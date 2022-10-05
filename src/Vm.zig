const std = @import("std");
const Loader = @import("Loader.zig");
const Vm = @This();

pub const OpCode = enum(u8) 
{
    nullop,
    @"unreachable",
    @"break",
    move,
    clear,
    read8,
    read16,
    read32,
    read64,
    write8,
    write16,
    write32,
    write64,
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
    extcall,
    @"return",

    imp7 = std.math.maxInt(u8) - 7,
    imp6 = std.math.maxInt(u8) - 6,
    imp5 = std.math.maxInt(u8) - 5,
    imp4 = std.math.maxInt(u8) - 4,
    imp3 = std.math.maxInt(u8) - 3,
    imp2 = std.math.maxInt(u8) - 2,
    imp1 = std.math.maxInt(u8) - 1,
    imp0 = std.math.maxInt(u8),
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
    register, //r0;
    register_register, //r0, r1;
    register_register_register, //r0, r1, r2;
    register_immediate, //r0, imm;
    register_immediate_register, //r0, imm, r1;
    immediate, //imm;
    immediate_immediate, //imm, imm
    immediate_register, //imm, r0;
    immediate_register_register, //imm, r0, r1;
    _
};

pub const InstructionHeader = packed struct(u16)
{
    opcode: OpCode,
    operand_layout: OperandLayout,
    operand_size: OperandAddressingSize,
    immediate_size: OperandAddressingSize,
};

//There are 4 operand registers available to instructions
//ro0: readonly_0; (64 bits) (register or immediate)
//ro1: readonly_1; (64 bits) (register or immediate)
//rw0: readwrite_0; (64 bits) (register)
//rw1: readwrite_1; (64 bits) (register)
pub const OperandPack = packed struct(u16)
{
    read_operand: Register = .c0, //readonly register 1
    write_operand: Register = .c0, //writeonly register 1
    read_operand1: Register = .c0, //readonly register 2
    write_operand1: Register = .c0, //writeonly register 2

    //optimization for storing 1 byte immediates
    // operand1: packed union 
    // { 
    //     immediate: u8, 
    //     registers: packed struct(u8) 
    //     { 
    //         read: Register = .c0, 
    //         write: Register = .c0,
    //     } 
    // } = .{ .immediate = 0, },
};

pub const NativeProcedure = fn (registers: *[16]u64, data_stack_pointer: [*]align(8) u8) void;

pub const ExecuteError = error 
{
    InvalidOpcode,
    IllegalInstructionAccess,
    UnreachableInstruction,
    BreakInstruction,
    DivisionByZero,
    StackOverflow,
    StackUnderflow,
    MemoryAccessViolation,
};

pub fn execute(module: Loader.ModuleInstance) ExecuteError!void 
{
    @setRuntimeSafety(false);

    var registers = std.mem.zeroes([16]u64);

    var instruction_pointer: [*]align(2) const u8 = @ptrCast([*]const u8, module.instructions.ptr);

    const instructions_begin: [*]align(2) const u8 = instruction_pointer;

    var data_stack_pointer: [*]u64 = module.data_stack.ptr;
    var call_stack_pointer: [*]Vm.CallFrame = module.call_stack.ptr;

    _ = call_stack_pointer;

    //- Each Instruction loop can fetch 1 or more code points,
    //- Decode Loop:
    //  - Fetch code point (2 bytes (16 bits)),
    //  - Decode code point,
    //- Dispatch/Execute,

    while (true)
    {
        const instruction_header = @ptrCast(*const InstructionHeader, instruction_pointer).*;

        instruction_pointer += @sizeOf(InstructionHeader);

        var read_operand0: u64 = undefined;
        var read_operand1: u64 = undefined;

        var write_operand0: *u64 = undefined;
        var write_operand1: *u64 = undefined;

        _ = write_operand1;

        switch (instruction_header.operand_layout)
        {
            .none => {},
            .immediate => {
                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand0 = @truncate(u8, @ptrCast(*const u16, instruction_pointer).*);
                        instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand0 = @ptrCast(*const u16, instruction_pointer).*;
                        instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand0 = @ptrCast(*const u32, @alignCast(@alignOf(u32), instruction_pointer)).*; //unaligned read
                        instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand0 = @ptrCast(*const u64, @alignCast(@alignOf(u64), instruction_pointer)).*; //unaligned read
                        instruction_pointer += @sizeOf(u64);
                    },
                }
            },
            .immediate_register => {
                const register_operands = @ptrCast(*const OperandPack, instruction_pointer).*;
                instruction_pointer += @sizeOf(u16);

                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand0 = @truncate(u8, @ptrCast(*const u16, instruction_pointer).*);
                        instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand0 = @ptrCast(*const u16, instruction_pointer).*;
                        instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand0 = @ptrCast(*align(1) const u32, instruction_pointer).*; //unaligned read
                        instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand0 = @ptrCast(*align(1) const u64, instruction_pointer).*; //unaligned read
                        instruction_pointer += @sizeOf(u64);
                    },
                }

                write_operand0 = &registers[@enumToInt(register_operands.write_operand)];

                std.log.info("Operands: {}, {s}({})", .{ read_operand0, @tagName(register_operands.write_operand), write_operand0.* });
            },
            .register => {
                const register_operands = @ptrCast(*const OperandPack, instruction_pointer).*;
                instruction_pointer += @sizeOf(u16);

                read_operand0 = registers[@enumToInt(register_operands.read_operand)];
            },
            .register_register => {
                const register_operands = @ptrCast(*const OperandPack, instruction_pointer).*;
                instruction_pointer += @sizeOf(u16);

                read_operand0 = registers[@enumToInt(register_operands.read_operand)];
                write_operand0 = &registers[@enumToInt(register_operands.write_operand)];
            },
            .register_register_register => {
                const register_operands = @ptrCast(*const OperandPack, instruction_pointer).*;
                instruction_pointer += @sizeOf(u16);

                read_operand0 = registers[@enumToInt(register_operands.read_operand)];
                read_operand1 = registers[@enumToInt(register_operands.read_operand1)];
                write_operand0 = &registers[@enumToInt(register_operands.write_operand)];
            },
            .register_immediate_register => {
                const register_operands = @ptrCast(*const OperandPack, instruction_pointer).*;
                instruction_pointer += @sizeOf(u16);

                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand1 = @truncate(u8, @ptrCast(*const u16, instruction_pointer).*);
                        instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand1 = @ptrCast(*const u16, instruction_pointer).*;
                        instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand1 = @ptrCast(*align(1) const u32, instruction_pointer).*; //unaligned read
                        instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand1 = @ptrCast(*align(1) const u64, instruction_pointer).*; //unaligned read
                        instruction_pointer += @sizeOf(u64);
                    },
                }

                read_operand0 = registers[@enumToInt(register_operands.read_operand)];
                write_operand0 = &registers[@enumToInt(register_operands.write_operand)];

                std.log.info("Operands: {s}, {}, {s}", .{ @tagName(register_operands.read_operand), read_operand1, @tagName(register_operands.write_operand) });
            },
            .register_immediate => {
                const register_operands = @ptrCast(*const OperandPack, instruction_pointer).*;
                instruction_pointer += @sizeOf(u16);

                switch (instruction_header.immediate_size)
                {
                    .@"8" => {
                        read_operand1 = @truncate(u8, @ptrCast(*const u16, instruction_pointer).*);
                        instruction_pointer += @sizeOf(u16);
                    },
                    .@"16" => {
                        read_operand1 = @ptrCast(*const u16, instruction_pointer).*;
                        instruction_pointer += @sizeOf(u16);
                    },
                    .@"32" => {
                        read_operand1 = @ptrCast(*align(1) const u32, instruction_pointer).*; //unaligned read
                        instruction_pointer += @sizeOf(u32);
                    },
                    .@"64" => { 
                        read_operand1 = @ptrCast(*align(1) const u64, instruction_pointer).*; //unaligned read
                        instruction_pointer += @sizeOf(u64);
                    },
                }

                read_operand0 = registers[@enumToInt(register_operands.read_operand)];

                std.log.info("Operands: {}, {}", .{ read_operand0, read_operand1 });
            },
            .immediate_immediate => unreachable,
            .immediate_register_register => unreachable,
            _ => unreachable,
        }

        std.log.info("{s}", .{ @tagName(instruction_header.opcode) });

        //Dispatch/Execution
        switch (instruction_header.opcode)
        {
            .nullop => {},
            .@"unreachable" => return error.UnreachableInstruction,
            .@"break" => return error.BreakInstruction,
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
            .read8 => unreachable,
            .read16 => unreachable,
            .read32 => unreachable,
            .read64 => unreachable,
            .write8 => {
                @intToPtr(*allowzero u8, write_operand0.*).* = @intCast(u8, read_operand0);
            },
            .write16 => unreachable,
            .write32 => unreachable,
            .write64 => unreachable,
            .jump => instruction_pointer = @ptrCast(@TypeOf(instruction_pointer), @alignCast(2, instructions_begin + read_operand0)),
            .jumpif => {
                if (read_operand0 == 1)
                {
                    instruction_pointer = @ptrCast(@TypeOf(instruction_pointer), @alignCast(2, instructions_begin + read_operand1));
                }
            },
            .call => unreachable,
            .@"return" => return,
            .extcall => {
                module.natives[read_operand0](
                    &registers,
                    @ptrCast([*]u8, data_stack_pointer),
                );
            },
            .imp0, .imp1, .imp2, .imp3, .imp4, .imp5, .imp6, .imp7 => {},
            _ => unreachable,
        }
    }
} 

//Legacy Implementation

pub const Instruction = struct
{
    opcode: OpCode,
    operands: [3]Operand,

    pub const Operand = union(enum) 
    {
        register: u4,
        immediate: u64,
    };
};

pub const Executable = struct
{
    instructions: []const Instruction,
    data: []u8,
};

pub const CallFrame = struct
{
    return_pointer: u64,
    registers: [16]u64,
};

program_pointer: usize = 0,
registers: [16]u64 = std.mem.zeroes([16]u64),
stack: []u64,
stack_pointer: usize = 0,
call_stack: []CallFrame,
call_stack_pointer: usize = 0,
natives: []const *const fn(*Vm) void,

pub fn init(_: *Vm) void 
{
    
}

pub fn deinit(_: *Vm) void 
{

}

///Resets the execution state
pub fn reset(self: *Vm) void
{
    self.stack_pointer = 0;
    self.program_pointer = 0;
    self.registers = std.mem.zeroes(@TypeOf(self.registers));
}

pub inline fn getRegister(self: *Vm, register: Register) *u64
{
    return &self.registers[@enumToInt(register)];
}

pub inline fn setRegister(self: *Vm, register: Register, value: u64) void
{
    self.registers[@enumToInt(register)] = value;
}

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

///Legacy fixed-width implementation
pub fn execute_old(self: *Vm, executable: Executable, instruction_pointer: usize) ExecuteError!void
{
    self.program_pointer = instruction_pointer;

    var old_sigsegv_action: std.os.Sigaction = undefined;
    var old_sigbus_action: std.os.Sigaction = undefined;

    std.os.sigaction(std.os.SIG.SEGV, &.{ .handler = .{ .handler = &segfaultHandler }, .flags = undefined, .mask = undefined }, &old_sigsegv_action) catch unreachable;
    defer std.os.sigaction(std.os.SIG.SEGV, &old_sigsegv_action, null) catch unreachable;

    std.os.sigaction(std.os.SIG.BUS, &.{ .handler = .{ .handler = &segfaultHandler }, .flags = undefined, .mask = undefined }, &old_sigbus_action) catch unreachable;
    defer std.os.sigaction(std.os.SIG.BUS, &old_sigbus_action, null) catch unreachable;

    if (setjmp(&segfault_jump_buf) != 0)
    {
        return error.MemoryAccessViolation;
    }

    while (true) : (self.program_pointer += 1)
    {
        @setRuntimeSafety(false);

        if (self.program_pointer >= executable.instructions.len)
        {
            return error.IllegalInstructionAccess;
        }

        const instruction = executable.instructions[self.program_pointer];

        defer 
        {
            std.log.info("Register State: {any}", .{ self.registers });
            std.log.info("Stack State: {any}", .{ self.stack[0..self.stack_pointer] } );
        }

        std.log.info("Program Counter: {}", .{ self.program_pointer });
        std.log.info("Executing {}", .{ instruction.opcode });

        switch (instruction.opcode)
        {
            .nullop => {},
            .@"unreachable" => return error.UnreachableInstruction,
            .@"break" => return error.BreakInstruction,
            .move => 
            {
                self.registers[instruction.operands[0].register] = self.operandValue(instruction.operands[1]);
            },
            .clear => 
            {
                self.registers[instruction.operands[0].register] = 0;
            },
            .read8 => 
            {
                self.registers[instruction.operands[0].register] = @intToPtr(*allowzero const u8, self.operandValue(instruction.operands[1])).*;
            },
            .read16 => {},
            .read32 => {},
            .read64 => {},
            .write8 => 
            {
                @intToPtr(*allowzero u8, self.operandValue(instruction.operands[0])).* = @intCast(u8, self.operandValue(instruction.operands[1]));
            },
            .write16 => {},
            .write32 => {},
            .write64 => {},
            .iadd => 
            {
                self.registers[instruction.operands[2].register] = self.operandValue(instruction.operands[0]) +% self.operandValue(instruction.operands[1]);
            },
            .isub => 
            {
                self.registers[instruction.operands[2].register] = self.operandValue(instruction.operands[0]) -% self.operandValue(instruction.operands[1]);
            },
            .imul =>
            {
                self.registers[instruction.operands[2].register] = self.operandValue(instruction.operands[0]) *% self.operandValue(instruction.operands[1]);
            },
            .idiv =>
            {
                if (self.operandValue(instruction.operands[1]) == 0)
                {
                    return error.DivisionByZero;
                }

                self.registers[instruction.operands[2].register] = self.registers[instruction.operands[0].register] / self.operandValue(instruction.operands[1]);
            },
            .islt => {},
            .isgt => {},
            .isle => {},
            .isge => {},
            .band => 
            {
                self.registers[instruction.operands[2].register] = self.operandValue(instruction.operands[0]) & self.operandValue(instruction.operands[1]);
            },
            .bor => 
            {
                self.registers[instruction.operands[2].register] = self.operandValue(instruction.operands[0]) | self.operandValue(instruction.operands[1]);
            },
            .bnot => 
            {
                self.registers[instruction.operands[1].register] = ~self.operandValue(instruction.operands[0]);
            },
            .lnot => 
            {
                self.registers[instruction.operands[1].register] = @boolToInt(!(self.operandValue(instruction.operands[0]) != 0));
            },
            .push =>
            {
                if (self.stack_pointer >= self.stack.len)
                {
                    return error.StackOverflow;
                }

                self.stack[self.stack_pointer] = self.operandValue(instruction.operands[1]); 
                self.stack_pointer +%= 1;
            },
            .pop => 
            {   
                if (self.stack_pointer == 0)
                {
                    return error.StackUnderflow;
                }

                self.stack_pointer -%= 1;
                self.registers[instruction.operands[0].register] = self.stack[self.stack_pointer];
            },
            .eql => 
            {
                self.registers[instruction.operands[2].register] = @boolToInt(self.operandValue(instruction.operands[0]) == self.operandValue(instruction.operands[1]));
            },
            .neql =>
            {
                self.registers[instruction.operands[2].register] = @boolToInt(self.operandValue(instruction.operands[0]) != self.operandValue(instruction.operands[1]));
            },
            .jump => 
            {
                self.program_pointer = self.operandValue(instruction.operands[0]) -% 1;
            },
            .jumpif =>
            {
                if (self.registers[instruction.operands[0].register] != 0)
                {
                    self.program_pointer = self.operandValue(instruction.operands[1]) -% 1;
                }
            },
            .call => 
            {
                if (self.call_stack_pointer >= self.call_stack.len)
                {
                    return error.StackOverflow;
                }

                self.call_stack[self.call_stack_pointer].return_pointer = self.program_pointer + 1;
                self.program_pointer = self.operandValue(instruction.operands[0]) - 1;
                self.call_stack_pointer +%= 1;
            },
            .@"return" => 
            {
                if (self.call_stack_pointer == 0)
                {
                    return;
                }
                
                self.call_stack_pointer -%= 1;
                self.program_pointer = self.call_stack[self.call_stack_pointer].return_pointer - 1;
            },
            .extcall => 
            {
                self.natives[self.operandValue(instruction.operands[0])](self);
            },
            .imp0, .imp1, .imp2, .imp3, .imp4, .imp5, .imp6, .imp7 => {},
            _ => return error.InvalidOpcode
        }     
    }
}

fn operandValue(self: *Vm, operand: Instruction.Operand) u64
{
    var value: u64 = undefined;

    switch (operand)
    {
        .register => |register| 
        {
            value = self.registers[register];
        },
        .immediate => |immediate| 
        {
            value = immediate;
        },
    }

    return value;
}