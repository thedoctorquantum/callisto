const std = @import("std");
const Disassembler = @This();

const CodeGenerator = @import("CodeGenerator.zig");
const Instruction = CodeGenerator.Instruction;
const callisto = @import("callisto");
const Module = callisto.Module;

pub const DecodeInstructionIterator = struct 
{
    code_points: []u16,
    code_point_index: usize,  
    instruction_index: usize,

    pub fn next(self: *@This()) ?Instruction
    {
        if (self.code_point_index == self.code_points.len)
        {
            return null;
        }

        const code_point = self.code_points[self.code_point_index];
        self.code_point_index += 1;

        const instruction_header = @bitCast(callisto.Vm.InstructionHeader, code_point);

        var instruction: Instruction = .{ .opcode = instruction_header.opcode, .write_operand = .empty, .read_operands = .{ .empty, .empty } };

        switch (instruction_header.operand_layout)
        {
            .none => {},
            .write_register,
            .write_register_read_register,
            .write_register_read_register_read_register,
            .read_register,
            .read_register_read_register => {
                self.code_point_index += 1;
            },
            .write_register_immediate,
            .write_register_read_register_immediate,
            .read_register_immediate,
            .write_register_immediate_read_register,
            .immediate_read_register => {
                self.code_point_index += 1;
                self.code_point_index += instruction_header.immediate_size.size() / 2;
            },
            .immediate => {
                self.code_point_index += instruction_header.immediate_size.size() / 2;
            },
            .write_register_immediate_immediate => {
                self.code_point_index += 1;
                self.code_point_index += instruction_header.immediate_size.size();
            },
            .immediate_immediate => {
                self.code_point_index += instruction_header.immediate_size.size();
            },
            _ => unreachable,
        }

        switch (instruction_header.operand_layout)
        {
            .none => {},
            .write_register => {},
            .write_register_read_register => {},
            .write_register_read_register_read_register => {},
            .read_register => {},
            .read_register_read_register => {},
            .write_register_immediate => {},
            .write_register_read_register_immediate => {},
            .read_register_immediate => {},
            .write_register_immediate_read_register => {},
            .immediate_read_register => {},
            .immediate => {},
            .write_register_immediate_immediate => {},
            .immediate_immediate => {},
            _ => unreachable,
        }

        return instruction;
    } 
};

pub fn dissassemble(allocator: std.mem.Allocator, module: Module) ![]Instruction 
{
    var instructions = std.ArrayList(Instruction).init(allocator);

    const code_point_bytes = module.getSectionData(.instructions, 0) orelse return error.NoInstructionSection;
    const code_points = @ptrCast([*]u16, @alignCast(@alignOf(u16), code_point_bytes.ptr))[0..code_point_bytes.len / 2];

    var instructions_iter = DecodeInstructionIterator 
    {  
        .code_points = code_points,
        .code_point_index = 0, 
        .instruction_index = 0,
    };

    while (instructions_iter.next()) |instruction|
    {
        std.log.info("{s}", .{ @tagName(instruction.opcode) });
    }

    return instructions.toOwnedSlice();
}