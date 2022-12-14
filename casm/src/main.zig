const std = @import("std");
const clap = @import("clap");

pub const Assembler = @import("Assembler.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const Parser = @import("Parser.zig");
pub const Ast = @import("Ast.zig");
pub const IR = @import("IR.zig");
pub const CodeGenerator = @import("CodeGenerator.zig");

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

    const params = comptime clap.parseParamsComptime(
        \\-h, --help Display this help and exit.
        \\-v, --version Display the version and exit.
        \\-s, --source <str>... Specify callisto assembly source code
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

    for (clap_result.args.source) |source_path|
    {
        std.log.info("{s}", .{ source_path });

        const source_file = try std.fs.cwd().openFile(source_path, .{});
        defer source_file.close(); 

        const source = try source_file.readToEndAlloc(allocator, std.math.maxInt(u32));
        defer allocator.free(source);

        const absolute_path = try std.fs.cwd().realpathAlloc(allocator, source_path);
        defer allocator.free(absolute_path);

        var parser: Parser = .{ 
            .allocator = allocator,  
            .source = source,
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
                .entry_point_procedure = 0,
                .statements = .{},
                .symbol_table = .{},
                .data = .{},
                .entry_points = .{},
            },
            .scopes = .{},
            .scope_patches = .{},
            .basic_block_patches = .{},
        };
        defer parser.tokens.deinit(parser.allocator);
        defer parser.errors.deinit(parser.allocator);

        const ir = parser.parse() catch {
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
                            absolute_path,
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

        _ = try std.io.getStdErr().write("\n");

        std.log.info("basic_syntax.casm parsed successfully", .{});

        //print ir
        {
            std.debug.print("\nIR Statements:\n", .{});

            var procedures = ir.constReachableProcedureIterator();

            while (procedures.next()) |procedure|
            {
                var basic_blocks = ir.constReachableBasicBlockIterator(procedure.*);

                while (basic_blocks.next()) |basic_block|
                {
                    const statements = ir.statements.items[basic_block.statement_offset..basic_block.statement_offset + basic_block.statement_count];

                    for (statements) |statement, statement_index|
                    {
                        switch (statement)
                        {
                            .instruction => |instruction| 
                            {   
                                if (instruction.write_operand != .empty)
                                {
                                    try std.fmt.format(std.io.getStdErr().writer(), "   {:0>2}: %{s} = {s} ", .{ 
                                        statement_index, 
                                        @tagName(instruction.write_operand.register),
                                        @tagName(instruction.operation) 
                                    });
                                }
                                else 
                                {
                                    try std.fmt.format(std.io.getStdErr().writer(), "   {:0>2}: {s} ", .{ statement_index, @tagName(instruction.operation) });
                                }

                                for (instruction.read_operands) |operand|
                                {
                                    switch (operand)
                                    {
                                        .empty => {},
                                        .register => |register| {
                                            try std.fmt.format(std.io.getStdErr().writer(), "%{s}, ", .{ @tagName(register) });
                                        },
                                        .immediate => |immediate| {
                                            try std.fmt.format(std.io.getStdErr().writer(), "{}, ", .{ immediate });
                                        },
                                        .symbol => |symbol| {
                                            try std.fmt.format(std.io.getStdErr().writer(), "$G{}, ", .{ symbol });
                                        },
                                    }
                                }

                                _ = try std.io.getStdErr().write("\n");
                            }
                        }
                    }
                }
            }
        }

        _ = try std.io.getStdErr().write("\nIR Globals: \n"); 

        for (ir.symbol_table.items) |value, i|
        {
            try std.fmt.format(std.io.getStdErr().writer(), "   %G{:0>2}: ", .{ i });

            switch (value)
            {
                .basic_block_index => |index| try std.fmt.format(std.io.getStdErr().writer(), "block: {}", .{ index }), 
                .procedure_index => |index| try std.fmt.format(std.io.getStdErr().writer(), "proc: {}", .{ index }), 
                .imported_procedure => |procedure| try std.fmt.format(std.io.getStdErr().writer(), "import proc: {s}, {}", .{ procedure.name, procedure.index }), 
                .data => |data| try std.fmt.format(std.io.getStdErr().writer(), "{s}", .{ ir.data.items[data.offset..data.offset + data.size] }), 
                .integer => |integer| try std.fmt.format(std.io.getStdErr().writer(), "{}", .{ integer }), 
            }

            _ = try std.io.getStdErr().write("\n");
        }

        var module = try CodeGenerator.generate(allocator, ir);

        if (clap_result.args.interpreter) |interpreter|
        {
            module.interpreter = interpreter;
        }

        const out_module_file_path = "out.csto";

        const out_file = std.fs.cwd().openFile(out_module_file_path, .{ .mode = .read_write }) catch try std.fs.cwd().createFile(out_module_file_path, .{});
        defer out_file.close();

        try out_file.setEndPos(0);
        try out_file.seekTo(0);

        try module.encode(out_file.writer());

        return;
    }

    return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
} 