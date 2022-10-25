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
    statement_index: u32,
    operand_index: u32,
}),
basic_block_patches: std.StringHashMapUnmanaged(struct 
{
    basic_block: u32,
    is_next: bool,
}),
next_import_index: u32 = 0,

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
    return self.getSymbolAtScope(string, self.scopes.items.len - 1);
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

fn defineSymbol(self: *@This(), string: []const u8, symbol: u32) !void
{
    if (self.scope_patches.get(string)) |patch|
    {
        if ((self.scopes.items.len - 1 <= patch.scope_level and !patch.scope_closed) or 
            (self.scopes.items.len - 1 < patch.scope_level and patch.scope_closed))
        {
            self.ir.statements.items[patch.statement_index].instruction.read_operands[patch.operand_index] = .{
                .symbol = symbol
            };

            std.log.info("Patched referenced symbol {s} with value %G{}", .{ string, symbol });

            _ = self.scope_patches.remove(string);
        }
    }

    if (self.basic_block_patches.get(string)) |patch|
    {
        const basic_block = &self.ir.basic_blocks.items[patch.basic_block];

        const symbol_value = self.ir.symbol_table.items[symbol]; 

        if (patch.is_next)
        {
            basic_block.next = @intCast(u31, symbol_value.basic_block_index);
        }
        else 
        {
            basic_block.cond_next = @intCast(u31, symbol_value.basic_block_index);
        }

        _ = self.basic_block_patches.remove(string);
    }

    try self.scopes.items[self.scopes.items.len - 1].locals.put(self.allocator, string, symbol);
}

fn definePatch(self: *@This(), string: []const u8, statement_index: u32, operand_index: u32) !void 
{
    try self.scope_patches.put(self.allocator, string, .{
        .token_referenced = self.token_index,
        .scope_level = @intCast(u32, self.scopes.items.len) - 1,
        .statement_index = statement_index,
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

            try self.defineSymbol(identifier, symbol);

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
            const string = token_string[1..token_string.len];

            const data_offset = self.ir.data.items.len;
            var data_size: usize = 0;

            //parse the string literal
            {
                var state: enum 
                {
                    start,
                    escape,
                    escape_hex,
                } = .start;

                var char_index: usize = 0;

                while (char_index < string.len) : (char_index += 1)
                {
                    const char = string[char_index];

                    switch (state)
                    {
                        .start => {
                            switch (char)
                            {
                                '\\' => {
                                    state = .escape;
                                },
                                '"' => break,
                                else => {
                                    try self.ir.data.append(self.allocator, char);
                                },
                            }
                        },
                        .escape => {
                            switch (char)
                            {
                                'n' => {
                                    try self.ir.data.append(self.allocator, '\n');
                                    state = .start;
                                },
                                'r' => {
                                    try self.ir.data.append(self.allocator, '\r');
                                    state = .start;
                                },
                                't' => {
                                    try self.ir.data.append(self.allocator, '\t');
                                    state = .start;
                                },
                                '\\' => {
                                    try self.ir.data.append(self.allocator, '\\');
                                    state = .start;
                                },
                                '\'' => {
                                    try self.ir.data.append(self.allocator, '\'');
                                    state = .start;
                                },                                
                                '\"' => {
                                    try self.ir.data.append(self.allocator, '\"');
                                    state = .start;
                                },
                                'x' => {
                                    state = .escape_hex;
                                },
                                else => unreachable,
                            }
                        },
                        .escape_hex => {
                            switch (char)
                            {
                                '0'...'9', 'a'...'f', 'A'...'F' => {},
                                else => {
                                    //\x00.
                                    const digit_offset = char_index - 2;
                                    const digit = try std.fmt.parseUnsigned(u8, string[digit_offset..digit_offset + 2], 16);

                                    std.log.info("hex digit: {s}", .{ string[digit_offset..digit_offset + 2] });

                                    try self.ir.data.append(self.allocator, digit);

                                    state = .start;
                                    char_index -= 1;
                                },
                            }
                        },
                    }
                }

                data_size = self.ir.data.items.len - data_offset;
            }

            // try self.ir.data.appendSlice(self.allocator, string);

            const symbol = try self.ir.addGlobal(.{ 
                .data = .{
                    .offset = @intCast(u32, data_offset), 
                    .size = @intCast(u32, data_size), 
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
    const is_import = self.eatToken(.keyword_import) != null;
    const is_entry = self.eatToken(.keyword_entry) != null;

    _ = try self.expectToken(.keyword_proc);

    if (is_import)
    {
        const identifier = try self.parseNamespacedIdentifier();

        _ = try self.expectToken(.semicolon);

        if (self.getSymbol(identifier) catch null) |symbol_index|
        {
            if (self.ir.symbol_table.items[symbol_index] == .imported_procedure)
            {
                return;
            }
        }
        else 
        {
            const symbol = try self.ir.addGlobal(.{
                .imported_procedure = .{ 
                    .index = self.next_import_index,
                    .name = identifier,
                },
            });

            self.next_import_index += 1;

            std.log.info("Defined import proc {s} as G{}", .{ identifier, symbol });

            try self.defineSymbol(identifier, symbol);

            return;
        }

        return;
    }

    const identifier_token = try self.expectToken(.identifier);
    const identifier = self.source[self.token_starts[identifier_token]..self.token_ends[identifier_token]];

    if (is_entry)
    {
        self.ir.entry_point_procedure = @intCast(u32, self.ir.procedures.items.len);
    }

    if (is_export or is_entry)
    {
        try self.ir.entry_points.append(self.allocator, @intCast(u32, self.ir.procedures.items.len));
    }

    const symbol = try self.ir.addGlobal(.{
        .procedure_index = @intCast(u32, self.ir.procedures.items.len)
    });

    std.log.info("Defined proc {s} as G{}", .{ identifier, symbol });

    try self.defineSymbol(identifier, symbol);

    try self.ir.beginProcedure();

    _ = try self.expectToken(.left_brace);

    try self.pushScope();

    while (true)
    {
        _ = self.parseBlock() catch break;
    }

    _ = try self.expectToken(.right_brace);

    self.popScope();

    std.log.info("\nparseProcedure\n", .{});
}

pub fn parseNamespacedIdentifier(self: *@This()) ![]const u8
{
    var namespaced_identifier = std.ArrayListUnmanaged(u8) {};

    while (true)
    {
        const identifier_token = try self.expectToken(.identifier);

        std.log.info("IDENT: {s}", .{ self.source[self.token_starts[identifier_token]..self.token_ends[identifier_token]] });

        try namespaced_identifier.appendSlice(self.allocator, self.source[self.token_starts[identifier_token]..self.token_ends[identifier_token]]);

        if (self.eatToken(.dot) != null)
        {
            try namespaced_identifier.append(self.allocator, '.');
        }
        else 
        {
            break;
        }
    }

    return namespaced_identifier.items;
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
            .basic_block_index = @intCast(u32, self.ir.basic_blocks.items.len)
        });

        try self.defineSymbol(label, @intCast(u32, symbol));

        try self.ir.beginBasicBlock();
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
        try self.parseInstruction();
    }
}

pub fn parseInstruction(self: *@This()) !void
{
    const write_register = self.eatToken(.context_register) orelse self.eatToken(.argument_register);

    if (write_register != null)
    {
        _ = try self.expectToken(.equals);
    }

    const opcode_token = try self.expectToken(.opcode);

    const opcode = Tokenizer.Token.getOperation(self.source[self.token_starts[opcode_token]..self.token_ends[opcode_token]]) orelse unreachable;

    const basic_block_index = self.ir.basic_blocks.items.len - 1;
    const basic_block = &self.ir.basic_blocks.items[basic_block_index];

    _ = basic_block;

    var write_operand: IR.Statement.Instruction.Operand = .empty;

    if (write_register) |register_token|
    {
        switch (self.token_tags[register_token])
        {
            .argument_register => {
                write_operand = .{
                    .register = Tokenizer.Token.getArgumentRegister(self.source[self.token_starts[register_token]..self.token_ends[register_token]]) orelse unreachable,
                };
            },
            .context_register => {
                write_operand = .{
                    .register = Tokenizer.Token.getContextRegister(self.source[self.token_starts[register_token]..self.token_ends[register_token]]) orelse unreachable
                };
            },
            else => unreachable,
        }
    }

    var read_operand_index: usize = 0;
    var read_operands: [2]IR.Statement.Instruction.Operand = .{ .empty, .empty };

    while (true)
    {
        const operand_token = (self.parseIntegerLiteral() catch 
        self.eatToken(.argument_register) orelse 
        self.eatToken(.context_register) orelse 
        self.parseBuiltinFunction() catch
            {                    
                const identifier = self.parseNamespacedIdentifier() catch break;

                const symbol = self.getSymbol(identifier) catch block: 
                {
                    try self.definePatch(identifier, @intCast(u32, self.ir.statements.items.len), @intCast(u32, read_operand_index));

                    if (IR.isBlockTerminatorOperation(opcode))
                    {
                        try self.basic_block_patches.put(self.allocator, identifier, .{
                            .basic_block = @intCast(u32, basic_block_index),
                            .is_next = opcode == .jump,
                        });
                    }

                    break :block null;
                };

                if (symbol != null)
                {
                    read_operands[read_operand_index] = .{
                        .symbol = symbol.?
                    };
                }

                read_operand_index += 1;

                if (self.eatToken(.comma) == null)
                {
                    break;
                }

                continue;
            }).?;

        switch (self.token_tags[operand_token])
        {
            .literal_integer => {
                read_operands[read_operand_index] = .{ 
                    .immediate = @bitCast(u64, try std.fmt.parseInt(i64, self.source[self.token_starts[operand_token]..self.token_ends[operand_token]], 10))
                };
            },
            .literal_binary => {
                read_operands[read_operand_index] = .{ 
                    .immediate = @bitCast(u64, try std.fmt.parseInt(i64, self.source[self.token_starts[operand_token] + 2..self.token_ends[operand_token]], 2))
                };
            },
            .literal_hex => {
                read_operands[read_operand_index] = .{ 
                    .immediate = @bitCast(u64, try std.fmt.parseInt(i64, self.source[self.token_starts[operand_token] + 2..self.token_ends[operand_token]], 16))
                };
            },
            .literal_char => {
                const char_literal = self.source[self.token_starts[operand_token]..self.token_ends[operand_token]];

                read_operands[read_operand_index] = .{ 
                    .immediate = char_literal[1]
                };
            },
            .argument_register => {
                read_operands[read_operand_index] = .{
                    .register = Tokenizer.Token.getArgumentRegister(self.source[self.token_starts[operand_token]..self.token_ends[operand_token]]) orelse unreachable,
                };
            },
            .context_register => {
                read_operands[read_operand_index] = .{
                    .register = Tokenizer.Token.getContextRegister(self.source[self.token_starts[operand_token]..self.token_ends[operand_token]]) orelse unreachable
                };
            },
            else => unreachable,
        }

        read_operand_index += 1;

        if (self.eatToken(.comma) == null)
        {
            break;
        }
    }

    _ = try self.expectToken(.semicolon);

    std.log.info("\nparseInstruction\n", .{});

    _ = try self.ir.addInstruction(
        opcode,
        write_operand, 
        read_operands,
    );
}

pub fn parseBuiltinFunction(self: *@This()) !?u32
{
    //save the beginning token and restore it on error
    const token_start = self.token_index;
    errdefer self.token_index = token_start;

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