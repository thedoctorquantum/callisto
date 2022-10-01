const std = @import("std");
const Vm = @This();
// const Module = @import("Module.zig");

pub const OpCode = enum(u8) 
{
    //core instructions
    nullop,
    @"unreachable", //Unrecoverable Trap
    @"break", //Recoverable Trap
    move,
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
    imul, //imul r, im, r 
    idiv,
    islt, //signed less than
    isgt, //signed greater than
    isle, //signed less than or equal
    isge, //signed greater than or equal
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

    //implementation instructions
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

pub const ImmedateSize = enum(u2) 
{
    @"8",
    @"16",
    @"32",
    @"64",

    pub fn size(self: ImmedateSize) usize 
    {
        return 1 << @enumToInt(self);
    }
};

//iadd reg_imm_reg im32(69)
pub const Instruction32 = packed struct(u32)
{
    opcode: OpCode,
    read_operand: Operand,
    read_operand1: Register,
    write_operand: Register,
    read_operand1_enabled: bool,
    write_enabled: bool,

    pub const Operand = packed struct(u8)
    {
        tag: Tag,
        data: packed union
        {
            size: Size,
            register: Register,
        },

        pub const Tag = enum(u4)
        {
            disabled,
            immediate,
            register,
            _
        };

        pub const Size = enum(u2)
        {
            @"8",
            @"16",
            @"32",
            @"64",

            pub fn size(self: ImmedateSize) usize 
            {
                return 1 << @enumToInt(self);
            }
        };
    };
};

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
    return_pointer: usize,
    registers: [16]u64,
};

//Generates a wrapper for any zig function
pub fn extFn(comptime proc: anytype) *const fn(*Vm) void
{
    const arg_types = @typeInfo(@TypeOf(proc)).Fn.args;

    const S = struct
    {
        pub fn function(vm: *Vm) void
        {
            comptime var args_type_fields: [arg_types.len]std.builtin.Type.StructField = undefined;

            inline for (arg_types) |arg_type, i|
            {
                args_type_fields[i] = .{
                    .field_type = arg_type.arg_type.?,
                    .alignment = @alignOf(arg_type.arg_type.?),
                    .default_value = null,
                    .is_comptime = false,
                    .name = comptime std.fmt.comptimePrint("{}", .{ i }),
                };
            }

            const ArgsType = @Type(.{ .Struct = .{ 
                .layout = .Auto,
                .is_tuple = true,
                .fields = &args_type_fields,
                .decls = &[_]std.builtin.Type.Declaration {},
            }});

            var args: ArgsType = undefined;

            comptime var register_index = 0;

            inline for (comptime std.meta.fields(ArgsType)) |_, i|
            {
                const ArgType = @TypeOf(args[i]);

                switch (@typeInfo(ArgType))
                {
                    .Int => {
                        args[i] = vm.getRegister(@intToEnum(Register, 8 + register_index)).*;
                    },
                    .Pointer => |pointer| {
                        switch (pointer.size)
                        {
                            .One, .Many => {
                                args[i] = @intToPtr(ArgType, vm.getRegister(@intToEnum(Register, 8 + register_index)).*);
                            },
                            .Slice => {
                                const register0 = vm.getRegister(@intToEnum(Register, 8 + register_index)).*;
                                const register1 = vm.getRegister(@intToEnum(Register, 8 + register_index + 1)).*;

                                register_index += 1;

                                args[i] = @intToPtr([*]std.meta.Child(ArgType), register0)[0..register1];
                            },
                            else => unreachable 
                        }
                    },
                    else => unreachable
                }

                register_index += 1;
            }

            const return_value = @call(
                .{ .modifier = .always_inline }, 
                proc,
                args,
            );

            switch (@typeInfo(@TypeOf(return_value)))
            {
                .Int => {
                    vm.setRegister(.a7, return_value);
                },
                .Pointer => |pointer| {
                    switch (pointer.size)
                    {
                        .One, .Many => {
                            vm.setRegister(.a7, @intCast(u64, @ptrToInt(return_value)));
                        },
                        .Slice => {
                            vm.setRegister(.a7, @ptrToInt(return_value.ptr));
                            vm.setRegister(.a6, @intCast(u64, return_value.len));
                        },
                        else => unreachable 
                    }
                },
                .Void => {},
                else => unreachable
            }
            
        }
    };

    return &S.function;
}

program_pointer: usize = 0,
stack_pointer: usize = 0,
registers: [16]u64 = std.mem.zeroes([16]u64),
stack: []u64,
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

const jump_buf = extern struct { a: c_int, b: c_int, c: c_int, d: c_int, e: c_int, f: c_int }; 

extern "c" fn setjmp(buf: *jump_buf) callconv(.C) c_int;
extern "c" fn longjmp(buf: *jump_buf, _: c_int) callconv(.C) void;

fn segfaultHandler(_: c_int) callconv(.C) void
{
    longjmp(&segfault_jump_buf, 1);

    unreachable;
}

var segfault_jump_buf: jump_buf = undefined;

pub fn execute(self: *Vm, executable: Executable, instruction_pointer: usize) ExecuteError!void
{
    self.program_pointer = instruction_pointer;

    var old_sigsegv_action: std.os.Sigaction = undefined;

    std.os.sigaction(std.os.SIG.SEGV, &.{ .handler = .{ .handler = &segfaultHandler }, .flags = undefined, .mask = undefined }, &old_sigsegv_action) catch unreachable;
    defer std.os.sigaction(std.os.SIG.SEGV, &old_sigsegv_action, null) catch unreachable;

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