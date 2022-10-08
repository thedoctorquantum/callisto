const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Ast = @import("Ast.zig");
const IR = @import("IR.zig");
const Node = Ast.Node;

pub const Error = union(enum) 
{
    expected_token: struct { 
        tag: Token.Tag,
        offset: u32,
    },
};

allocator: std.mem.Allocator,
source: []const u8,
tokens: std.MultiArrayList(struct {
    tag: Token.Tag,
    start: u32,
    end: u32,
}),
token_tags: []const Token.Tag,
token_starts: []const u32,
token_ends: []const u32,
token_index: u32,
errors: std.ArrayListUnmanaged(Error),
nodes: std.MultiArrayList(Node),
extra_data: std.ArrayListUnmanaged(Node.Index),
ir: IR,
scopes: std.ArrayListUnmanaged(Scope),
scope_patches: std.StringHashMapUnmanaged(struct
{
    token_referenced: u32,
    scope_level: u32,
    scope_closed: bool,
    instruction_index: u32,
    operand_index: u32,
}),
basic_block_patches: std.StringHashMapUnmanaged(struct 
{
    block_end: u32,
}),

pub const Scope = struct 
{
    locals: std.StringHashMapUnmanaged(u32) = .{},
};

pub fn deinit(self: *@This()) void 
{
    self.tokens.deinit(self.allocator);
    self.errors.deinit(self.allocator);
}

fn addNode(p: *@This(), elem: Ast.NodeList.Elem) std.mem.Allocator.Error!Node.Index {
    const result = @intCast(Node.Index, p.nodes.len);
    try p.nodes.append(p.allocator, elem);
    return result;
}

fn setNode(p: *@This(), i: usize, elem: Ast.NodeList.Elem) Node.Index {
    p.nodes.set(i, elem);
    return @intCast(Node.Index, i);
}

fn reserveNode(p: *@This()) !Node.Index {
    try p.nodes.resize(p.allocator, p.nodes.len + 1);
    return @intCast(u32, p.nodes.len - 1);
}

fn addExtra(p: *@This(), extra: anytype) std.mem.Allocator.Error!Node.Index {
    const fields = std.meta.fields(@TypeOf(extra));
    try p.extra_data.ensureUnusedCapacity(p.allocator, fields.len);
    const result = @intCast(u32, p.extra_data.items.len);
    inline for (fields) |field| {
        comptime std.debug.assert(field.field_type == Node.Index);
        p.extra_data.appendAssumeCapacity(@field(extra, field.name));
    }
    return result;
}

pub fn parse(self: *@This()) !IR 
{
    var tokenizer = Tokenizer
    {
        .source = self.source,
        .index = 0,
    };

    while (tokenizer.next()) |token|
    {
        try self.tokens.append(self.allocator, .{ .tag = token.tag, .start = @intCast(u32, token.start), .end = @intCast(u32, token.end) });

        std.log.info("{s}: {s}", .{ @tagName(token.tag), self.source[token.start..token.end] });
    }

    _ = try std.io.getStdErr().write("\n");

    self.token_tags = self.tokens.items(.tag);
    self.token_starts = self.tokens.items(.start);
    self.token_ends = self.tokens.items(.end);

    try self.nodes.append(self.allocator, .{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });

    try self.pushScope();

    while (self.token_index < self.token_tags.len)
    {
        _ = self.parseVar() catch 
        self.parseProcedure() catch 
            return error.ExpectedToken;
    }

    if (self.scope_patches.count() > 0)
    {
        return error.PatchesNotResolved;
    }

    self.popScope();

    return self.ir;
}

fn pushScope(self: *@This()) !void 
{
    try self.scopes.append(self.allocator, .{});
}

fn popScope(self: *@This()) void 
{
    const scope_level = self.scopes.items.len - 1;
    var scope = self.scopes.pop();

    {
        var iter = scope.locals.keyIterator();

        while (iter.next()) |label|
        {
            std.log.info("scope: {s}", .{ label.* });
        }
    }

    {
        var iter = self.scope_patches.keyIterator();

        while (iter.next()) |key|
        {
            const scope_ptr = self.scope_patches.getPtr(key.*) orelse unreachable;

            if (scope_level == scope_ptr.scope_level)
            {
                scope_ptr.scope_closed = true;
            }
        }
    }

    scope.locals.deinit(self.allocator);
}

fn getSymbol(self: *@This(), string: []const u8) !u32
{
    return self.scopes.items[self.scopes.items.len - 1].locals.get(string) orelse self.getSymbolAtScope(string, self.scopes.items.len - 2);
}

fn getSymbolAtScope(self: *@This(), string: []const u8, scope: usize) !u32
{
    return self.scopes.items[scope].locals.get(string) orelse block: {
        if (scope == 0)
        {
            return error.SymbolNotDefined;
        }

        break: block self.getSymbolAtScope(string, scope - 1);
    };
}

fn defineSymbol(self: *@This(), string: []const u8, value: u32) !void
{
    if (self.scope_patches.get(string)) |patch|
    {
        if ((self.scopes.items.len - 1 <= patch.scope_level and !patch.scope_closed) or 
            (self.scopes.items.len - 1 < patch.scope_level and patch.scope_closed))
        {
            self.ir.statements.items[patch.instruction_index].instruction.operands[patch.operand_index] = .{
                .symbol = value
            };

            std.log.info("Patched referenced symbol {s} with value %G{}", .{ string, value });

            _ = self.scope_patches.remove(string);
        }
    }

    if (self.basic_block_patches.get(string)) |patch|
    {
        const block_end_statement = &self.ir.statements.items[patch.block_end];

        const symbol_value = self.ir.symbol_table.items[value]; 

        switch (block_end_statement.*)
        {
            .entry_block_end => {
                const entry_block_end = &block_end_statement.entry_block_end;

                entry_block_end.next = @intCast(u31, symbol_value.basic_block_index);
            },
            .basic_block_end => {
                const basic_block_end = &block_end_statement.basic_block_end;

                basic_block_end.next = @intCast(u31, symbol_value.basic_block_index);
            },
            .exit_block_end => {},
            else => unreachable,
        }
    }

    try self.scopes.items[self.scopes.items.len - 1].locals.put(self.allocator, string, value);
}

fn definePatch(self: *@This(), string: []const u8, instruction_index: u32, operand_index: u32) !void 
{
    try self.scope_patches.put(self.allocator, string, .{
        .token_referenced = self.token_index,
        .scope_level = @intCast(u32, self.scopes.items.len) - 1,
        .instruction_index = instruction_index,
        .operand_index = operand_index,
        .scope_closed = false,
    });
}

pub fn parseVar(self: *@This()) !void
{
    _ = try self.expectToken(.keyword_var);

    const identifier_token = try self.expectToken(.identifier);
    _ = try self.expectToken(.equals);

    const identifier = self.source[self.token_starts[identifier_token]..self.token_ends[identifier_token]];

    const value_token = self.eatToken(.literal_string) orelse 
                        self.parseIntegerLiteral() catch {
        const result = try self.parseBuiltinFunction();

        if (result) |result_value|
        {
            const symbol = try self.ir.addGlobal(.{ 
                .integer = result_value
            });

            try self.defineSymbol(identifier, @intCast(u32, symbol));

            _ = try self.expectToken(.semicolon);

            return;
        }

        return error.SymbolNotDefined;
    };

    _ = try self.expectToken(.semicolon);

    const token_string = self.source[self.token_starts[value_token]..self.token_ends[value_token]];

    switch (self.token_tags[value_token])
    {
        .literal_string => {
            const string = token_string[1..token_string.len - 1];
            const data_offset = self.ir.data.items.len;

            try self.ir.data.appendSlice(self.allocator, string);

            const symbol = try self.ir.addGlobal(.{ 
                .data = .{
                    .offset = @intCast(u32, data_offset), 
                    .size = @intCast(u32, string.len), 
                },
            });

            try self.defineSymbol(identifier, @intCast(u32, symbol));
        },
        .literal_char => {
            const char_string = token_string[1..token_string.len - 1];

            const symbol = try self.ir.addGlobal(.{ 
                .integer = char_string[0] //parse unicode escapes?
            });

            try self.defineSymbol(identifier, @intCast(u32, symbol));
        },
        .literal_integer => {
            const symbol = try self.ir.addGlobal(.{ 
                .integer = @bitCast(u64, try std.fmt.parseInt(i64, token_string, 10))
            });

            try self.defineSymbol(identifier, @intCast(u32, symbol));
        },
        .literal_binary => {
            const symbol = try self.ir.addGlobal(.{ 
                .integer = @bitCast(u64, try std.fmt.parseInt(i64, token_string[2..token_string.len - 1], 2))
            });

            try self.defineSymbol(identifier, @intCast(u32, symbol));
        },
        .literal_hex => {
            const symbol = try self.ir.addGlobal(.{ 
                .integer = @bitCast(u64, try std.fmt.parseInt(i64, token_string[2..token_string.len - 1], 16))
            });

            try self.defineSymbol(identifier, @intCast(u32, symbol));
        },
        else => unreachable,
    }
    
    std.log.info("\nparseVar\n", .{});
}

pub fn parseProcedure(self: *@This()) !void
{
    const is_export = self.eatToken(.keyword_export) != null;

    _ = try self.expectToken(.keyword_proc);

    const identifier_token = try self.expectToken(.identifier);

    const identifier = self.source[self.token_starts[identifier_token]..self.token_ends[identifier_token]];

    if (is_export)
    {
        try self.ir.entry_points.append(self.allocator, @intCast(u32, self.ir.statements.items.len));
    }

    const symbol = try self.ir.addGlobal(.{
        .procedure_index = @intCast(u32, self.ir.statements.items.len)
    });

    try self.defineSymbol(identifier, symbol);

    _ = try self.ir.beginProcedure();

    _ = try self.expectToken(.left_brace);

    try self.pushScope();

    while (true)
    {
        _ = self.parseBlock() catch break;
    }

    _ = try self.expectToken(.right_brace);

    _ = try self.ir.endProcedure();

    self.popScope();

    std.log.info("\nparseProcedure\n", .{});
}

pub fn parseBlock(self: *@This()) !void
{
    const label_token = self.eatToken(.identifier);

    if (label_token != null)
    {
        _ = try self.expectToken(.colon);

        const label = self.source[self.token_starts[label_token.?]..self.token_ends[label_token.?]];

        const symbol = self.ir.symbol_table.items.len;

        try self.ir.symbol_table.append(self.ir.allocator, .{
            .basic_block_index = @intCast(u32, self.ir.statements.items.len)
        });

        try self.defineSymbol(label, @intCast(u32, symbol));

        switch (self.ir.getLastStatement().*)
        {
            .procedure_begin => {
                _ = try self.ir.beginEntryBlock();
            },
            .instruction => {
                _ = try self.ir.beginBasicBlock();
            },
            else => {},
        }
    }

    if (self.eatToken(.left_brace) != null)
    {
        try self.pushScope();

        while (true)
        {
            _ = self.parseBlock() catch break;
        }  

        _ = try self.expectToken(.right_brace);
        
        self.popScope();

        std.log.info("\nparseBlock\n", .{});
    }
    else 
    {
        _ = try self.parseInstruction();
    }
}

pub fn parseInstruction(self: *@This()) !IR.StatementIndex
{
    var success: bool = true;
    errdefer success = false;

    const opcode_token = try self.expectToken(.opcode);

    const opcode = Tokenizer.Token.getOpcode(self.source[self.token_starts[opcode_token]..self.token_ends[opcode_token]]) orelse unreachable;

    const last_statement = self.ir.getLastStatement().*;

    if (IR.isProcedureTerminatorOperation(opcode))
    {
        const block_begin_statement = self.ir.getLastStatementOfTagAny(&.{
            .entry_block_begin,
            .basic_block_begin,
            .exit_block_begin,
        });

        switch (block_begin_statement.?.*)
        {
            .entry_block_begin => {
                // _ = try self.ir.endEntryBlock(null, null);
                _ = try self.ir.beginExitBlock();
            },
            .basic_block_begin => {
                if (last_statement != .basic_block_end)
                {                
                    _ = try self.ir.endBasicBlock(null, null);
                }

                _ = try self.ir.beginExitBlock();
            },
            .exit_block_begin => {
                _ = try self.ir.endExitBlock();
                _ = try self.ir.beginExitBlock();
            },
            else => unreachable,
        }
    }
    else 
    {
        switch (last_statement)
        {
            .procedure_begin => {
                _ = try self.ir.beginEntryBlock();
            },
            .procedure_end => unreachable,
            .entry_block_begin => {},
            .basic_block_begin => {},
            .exit_block_begin => {},
            .entry_block_end,
            .basic_block_end,
            .exit_block_end => {
                _ = try self.ir.beginBasicBlock();
            },
            .instruction => {},
        }
    }

    var operand_index: usize = 0;
    var operands: [3]IR.Statement.Instruction.Operand = .{ .empty, .empty, .empty };

    if (self.eatToken(.semicolon) == null)
    {
        while (true)
        {
            const operand_token = (self.parseIntegerLiteral() catch 
            self.eatToken(.argument_register) orelse 
            self.eatToken(.context_register) orelse 
            self.eatToken(.identifier) orelse
            self.parseBuiltinFunction() catch
                break).?;

            switch (self.token_tags[operand_token])
            {
                .literal_integer => {
                    operands[operand_index] = .{ 
                        .immediate = @bitCast(u64, try std.fmt.parseInt(i64, self.source[self.token_starts[operand_token]..self.token_ends[operand_token]], 10))
                    };
                },
                .literal_binary => {
                    operands[operand_index] = .{ 
                        .immediate = @bitCast(u64, try std.fmt.parseInt(i64, self.source[self.token_starts[operand_token] + 2..self.token_ends[operand_token]], 2))
                    };
                },
                .literal_hex => {
                    operands[operand_index] = .{ 
                        .immediate = @bitCast(u64, try std.fmt.parseInt(i64, self.source[self.token_starts[operand_token] + 2..self.token_ends[operand_token]], 16))
                    };
                },
                .literal_char => {
                    operands[operand_index] = .{ 
                        .immediate = self.token_starts[operand_token]
                    };
                },
                .argument_register => {
                    operands[operand_index] = .{
                        .register = 8 + try std.fmt.parseUnsigned(u4, self.source[self.token_starts[operand_token] + 1..self.token_ends[operand_token]], 10)
                    };
                },
                .context_register => {
                    operands[operand_index] = .{
                        .register = try std.fmt.parseUnsigned(u4, self.source[self.token_starts[operand_token] + 1..self.token_ends[operand_token]], 10)
                    };
                },
                .identifier => {
                    const identifier = self.source[self.token_starts[operand_token]..self.token_ends[operand_token]];
                    const symbol = self.getSymbol(identifier) catch block: 
                    {
                        try self.definePatch(identifier, @intCast(u32, self.ir.statements.items.len), @intCast(u32, operand_index));

                        break :block null;
                    };

                    if (IR.isBlockTerminatorOperation(opcode) and symbol == null and operand_index == 0)
                    {
                        const block_end_index = @intCast(u32, self.ir.statements.items.len) + 1;

                        try self.basic_block_patches.put(self.allocator, identifier, .{
                            .block_end = block_end_index,
                        });

                        std.log.info("block_end_index: {}", .{ block_end_index });
                    }

                    if (symbol != null)
                    {
                        operands[operand_index] = .{
                            .symbol = symbol.?
                        };
                    }
                },
                else => unreachable,
            }

            operand_index += 1;

            if (self.eatToken(.comma) == null)
            {
                break;
            }
        }

        _ = try self.expectToken(.semicolon);
    }

    std.log.info("\nparseInstruction\n", .{});

    const instruction_statement = try self.ir.addInstruction(
        opcode, 
        operands,
    );

    if (IR.isProcedureTerminatorStatement(self.ir.getStatement(instruction_statement).*))
    {
        const block_begin_statement = self.ir.getLastStatementOfTagAny(&.{
            .entry_block_begin,
            .basic_block_begin,
            .exit_block_begin,
        });

        switch (block_begin_statement.?.*)
        {
            .entry_block_begin => {
                _ = try self.ir.endExitBlock();
            },
            .basic_block_begin => {
                _ = try self.ir.endExitBlock();

                block_begin_statement.?.* = .exit_block_begin;
            },
            .exit_block_begin => _ = try self.ir.endExitBlock(),
            else => unreachable,
        }
    }
    else if (IR.isBlockTerminatorStatement(self.ir.getStatement(instruction_statement).*))
    {
        const block_begin_statement = self.ir.getLastStatementOfTagAny(&.{
            .entry_block_begin,
            .basic_block_begin,
            .exit_block_begin,
        });

        var next_block: ?u31 = @intCast(u31, self.ir.statements.items.len + 1);
        var cond_next_block: ?u31 = null;

        switch (self.ir.getStatement(instruction_statement).*)
        {
            .instruction => |terminator_instruction| {
                switch (terminator_instruction.operation) 
                {
                    .jump => {
                        switch (terminator_instruction.operands[0])
                        {
                            .symbol => |symbol_index| {
                                const symbol_value = self.ir.symbol_table.items[symbol_index];

                                switch (symbol_value)
                                {
                                    .basic_block_index => |basic_block_index| {
                                        next_block = @intCast(u31, basic_block_index);
                                    },
                                    else => {  
                                        std.log.info("symbol_index {}", .{ symbol_index });
                                        std.log.info("symbol {}", .{ symbol_value });
                                        unreachable; 
                                    },
                                }
                            },
                            else => {}, 
                        }
                    },
                    .jumpif => {
                        switch (terminator_instruction.operands[1])
                        {
                            .symbol => |symbol_index| {
                                const symbol_value = self.ir.symbol_table.items[symbol_index];

                                switch (symbol_value)
                                {
                                    .basic_block_index => |basic_block_index| {
                                        cond_next_block = @intCast(u31, basic_block_index);
                                    },
                                    else => {},
                                }
                            },
                            else => {}, 
                        }
                    },
                    else => unreachable,
                }
            },
            else => unreachable,
        }

        switch (block_begin_statement.?.*)
        {
            .entry_block_begin => _ = try self.ir.endEntryBlock(next_block, cond_next_block),
            .basic_block_begin => _ = try self.ir.endBasicBlock(next_block, cond_next_block),
            .exit_block_begin => _ = try self.ir.endExitBlock(),
            else => unreachable,
        }
    }
    else 
    {
        const block_begin_statement = self.ir.getLastStatementOfTagAny(&.{
            .entry_block_begin,
            .basic_block_begin,
            .exit_block_begin,
        });

        var next_block: ?u31 = @intCast(u31, self.ir.statements.items.len + 1);
        var cond_next_block: ?u31 = null;

        switch (block_begin_statement.?.*)
        {
            .entry_block_begin => _ = try self.ir.endEntryBlock(next_block, cond_next_block),
            .basic_block_begin => _ = try self.ir.endBasicBlock(next_block, cond_next_block),
            .exit_block_begin => _ = try self.ir.endExitBlock(),
            else => unreachable,
        }
    }

    return instruction_statement;
}

pub fn parseBuiltinFunction(self: *@This()) !?u32
{
    _ = self.eatToken(.dollar);

    const identifier_token = try self.expectToken(.identifier);
    _ = try self.expectToken(.left_paren);

    //should be an expression
    const identifier_param_token = try self.expectToken(.identifier);

    _ = try self.expectToken(.right_paren);

    const identifier = self.source[self.token_starts[identifier_token]..self.token_ends[identifier_token]];

    var result: ?u32 = null;

    //very hardcody...
    //ie huge bodge
    if (std.mem.eql(u8, identifier, "sizeof"))
    {
        const symbol_name = self.source[self.token_starts[identifier_param_token]..self.token_ends[identifier_param_token]];
        const symbol = try self.getSymbol(symbol_name);

        const symbol_value = self.ir.symbol_table.items[symbol];

        switch (symbol_value)
        {
            .data => |data| {
                result = data.size;  
            },
            else => unreachable,
        }
    }

    std.log.info("\nparseBuiltinFunction\n", .{});

    return result;
}

pub fn parseIntegerLiteral(self: *@This()) !u32 
{
    return 
        self.expectToken(.literal_integer) catch
        self.expectToken(.literal_hex) catch 
        self.expectToken(.literal_char) catch 
        try self.expectToken(.literal_binary);
}

pub fn expectToken(self: *@This(), tag: Token.Tag) !u32
{
    errdefer {
        self.errors.append(self.allocator, 
        .{ 
            .expected_token = .{
                .tag = tag,
                .offset = self.token_starts[self.token_index - 1]
            }
        }) catch unreachable;
    }

    const value = self.eatToken(tag) orelse error.ExpectedToken;

    return value;
}

pub fn eatToken(self: *@This(), tag: Token.Tag) ?u32
{
    if (self.token_tags[self.token_index] == tag)
    {
        std.log.info("Ate token: {s}: {s}", .{ @tagName(tag), self.source[self.token_starts[self.token_index]..self.token_ends[self.token_index]] });
    }

    return if (self.token_tags[self.token_index] == tag) self.nextToken() else null;
}

pub fn nextToken(self: *@This()) u32 
{
    const result = self.token_index;
    self.token_index += 1;
    return result;
}