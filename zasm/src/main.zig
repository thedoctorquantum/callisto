const std = @import("std");
const clap = @import("clap");

pub const Assembler = @import("Assembler.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const Parser = @import("Parser.zig");
pub const Ast = @import("Ast.zig");

pub usingnamespace if (@import("root") == @This()) struct {
    pub const main = run;
} else struct {};

fn traverseTree(ast: Ast, node: Ast.Node.Index) void
{
    const node_data = ast.nodes.get(node);

    switch (node_data.tag)
    {
        else => std.log.info("Node: {s}", .{ @tagName(node_data.tag) }),
    }

    if (node_data.data.left != 0)
    {
        traverseTree(ast, node_data.data.left);
    }
    
    if (node_data.data.right != 0)
    {
        traverseTree(ast, node_data.data.right);
    }
}

///Command line interface driver
fn run() !void
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    // defer std.debug.assert(!gpa.deinit());

    const allocator = gpa.allocator();

    {
        var parser: Parser = .{ 
            .allocator = allocator,  
            .source = @embedFile("basic_syntax.zasm"),
            .tokens = .{},
            .token_tags = &.{},
            .token_starts = &.{},
            .token_ends = &.{},
            .token_index = 0,
            .errors = .{},
            .nodes = .{},
            .extra_data = .{},
            .ir = .{
                .allocator = allocator,
                .instructions = .{},
                .symbol_table = .{},
                .data = .{},
            },
            .scopes = .{},
            .scope_patches = .{},
        };
        defer parser.tokens.deinit(parser.allocator);
        defer parser.errors.deinit(parser.allocator);

        const ir = parser.parse() catch |e| {

            if (true)
            {
                return e;
            }

            for (parser.errors.items) |error_union|
            {
                switch (error_union)
                {
                    .expected_token => |expected_token|
                    {
                        const line_number = std.mem.count(u8, parser.source[0..expected_token.offset], "\n");

                        var line_begin: usize = expected_token.offset;
                        var line_end: usize = expected_token.offset;

                        while (line_begin >= 0)
                        {
                            const char = parser.source[line_begin];

                            switch (char)
                            {
                                '\n', '\r', 0 => break,
                                else => line_begin -= 1,
                            }
                        }

                        while (line_end < parser.source.len)
                        {
                            const char = parser.source[line_end];

                            switch (char)
                            {
                                '\n', '\r', 0 => break,
                                else => line_end += 1,
                            }
                        }

                        const column = line_end - line_begin;

                        try std.fmt.format(std.io.getStdErr().writer(), "Error: expected '{s}' at {s}:{}:{}\n", 
                        .{  
                            Tokenizer.Token.lexeme(expected_token.tag) orelse @tagName(expected_token.tag), 
                            "/home/zak/Dev/Zig/Zyte/zasm/src/basic_syntax.zasm",
                            line_number + 1, 
                            column 
                        });

                        try std.fmt.format(std.io.getStdErr().writer(), "{s}\n", .{ parser.source[line_begin..line_end] });

                        {
                            var i: usize = 0;

                            while (i < column - 1) : (i += 1)
                            {
                                _ = try std.io.getStdErr().write("~");
                            }
                            
                            _ = try std.io.getStdErr().write("^");
                        }

                        _ = try std.io.getStdErr().write("\n");
                    }
                }
            }

            return;
        };

        {
            var i: u32 = 0;

            while (i < ir.instructions.items.len)
            {
                const instruction = ir.instructions.items[i];

                std.log.info("{s}", .{ @tagName(instruction.operation) });

                i = instruction.next;
            }
        }

        std.log.info("basic_syntax.zasm parsed successfully", .{});

        return;
    }

    const params = comptime clap.parseParamsComptime(
        \\-h, --help Display this help and exit.
        \\-v, --version Display the version and exit.
        \\-s, --source <str>... Specify zyte assembly source code
        \\-m, --module <str>... Specify a module to be loaded
        \\-o, --out_module <str> Specify the name of the output module
        \\-i, --interpreter <str> Specify an interpreter path
    );
        
    const clap_result = try clap.parse(clap.Help, &params, clap.parsers.default, .{});
    defer clap_result.deinit();

    if (clap_result.args.help)
    {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }   
        
    if (clap_result.args.version)
    {
        return try std.io.getStdErr().writer().print("{s}\n", .{ "0.1.0" });
    }

    return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
} 