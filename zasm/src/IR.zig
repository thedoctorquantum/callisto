const std = @import("std");
const zyte = @import("zyte");

///This may not be the same as the low level opcode
pub const Operation = zyte.Vm.OpCode;

pub const InstructionStatement = struct
{
    operation: Operation,
    operands: [3]Operand,
    next: ?u31 = null,
    branch_next: ?u31 = null,

    pub const Operand = union(enum)
    {
        empty,
        register: u4,
        immediate: u64,
        symbol: u32,
    };
};

pub const SymbolValue = union(enum)
{
    basic_block_index: u32,
    data: struct {
        offset: u32,
        size: u32, 
    },
    integer: u64,
};

allocator: std.mem.Allocator,
instructions: std.ArrayListUnmanaged(InstructionStatement),
symbol_table: std.ArrayListUnmanaged(SymbolValue),
data: std.ArrayListUnmanaged(u8),

pub fn addInstruction(self: *@This(), operation: Operation, operands: [3]InstructionStatement.Operand) !u32 
{
    const index = @intCast(u32, self.instructions.items.len);

    try self.instructions.append(self.allocator, .{
        .operation = operation,
        .operands = operands,
        .next = @intCast(u31, index + 1),
        .branch_next = @intCast(u31, index + 1),
    });

    return index;
}

pub fn addBranchInstruction(self: *@This(), operation: Operation, operands: [3]u32) !u32
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

pub fn addGlobal(self: *@This(), value: SymbolValue) !u32 
{
    const symbol = self.symbol_table.items.len;

    try self.symbol_table.append(self.allocator, value);

    return @intCast(u32, symbol);
}