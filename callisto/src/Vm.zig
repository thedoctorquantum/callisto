const std = @import("std");
const Loader = @import("Loader.zig");
const Vm = @This();

pub const FlatOpCode = enum(u8) 
{
    nullop,

    @"unreachable",

    @"break",

    move_rr, //reg_reg
    move_ri, //reg_imm

    clear,

    read8_ri,
    read8_rr,

    read16_ri,
    read16_rr,

    read32_ri,
    read32_rr,

    read64_ri,
    read64_rr,
    
    write8_rr,
    write8_ri,
    write8_ir,
    write8_ii,

    write16_rr,
    write16_ri,
    write16_ir,
    write16_ii,

    write32_rr,
    write32_ri,
    write32_ir,
    write32_ii,

    write64_rr,
    write64_ri,
    write64_ir,
    write64_ii,

    iadd_rr,
    iadd_ri,

    isub_rr,
    isub_ri,
    isub_ir,

    imul_rr,
    imul_ri,

    idiv_rr,
    idiv_ri,
    idiv_ir,

    islt,
    isgt,
    isle,
    isge,

    f32_add,
    f32_sub,
    f32_div,
    f32_mul,

    f64_add,
    f64_sub,
    f64_div,
    f64_mul,

    band_rr,
    band_ri,

    bor,
    bnot,
    lnot,

    push8_i,
    push8_r,

    push16_i,
    push16_r,

    push32_i,
    push32_r,

    push64_i,
    push64_r,

    pop8_r,

    pop16_r,
    
    pop32_r,

    pop64_r,

    eql_rr,
    eql_ri,

    neql_rr,
    neql_ri,

    jump_r,
    jump_i,

    jumpif_rr,
    jumpif_ri,

    call_r,
    call_i,

    ecall_r,
    ecall_i,

    @"return",
};

pub const OpCode = enum(u8) 
{
    nullop,
    @"unreachable",
    move,
    clear,
    daddr,
    load8,
    load16,
    load32,
    load64,
    store8,
    store16,
    store32,
    store64,
    iadd,
    isub,
    imul,
    idiv,
    islt,
    isgt,
    isle,
    isge,
    band,
    bor,
    bnot,
    lnot,
    push,
    pop,
    eql,
    neql,
    jump,
    jumpif,
    call,
    @"return",
    ecall,
    ebreak,

    imp7,
    imp6,
    imp5,
    imp4,
    imp3,
    imp2,
    imp1,
    imp0,
    _
};

pub const Register = enum(u4)
{
    c0, 
    c1, 
    c2, 
    c3, 
    c4, 
    c5,
    c6,
    c7,
    a0,
    a1,
    a2,
    a3,
    a4,
    a5,
    a6,
    a7,
};

pub const OperandAddressingSize = enum(u2) 
{
    @"8",
    @"16",
    @"32",
    @"64",

    pub inline fn size(self: OperandAddressingSize) usize 
    {
        return @as(u8, 1) << @enumToInt(self);
    }
};

pub const OperandLayout = enum(u4)
{
    none,
    write_register,
    write_register_read_register,
    write_register_read_register_read_register,
    write_register_immediate,
    write_register_immediate_immediate,
    write_register_immediate_read_register,
    write_register_read_register_immediate,
    read_register,
    read_register_read_register,
    read_register_immediate,
    immediate,
    immediate_immediate,
    immediate_read_register,
    _
};

pub const InstructionHeader = packed struct(u16)
{
    opcode: OpCode,
    operand_layout: OperandLayout,
    operand_size: OperandAddressingSize,
    immediate_size: OperandAddressingSize,
};

pub const OperandPack = packed struct(u16)
{
    read_operand: Register = .c0,
    write_operand: Register = .c0,
    read_operand1: Register = .c0,
    write_operand1: Register = .c0,
};

pub const NativeProcedure = fn (registers: *[16]u64, data_stack_pointer: [*]align(8) u8) void;

pub const ExecuteTrap = enum(u8) 
{
    invalid_opcode,
    illegal_instruction_access,
    unreachable_instruction,
    break_instruction,
    division_by_zero,
    stack_overflow,
    stack_underflow,
    memory_access_violation,
};

instruction_pointer: [*]align(2) u8 = undefined,
data_stack_pointer: [*]u64 = undefined,
call_stack_pointer: [*]Vm.CallFrame = undefined,
data_begin: [*]u8 = undefined,
registers: [16]u64 = std.mem.zeroes([16]u64),

pub fn bind(self: *@This(), module: Loader.ModuleInstance, address: usize) void
{
    const instructions_begin: [*]align(2) u8 = @ptrCast([*]u8, module.instructions.ptr);

    self.instruction_pointer = @alignCast(@alignOf(u16), instructions_begin + address);

    self.data_stack_pointer = module.data_stack.ptr;
    self.call_stack_pointer = module.call_stack.ptr;
    self.data_begin = module.data.ptr;
}

pub const ExecuteMode = union(enum)
{
    unbounded,
    bounded
};

pub const CallFrame = struct
{
    return_pointer: [*]align(2) u8,
    registers: [8]u64,
};

//Should implement setjmp/longjump in inline asm instead of linking to libc dynamically
const jump_buf = extern struct { a: c_int, b: c_int, c: c_int, d: c_int, e: c_int, f: c_int }; 

extern "c" fn setjmp(buf: *jump_buf) callconv(.C) c_int;
extern "c" fn longjmp(buf: *jump_buf, _: c_int) callconv(.C) void;

fn segfaultHandler(_: c_int) callconv(.C) void
{
    longjmp(&segfault_jump_buf, 1);

    unreachable;
}

var segfault_jump_buf: jump_buf = undefined;

pub const ExecuteResult = struct 
{
    trap: ?ExecuteTrap = null,
    last_instruction: [*]align(@alignOf(u16)) u8,
};

inline fn signExtend(comptime DestType: type, int: anytype) DestType
{   
    @setRuntimeSafety(false);

    const Unsigned = DestType;
    const Signed = std.meta.Int(.signed, @bitSizeOf(DestType));

    return @bitCast(Unsigned, @intCast(Signed, int));
}

comptime {
    // const original: u16 = @bitCast(u16, @as(i16, -5));
    // const extended: u64 = signExtend(u64, original);

    // @compileLog(@bitCast(i64, extended));
}

pub fn execute(
    self: *@This(), 
    module: Loader.ModuleInstance, 
    comptime mode: ExecuteMode, 
    bound: if (mode == .bounded) u32 else void
    ) ExecuteResult
{
    @setRuntimeSafety(false);

    var old_sigsegv_action: std.os.Sigaction = undefined;
    var old_sigbus_action: std.os.Sigaction = undefined;

    std.os.sigaction(std.os.SIG.SEGV, &.{ .handler = .{ .handler = &segfaultHandler }, .flags = undefined, .mask = undefined }, &old_sigsegv_action) catch unreachable;
    defer std.os.sigaction(std.os.SIG.SEGV, &old_sigsegv_action, null) catch unreachable;

    std.os.sigaction(std.os.SIG.BUS, &.{ .handler = .{ .handler = &segfaultHandler }, .flags = undefined, .mask = undefined }, &old_sigbus_action) catch unreachable;
    defer std.os.sigaction(std.os.SIG.BUS, &old_sigbus_action, null) catch unreachable;

    if (setjmp(&segfault_jump_buf) != 0)
    {
        return .{
            .trap = .memory_access_violation,
            .last_instruction = undefined,
        };
    }

    const instructions_begin: [*]align(2) u8 = @ptrCast([*]u8, module.instructions.ptr);

    var instruction_count: u32 = 0;

    while (true)
    {
        const instruction_begin = self.instruction_pointer;

        const instruction_header = @ptrCast(*const InstructionHeader, self.instruction_pointer).*;

        self.instruction_pointer += @sizeOf(InstructionHeader);

        switch (mode)
        {
            .bounded => {
                instruction_count += 1;
                
                if (instruction_count == bound)
                {
                    return .{
                        .last_instruction = instruction_begin,
                    };
                }
            },
            else => {},
        }

        var read_operand0: u64 = undefined;
        var read_operand1: u64 = undefined;

        var write_operand0: *u64 = undefined;

        switch (instruction_header.operand_layout)
        {
            .none => {},
            .write_register => {
                const register_operands = @ptrCast(*const OperandPack, self.instruction_pointer).*;
                self.instruction_pointer += @sizeOf(u16);

                write_operand0 = &self.registers[@enumToInt(register_operands.write_operand)];
            },
            .write_register_read_register => {
                const register_operands = @ptrCast(*const OperandPack, self.instruction_pointer).*;
                self.instruction_pointer += @sizeOf(u16);

                write_operand0 = &self.registers[@enumToInt(register_operands.write_operand)];
                read_operand0 = self.registers[@enumToInt(register_operands.read_operand)];
            },
            .write_register_read_register_read_register => {
                const register_operands = @ptrCast(*const OperandPack, self.instruction_pointer).*;
                self.instruction_pointer += @sizeOf(u16);

                write_operand0 = &self.registers[@enumToInt(register_operands.write_operand)];
                read_operand0 = self.registers[@enumToInt(register_operands.read_operand)];
                read_operand1 = self.registers[@enumToInt(register_operands.read_operand1)];
            },
            .write_register_immediate => {
                const register_operands = @ptrCast(*const OperandPack, self.instruction_pointer).*;
                self.instruction_pointer += @sizeOf(u16);

                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand0 = signExtend(u64, @ptrCast(*const i8, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand0 = signExtend(u64, @ptrCast(*const i16, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand0 = signExtend(u64, @ptrCast(*align(1) const i32, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand0 = @ptrCast(*align(1) const u64, self.instruction_pointer).*;
                        self.instruction_pointer += @sizeOf(u64);
                    },
                }

                write_operand0 = &self.registers[@enumToInt(register_operands.write_operand)];
            },
            .write_register_immediate_immediate => {
                unreachable;
            },
            .write_register_immediate_read_register => {
                const register_operands = @ptrCast(*const OperandPack, self.instruction_pointer).*;
                self.instruction_pointer += @sizeOf(u16);

                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand0 = signExtend(u64, @ptrCast(*const i8, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand0 = signExtend(u64, @ptrCast(*const i16, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand0 = signExtend(u64, @ptrCast(*align(1) const i32, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand0 = @ptrCast(*align(1) const u64, self.instruction_pointer).*;
                        self.instruction_pointer += @sizeOf(u64);
                    },
                }

                write_operand0 = &self.registers[@enumToInt(register_operands.write_operand)];
                read_operand1 = self.registers[@enumToInt(register_operands.read_operand)];
            },
            .write_register_read_register_immediate => {
                const register_operands = @ptrCast(*const OperandPack, self.instruction_pointer).*;
                self.instruction_pointer += @sizeOf(u16);

                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand1 = @truncate(u8, @ptrCast(*const u16, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand1 = @ptrCast(*const u16, self.instruction_pointer).*;
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand1 = @ptrCast(*align(1) const u32, self.instruction_pointer).*; //unaligned read
                        self.instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand1 = @ptrCast(*align(1) const u64, self.instruction_pointer).*; //unaligned read
                        self.instruction_pointer += @sizeOf(u64);
                    },
                }

                write_operand0 = &self.registers[@enumToInt(register_operands.write_operand)];
                read_operand0 = self.registers[@enumToInt(register_operands.read_operand)];
            },
            .read_register => { unreachable; },
            .read_register_read_register => { unreachable; },
            .read_register_immediate => {
                const register_operands = @ptrCast(*const OperandPack, self.instruction_pointer).*;
                self.instruction_pointer += @sizeOf(u16);

                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand1 = @truncate(u8, @ptrCast(*const u16, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand1 = @ptrCast(*const u16, self.instruction_pointer).*;
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand1 = @ptrCast(*align(1) const u32, self.instruction_pointer).*; //unaligned read
                        self.instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand1 = @ptrCast(*align(1) const u64, self.instruction_pointer).*; //unaligned read
                        self.instruction_pointer += @sizeOf(u64);
                    },
                }

                read_operand0 = self.registers[@enumToInt(register_operands.read_operand)];
            },
            .immediate => {
                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand0 = @truncate(u8, @ptrCast(*const u16, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand0 = @ptrCast(*const u16, self.instruction_pointer).*;
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand0 = @ptrCast(*align(1) const u32, self.instruction_pointer).*; //unaligned read
                        self.instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand0 = @ptrCast(*align(1) const u64, self.instruction_pointer).*; //unaligned read
                        self.instruction_pointer += @sizeOf(u64);
                    },
                }
            },
            .immediate_immediate => {
                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand0 = @truncate(u8, @ptrCast(*const u16, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u16);
                        read_operand1 = @truncate(u8, @ptrCast(*const u16, self.instruction_pointer).*);
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand0 = @ptrCast(*const u16, self.instruction_pointer).*;
                        self.instruction_pointer += @sizeOf(u16);
                        read_operand1 = @ptrCast(*const u16, self.instruction_pointer).*;
                        self.instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand0 = @ptrCast(*align(1) const u32, self.instruction_pointer).*; //unaligned read
                        self.instruction_pointer += @sizeOf(u32);
                        read_operand1 = @ptrCast(*align(1) const u32, self.instruction_pointer).*;
                        self.instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand0 = @ptrCast(*align(1) const u64, self.instruction_pointer).*; //unaligned read
                        self.instruction_pointer += @sizeOf(u64);
                        read_operand1 = @ptrCast(*align(1) const u64, self.instruction_pointer).*;
                        self.instruction_pointer += @sizeOf(u64);
                    },
                }
            },
            .immediate_read_register => unreachable,
            _ => unreachable,
        }

        //Dispatch/Execution
        switch (instruction_header.opcode)
        {
            .nullop => {},
            .@"unreachable" => return .{
                .trap = .unreachable_instruction,
                .last_instruction = instruction_begin,
            },
            .ebreak => return .{
                .trap = .break_instruction,
                .last_instruction = instruction_begin,
            },
            .move => write_operand0.* = read_operand0,
            .clear => write_operand0.* = 0,
            .iadd => write_operand0.* = read_operand0 +% read_operand1,
            .isub => write_operand0.* = read_operand0 -% read_operand1,
            .imul => write_operand0.* = read_operand0 *% read_operand1,
            .idiv => write_operand0.* = read_operand0 / read_operand1,
            .islt => unreachable,
            .isgt => unreachable,
            .isle => unreachable,
            .isge => unreachable,
            .band => unreachable,
            .bor => unreachable,
            .bnot => unreachable,
            .lnot => unreachable,
            .eql => unreachable,
            .neql => {
                write_operand0.* = @boolToInt(read_operand0 != read_operand1);
            },
            .push => unreachable,
            .pop => unreachable,
            .daddr => {
                write_operand0.* = @ptrToInt(self.data_begin + read_operand0);
            },
            .load8 => unreachable,
            .load16 => unreachable,
            .load32 => unreachable,
            .load64 => unreachable,
            .store8 => {
                @intToPtr(*allowzero u8, read_operand0).* = @truncate(u8, read_operand1);
            },
            .store16 => unreachable,
            .store32 => unreachable,
            .store64 => unreachable,
            .jump => self.instruction_pointer = @ptrCast(@TypeOf(self.instruction_pointer), @alignCast(2, instructions_begin + read_operand0)),
            .jumpif => {
                if (read_operand0 == 1)
                {
                    self.instruction_pointer = @ptrCast(@TypeOf(self.instruction_pointer), @alignCast(2, instructions_begin + read_operand1));
                }
            },
            .call => 
            {
                if (@ptrToInt(self.call_stack_pointer) >= @ptrToInt(module.call_stack.ptr + module.call_stack.len))
                {
                    return .{
                        .trap = .stack_overflow,
                        .last_instruction = instruction_begin,
                    };
                }

                self.call_stack_pointer[0].return_pointer = self.instruction_pointer;
                self.call_stack_pointer[0].registers = self.registers[0..8].*;

                std.mem.set(u64, self.registers[0..8], 0);

                self.call_stack_pointer += 1;
                self.instruction_pointer = @ptrCast(@TypeOf(self.instruction_pointer), @alignCast(2, instructions_begin + read_operand0));
            },
            .@"return" => 
            {
                if (self.call_stack_pointer == module.call_stack.ptr)
                {
                    return .{ 
                        .last_instruction = instruction_begin
                    };
                }
                
                self.call_stack_pointer -= 1;
                self.instruction_pointer = self.call_stack_pointer[0].return_pointer;
                self.registers[0..8].* = self.call_stack_pointer[0].registers;
            },
            .ecall => {
                module.natives[read_operand0](
                    &self.registers,
                    @ptrCast([*]u8, self.data_stack_pointer),
                );
            },
            .imp0, .imp1, .imp2, .imp3, .imp4, .imp5, .imp6, .imp7 => {},
            _ => return .{
                .trap = .invalid_opcode,
                .last_instruction = instruction_begin,
            },
        }
    }
} 