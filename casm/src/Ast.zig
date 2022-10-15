const std = @import("std");
const Parser = @import("Parser.zig");
const Token = @import("Tokenizer.zig").Token;

allocator: std.mem.Allocator,
source: []const u8,
token_tags: []const Token.Tag,
token_starts: []const u32,
token_ends: []const u32,
errors: []const Parser.Error,
nodes: NodeList,
extra_data: std.ArrayListUnmanaged(Node.Index),

pub const NodeList = std.MultiArrayList(Node);

pub const Node = struct 
{
    tag: Tag,
    main_token: u32,
    data: Data,

    pub const Data = struct 
    {
        left: u32,
        right: u32,
    };

    pub const Tag = enum 
    {
        root,
        var_decl,
        proc_decl,
        instruction,
    };

    pub const Index = u32;

    pub const VarDecl = struct 
    {

    };

    pub const Instruction = struct 
    {
        operands_node: Index,
    };
};

pub fn extraData(tree: @This(), index: usize, comptime T: type) T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    inline for (fields) |field, i| {
        comptime std.debug.assert(field.field_type == Node.Index);
        @field(result, field.name) = tree.extra_data[index + i];
    }
    return result;
}