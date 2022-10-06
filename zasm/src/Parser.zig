const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

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

pub fn deinit(self: *@This()) void 
{
    self.tokens.deinit(self.allocator);
    self.errors.deinit(self.allocator);
}

pub fn parse(self: *@This()) !void 
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

    while (self.token_index < self.token_tags.len)
    {
        self.parseVar() catch 
        self.parseProcedure() catch 
            return error.ExpectedToken;
    }
}

pub fn parseVar(self: *@This()) !void
{
    _ = try self.expectToken(.keyword_var);
    _ = try self.expectToken(.identifier);
    _ = try self.expectToken(.equals);

    _ = self.eatToken(.literal_string) orelse try self.parseIntegerLiteral();

    _ = try self.expectToken(.semicolon);

    std.log.info("\nparseVar\n", .{});
}

pub fn parseProcedure(self: *@This()) !void 
{
    _ = self.eatToken(.keyword_export);

    _ = try self.expectToken(.keyword_proc);

    const identifier = try self.expectToken(.identifier);

    _ = identifier;

    _ = try self.expectToken(.left_brace);

    while (true)
    {
        self.parseBasicBlock() catch break;
    }   

    _ = try self.expectToken(.right_brace);

    std.log.info("\nparseProcedure\n", .{});
}

pub fn parseBasicBlock(self: *@This()) !void
{
    const label = self.eatToken(.identifier);

    if (label != null)
    {
        _ = try self.expectToken(.colon);
    }

    if (self.eatToken(.left_brace) != null)
    {
        while (true)
        {
            self.parseBasicBlock() catch break;
        }  

        _ = try self.expectToken(.right_brace);

        std.log.info("\nparseBasicBlock\n", .{});
    }
    else 
    {
        try self.parseInstruction();
    }
}

pub fn parseInstruction(self: *@This()) !void 
{
    const opcode = try self.expectToken(.opcode);

    _ = opcode;

    if (self.eatToken(.semicolon) != null) return;

    while (true)
    {
        _ = self.parseIntegerLiteral() catch 
        self.eatToken(.argument_register) orelse 
        self.eatToken(.context_register) orelse 
        self.eatToken(.identifier) orelse
        self.parseBuiltinFunction() catch
            break;

        if (self.eatToken(.comma) == null) break;
    }

    _ = try self.expectToken(.semicolon);

    std.log.info("\nparseInstruction\n", .{});
}

pub fn parseBuiltinFunction(self: *@This()) !u32
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