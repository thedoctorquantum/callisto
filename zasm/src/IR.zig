const std = @import("std");
const zyte = @import("zyte");

pub const OperationType = zyte.Vm.OpCode;

pub const InstructionStatement = struct
{
    operation: OperationType,
    operands: [3]Operand,
    next: u32 = 0,
    branch_next: u32 = 0,

    pub const Operand = union(enum)
    {
        register: u4,
        immediate: u64,
        symbol: u32,
    };
};

pub const SymbolValue = union(enum)
{
    register: u4,
    immediate: u64,
    basic_block_index: u32,
};

allocator: std.mem.Allocator,
instructions: std.ArrayListUnmanaged(InstructionStatement),
symbol_table: std.ArrayListUnmanaged(SymbolValue),
data: std.ArrayListUnmanaged(u8),

pub fn addInstruction(self: *@This(), operation: OperationType, operands: [3]InstructionStatement.Operand) !u32 
{
    const index = @intCast(u32, self.instructions.items.len);

    try self.instructions.append(self.allocator, .{
        .operation = operation,
        .operands = operands,
        .next = index + 1,
        .branch_next = index + 1,
    });

    return index;
}

pub fn addBranchInstruction(self: *@This(), operation: OperationType, operands: [3]u32) !u32
{
    const index = self.instructions.items.len;

    self.instructions.append(self.allocator, .{
        .operation = operation,
        .operands = operands,
        .next = index + 1,
        .branch_next = index + 1,
    });

    return index;
}