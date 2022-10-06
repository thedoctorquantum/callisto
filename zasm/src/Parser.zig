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

    self.ir = .{
        .allocator = self.allocator,
        .instructions = .{},
        .symbol_table = .{},
        .data = .{},
    };

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

pub fn defineSymbol(self: *@This(), string: []const u8, value: u32) !void
{
    if (self.scope_patches.get(string)) |patch|
    {
        if ((self.scopes.items.len - 1 <= patch.scope_level and !patch.scope_closed) or 
            (self.scopes.items.len - 1 < patch.scope_level and patch.scope_closed))
        {
            _ = self.scope_patches.remove(string);
        }
    }

    try self.scopes.items[self.scopes.items.len - 1].locals.put(self.allocator, string, value);
}

pub fn definePatch(self: *@This(), string: []const u8, instruction_index: u32, operand_index: u32) !void 
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

    const value_token = self.eatToken(.literal_string) orelse try self.parseIntegerLiteral();

    _ = try self.expectToken(.semicolon);

    const identifier = self.source[self.token_starts[identifier_token]..self.token_ends[identifier_token]];

    switch (self.token_tags[value_token])
    {
        .literal_string => {
            try self.defineSymbol(identifier, 0);
        },
        else => {},
    }
    
    std.log.info("\nparseVar\n", .{});
}

pub fn parseProcedure(self: *@This()) !void
{
    _ = self.eatToken(.keyword_export);

    _ = try self.expectToken(.keyword_proc);

    const identifier_token = try self.expectToken(.identifier);

    const identifier = self.source[self.token_starts[identifier_token]..self.token_ends[identifier_token]];

    try self.defineSymbol(identifier, 0);

    _ = try self.expectToken(.left_brace);

    try self.pushScope();

    while (true)
    {
        _ = self.parseBlock() catch break;
    }   

    _ = try self.expectToken(.right_brace);

    if (self.scope_patches.count() > 0)
    {
        return error.PatchesNotResolved;
    }

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

        try self.defineSymbol(label, 0);
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
        return try self.parseInstruction();
    }
}

pub fn parseInstruction(self: *@This()) !void
{
    const opcode_token = try self.expectToken(.opcode);

    if (self.eatToken(.semicolon) != null) {
        _ = try self.ir.addInstruction(
            Tokenizer.Token.getOpcode(self.source[self.token_starts[opcode_token]..self.token_ends[opcode_token]]) orelse unreachable, 
            undefined
        );

        return;
    }

    var operands: [4]IR.InstructionStatement.Operand = undefined;
    var operand_index: usize = 0;

    while (true)
    {
        const operand_token = self.parseIntegerLiteral() catch 
        self.eatToken(.argument_register) orelse 
        self.eatToken(.context_register) orelse 
        self.eatToken(.identifier) orelse
        self.parseBuiltinFunction() catch
            break;

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
                    try self.definePatch(identifier, @intCast(u32, self.ir.instructions.items.len), @intCast(u32, operand_index));

                    break :block 0;
                };

                _ = symbol;
            },
            else => unreachable,
        }

        operand_index += 1;

        if (self.eatToken(.comma) == null) break;
    }

    _ = try self.expectToken(.semicolon);

    std.log.info("\nparseInstruction\n", .{});

    _ = try self.ir.addInstruction(
        Tokenizer.Token.getOpcode(self.source[self.token_starts[opcode_token]..self.token_ends[opcode_token]]) orelse unreachable, 
        undefined
    );
}

pub fn parseBuiltinFunction(self: *@This()) !Node.Index
{
    _ = self.eatToken(.dollar);

    _ = try self.expectToken(.identifier);
    _ = try self.expectToken(.left_paren);

    //should be an expression

    _ = try self.expectToken(.identifier);

    _ = try self.expectToken(.right_paren);

    std.log.info("\nparseBuiltinFunction\n", .{});

    return 0; //return the "primary" token
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