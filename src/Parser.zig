const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

pub const Error = struct 
{
    tag: Tag,

    pub const Tag = enum 
    {
        expected_opcode,
    };
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
        self.parseProcedure() catch 
        self.parseVar() catch 
            continue;
    }
}

pub fn parseVar(self: *@This()) !void
{
    _ = try self.expectToken(.keyword_var);
    _ = try self.expectToken(.identifier);
    _ = try self.expectToken(.equals);

    _ = self.eatToken(.literal_string) orelse try self.parseIntegerLiteral();

    _ = try self.expectToken(.semicolon);

    std.log.info("parseVar\n", .{});
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
        self.parseInstruction() catch break;
    }   

    _ = try self.expectToken(.right_brace);

    std.log.info("parseProcedure\n", .{});
}

pub fn parseInstruction(self: *@This()) !void 
{
    const label = self.eatToken(.identifier);

    if (label != null)
    {
        _ = try self.expectToken(.semicolon);
    }

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

    std.log.info("parseInstruction\n", .{});
}

pub fn parseBuiltinFunction(self: *@This()) !u32
{
    _ = self.eatToken(.dollar);

    _ = try self.expectToken(.identifier);
    _ = try self.expectToken(.left_paren);

    //should be an expression

    _ = try self.expectToken(.identifier);

    _ = try self.expectToken(.right_paren);

    std.log.info("parseBuiltinFunction\n", .{});

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
    const value = self.eatToken(tag) orelse error.ExpectedToken;

    return value;
}

pub fn eatToken(self: *@This(), tag: Token.Tag) ?u32
{
    if (self.token_tags[self.token_index] == tag)
    {
        std.log.info("Ate token {s} {s}", .{ @tagName(tag), self.source[self.token_starts[self.token_index]..self.token_ends[self.token_index]] });
    }

    return if (self.token_tags[self.token_index] == tag) self.nextToken() else null;
}

pub fn nextToken(self: *@This()) u32 
{
    const result = self.token_index;
    self.token_index += 1;
    return result;
}