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
token_tags: []const Token.Tag,
token_starts: []const u32,
token_index: u32,
errors: std.ArrayListUnmanaged(Error),

pub fn deinit() void 
{

}

pub fn parse(self: @This()) void 
{
    _ = self;
}

//procedure : proc identifier '{' instruction_block '}'

//instruction_block : instruction_block instruction 
//                  | instruction;

pub fn parseInstructionBlock(self: @This()) void 
{
    while (self.parseInstruction())
    {
        
    }   
}

//instruction : identifier ':' opcode operand_list ';'
//            | opcode operand_list ';'
pub fn parseInstruction(self: @This()) !void 
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
        try parseIntegerLiteral();
    }

    _ = self.eatToken(.semicolon);
}

pub fn parseIntegerLiteral(self: @This()) !u64 
{
    const decimal = self.eatToken(.literal_integer);

    if (decimal != null)
    {
        return;
    }

    const hex = self.eatToken(.literal_hex);

    if (hex != null)
    {
        return;
    }

    const binary = self.eatToken(.literal_binary);

    if (hex != null)
    {
        return;
    }

    return error.ExpectedToken;
}

pub fn eatToken(self: @This(), tag: Token.Tag) ?u32
{
    return if (self.token_tags[self.token_index] == tag) self.nextToken() else null;
}

pub fn expectToken(self: @This(), tag: Token.Tag) !u32
{
    return self.eatToken(tag) orelse return error.ExpectedToken;
}

pub fn nextToken(self: @This()) u32 
{
    const result = self.token_index;
    self.token_index += 1;
    return result;
}