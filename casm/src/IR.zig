const std = @import("std");
const zyte = @import("zyte");
const IR = @This();

pub fn isBlockTerminatorOperation(operation: Statement.Instruction.Operation) bool
{
    return switch (operation)
    {
        .jumpif,
        .jump => true, 
        else => false,
    };
}

pub fn isProcedureTerminatorOperation(operation: Statement.Instruction.Operation) bool 
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

pub const Statement = union(enum)
{
    instruction: Instruction,

    pub const Instruction = struct
    {
        operation: Operation,
        write_operand: Operand,
        read_operands: [2]Operand,

        ///Not the same as an opcode,
        ///this is describes a pseudo operation
        ///Not a 1:1 ratio with actual callisto instructions
        ///Eg: call print -> ecall print or call print; 
        pub const Operation = enum 
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
            ebreak,
        };

        pub const Register = enum 
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

        pub const Operand = union(enum)
        {
            empty,
            register: Register,
            immediate: u64,
            symbol: u32,
        };
    };
};

pub const StatementIndex = u32;

pub const max_statements = std.math.maxInt(StatementIndex);

pub const SymbolValue = union(enum)
{
    basic_block_index: u32,
    procedure_index: u32,
    imported_procedure: struct
    {
        index: u32,
        name: []const u8, //should really be stored in the IR
    },
    data: struct {
        offset: u32,
        size: u32, 
    },
    integer: u64,
};

pub const Procedure = struct 
{
    entry: BasicBlockIndex,
};

pub const BasicBlockIndex = BasicBlock.Index;

pub const BasicBlock = struct
{
    statement_offset: u32,
    statement_count: u32,
    next: ?u31,
    cond_next: ?u31,

    pub const Index = u32;
};

allocator: std.mem.Allocator,
entry_points: std.ArrayListUnmanaged(u32) = .{},
entry_point_procedure: u32,
procedures: std.ArrayListUnmanaged(Procedure) = .{},
basic_blocks: std.ArrayListUnmanaged(BasicBlock) = .{},
statements: std.ArrayListUnmanaged(Statement) = .{},
symbol_table: std.ArrayListUnmanaged(SymbolValue) = .{},
data: std.ArrayListUnmanaged(u8) = .{},

pub const ConstReachableProcedureIterator = struct 
{
    ir: *const IR,
    index: u32 = 0,
    entry_point_index: u32 = 0, 

    pub fn next(self: *@This()) ?*const Procedure
    {
        while (self.entry_point_index < self.ir.entry_points.items.len)
        {
            self.index = self.ir.entry_points.items[self.entry_point_index];
            defer self.entry_point_index += 1;

            return &self.ir.procedures.items[self.index];            
        }

        return null;
    }
};

pub fn constReachableProcedureIterator(self: *const @This()) ConstReachableProcedureIterator
{
    return ConstReachableProcedureIterator
    {
        .ir = self,
    };
}

pub const ConstReachableBasicBlockIterator = struct 
{
    ir: *const IR,
    index: u32,
    current_index: u32,

    pub fn next(self: *@This()) ?*const BasicBlock 
    {
        if (self.current_index < self.ir.basic_blocks.items.len)
        {
            const block = &self.ir.basic_blocks.items[self.current_index];

            self.index = self.current_index;
            self.current_index = block.next orelse
            {
                self.current_index = @intCast(u32, self.ir.basic_blocks.items.len);

                return block;
            };

            return block;
        }

        return null;
    }
};

pub fn constReachableBasicBlockIterator(self: *const @This(), procedure: Procedure) ConstReachableBasicBlockIterator
{
    return ConstReachableBasicBlockIterator
    {
        .ir = self,
        .index = procedure.entry,
        .current_index = procedure.entry,
    };
}

pub fn beginProcedure(self: *@This()) !void
{
    try self.procedures.append(self.allocator, .{ .entry = @intCast(u32, self.basic_blocks.items.len), });
    try self.beginBasicBlock();
}

pub fn beginBasicBlock(self: *@This()) !void 
{
    if (self.basic_blocks.items.len != 0)
    {
        const previous = self.basic_blocks.items[self.basic_blocks.items.len - 1];

        if (previous.statement_count == 0)
        {
            return;
        }
    }

    try self.basic_blocks.append(self.allocator, .{ 
        .statement_offset = @intCast(u31, self.statements.items.len), 
        .statement_count = 0, 
        .next = @intCast(u31, self.basic_blocks.items.len + 1), 
        .cond_next = null 
    });
}

pub fn addInstruction(
    self: *@This(), 
    operation: Statement.Instruction.Operation, 
    write_operand: Statement.Instruction.Operand, 
    read_operands: [2]Statement.Instruction.Operand
) !void 
{
    const current_block = &self.basic_blocks.items[self.basic_blocks.items.len - 1];

    if (current_block.next == null)
    {
        return;
    }

    _ = try self.addStatement(.{
        .instruction = .{
            .operation = operation,
            .write_operand = write_operand,
            .read_operands = read_operands,
        }
    });

    if (isBlockTerminatorOperation(operation))
    {
        current_block.next = @intCast(u31, self.basic_blocks.items.len);
        current_block.cond_next = null;

        switch (operation)
        {
            .jump => {
                switch (read_operands[0])
                {
                    .symbol => |symbol_index| {
                        const symbol_value = self.symbol_table.items[symbol_index];

                        switch (symbol_value)
                        {
                            .basic_block_index => |basic_block_index| {
                                current_block.next = @intCast(u31, basic_block_index);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            .jumpif => {
                switch (read_operands[1])
                {
                    .symbol => |symbol_index| {
                        const symbol_value = self.symbol_table.items[symbol_index];

                        switch (symbol_value)
                        {
                            .basic_block_index => |basic_block_index| {
                                current_block.cond_next = @intCast(u31, basic_block_index);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }

        try self.beginBasicBlock();
    }
    else if (isProcedureTerminatorOperation(operation))
    {
        current_block.next = null;
        current_block.cond_next = null;
    }
    else 
    {
        current_block.next = @intCast(u31, self.basic_blocks.items.len);
        current_block.cond_next = null;
    }
}

pub fn addStatement(self: *@This(), statement: Statement) !StatementIndex
{
    const current_block = &self.basic_blocks.items[self.basic_blocks.items.len - 1];

    current_block.statement_count += 1;

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