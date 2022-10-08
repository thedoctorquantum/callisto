const std = @import("std");
const zyte = @import("zyte");

///This may not be the same as the low level opcode
pub const Operation = zyte.Vm.OpCode;

pub fn isBlockTerminatorOperation(operation: Operation) bool
{
    return switch (operation)
    {
        .@"return",
        .@"unreachable",
        .jumpif,
        .jump => true, 
        else => false,
    };
}

pub fn isProcedureTerminatorOperation(operation: Operation) bool 
{
    return switch (operation) {
        .@"unreachable",
        .@"return" => true,
        else => false,
    };
}

pub fn isBlockTerminatorStatement(statement: Statement) bool 
{
    return isBlockTerminatorOperation(statement.instruction.operation);
}

pub fn isProcedureTerminatorStatement(statement: Statement) bool 
{
    return isProcedureTerminatorOperation(statement.instruction.operation);
}

//
//procedure_begin

//entry_block_begin //0 entry
//jumpif c0, 2;
//entry_block_end

//basic_block_begin
//set_opt 0 //no optimisation for this basic block
//inst
//inst
//inst
//....
//terminator inst
//basic_block_end -> basic_block_begin

//exit_block_begin //2
//iadd c0, c1, c2;
//sub c0, 2, c3;
//mul c0, 3;
//return;
//exit_block_end

//procedure_end
//

pub const Statement = union(enum)
{
    procedure_begin,
    procedure_end,
    entry_block_begin,
    entry_block_end: struct {
        next: ?u31, //next basic_block
        cond_next: ?u31, //next basic_block for the condition
    },
    basic_block_begin,
    basic_block_end: struct {
        next: ?u31, //next basic_block
        cond_next: ?u31, //next basic_block for the condition
    },
    exit_block_begin,
    exit_block_end,
    instruction: Instruction,

    pub const Instruction = struct
    {
        operation: Operation,
        operands: [3]Operand,

        pub const Operand = union(enum)
        {
            empty,
            register: u4,
            immediate: u64,
            symbol: u32,
        };
    };
};

pub const StatementIndex = u32;

pub const max_statements = std.math.maxInt(StatementIndex);

pub const SymbolValue = union(enum)
{
    basic_block_index: u32, //index to any block_begin statement
    procedure_index: u32, //index to procedure_begin statment
    data: struct {
        offset: u32,
        size: u32, 
    },
    integer: u64,
};

allocator: std.mem.Allocator,
statements: std.ArrayListUnmanaged(Statement),
entry_points: std.ArrayListUnmanaged(u32),
symbol_table: std.ArrayListUnmanaged(SymbolValue),
data: std.ArrayListUnmanaged(u8),

pub fn beginProcedure(self: *@This()) !StatementIndex 
{
    return try self.addStatement(.procedure_begin);
}

pub fn endProcedure(self: *@This()) !StatementIndex
{
    return try self.addStatement(.procedure_end);
}

pub fn beginEntryBlock(self: *@This()) !StatementIndex 
{
    return try self.addStatement(.entry_block_begin);
}

pub fn endEntryBlock(self: *@This(), next: ?u31, cond_next: ?u31) !StatementIndex
{
    return try self.addStatement(.{ .entry_block_end = .{ .next = next, .cond_next = cond_next } });
}

pub fn beginBasicBlock(self: *@This()) !StatementIndex
{
    return try self.addStatement(.basic_block_begin);
}

pub fn endBasicBlock(self: *@This(), next: ?u31, cond_next: ?u31) !StatementIndex
{
    return try self.addStatement(.{ .basic_block_end = .{ .next = next, .cond_next = cond_next } });
}

pub fn beginExitBlock(self: *@This()) !StatementIndex
{
    return try self.addStatement(.exit_block_begin);
}

pub fn endExitBlock(self: *@This()) !StatementIndex
{
    return try self.addStatement(.exit_block_end);
}

pub fn addInstruction(self: *@This(), operation: Operation, operands: [3]Statement.Instruction.Operand) !StatementIndex 
{
    return try self.addStatement(.{
        .instruction = .{
            .operation = operation,
            .operands = operands,
        }
    });
}

pub fn addStatement(self: *@This(), statement: Statement) !StatementIndex
{
    const index = self.statements.items.len;

    try self.statements.append(self.allocator, statement);

    return @intCast(StatementIndex, index);
}

pub fn getLastStatementTag(self: *@This()) std.meta.Tag(Statement) 
{
    return std.meta.activeTag(self.getLastStatement().*);
} 

pub fn getLastStatement(self: *@This()) *Statement
{
    return &self.statements.items[self.statements.items.len - 1];
}

pub fn getLastStatementOfTag(self: *@This(), tag: std.meta.Tag(Statement)) ?*Statement 
{
    var i: isize = @intCast(isize, self.statements.items.len) - 1;

    while (i >= 0)
    {
        const statement = self.getStatement(@intCast(usize, i));

        if (statement.* == tag)
        {
            return statement;
        }

        i -= 1;
    }

    return null;
}

pub fn getLastStatementOfTagAny(self: *@This(), tags: []const std.meta.Tag(Statement)) ?*Statement
{
    var i: isize = @intCast(isize, self.statements.items.len) - 1;

    while (i >= 0)
    {
        const statement = self.getStatement(@intCast(u32, i));

        for (tags) |tag|
        {
            if (statement.* == tag)
            {
                return statement;
            }
        }

        i -= 1;
    }

    return null;
}

pub fn getStatementTag(self: *@This(), index: StatementIndex) std.meta.Tag(Statement)
{
    return std.meta.activeTag(self.getStatement(index).*);
}

pub fn getStatement(self: *@This(), index: StatementIndex) *Statement
{
    return &self.statements.items[index];
}

pub fn addGlobal(self: *@This(), value: SymbolValue) !u32 
{
    const symbol = self.symbol_table.items.len;

    try self.symbol_table.append(self.allocator, value);

    return @intCast(u32, symbol);
}