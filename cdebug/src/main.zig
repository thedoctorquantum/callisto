const std = @import("std");
const clap = @import("clap");
const callisto = @import("callisto");

pub const Shell = @import("Shell.zig");

pub usingnamespace if (@import("root") == @This()) struct {
    pub const main = run;
} else struct {};

fn run() !void 
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    // defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help Display this help and exit.
        \\-v, --version Display the version and exit.
    );
        
    var clap_result = try clap.parse(clap.Help, &params, clap.parsers.default, .{});
    defer clap_result.deinit();
    
    if (clap_result.args.help)
    {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }   
        
    if (clap_result.args.version)
    {
        return try std.io.getStdErr().writer().print("{s}\n", .{ "0.1.0" });
    }

    var command_buffer: [1024]u8 = undefined;
    
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    if (!std.io.getStdIn().isTty() or !std.io.getStdIn().supportsAnsiEscapeCodes())
    {
        std.debug.print("Error: stdin must be a ansi capable tty\n", .{});

        return;
    }

    var stdout_allocator = std.heap.StackFallbackAllocator(4096) {
        .buffer = undefined,
        .fallback_allocator = allocator,
        .fixed_buffer_allocator = undefined,
    };

    stdout_allocator.fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&stdout_allocator.buffer);

    var shell = Shell 
    {
        .allocator = allocator,
        .stdout_allocator = stdout_allocator.get(),
        .execution_context = undefined,
    };

    while (true)
    {
        try stdout.print("cdebug:$ ", .{});

        const command_string = try stdin.readUntilDelimiterOrEof(&command_buffer, '\n') orelse {
            try stdout.print("\n", .{});
            return;
        };

        if (command_string.len == 0) continue;

        const execute_result = shell.execute(command_string);

        if (stdout_allocator.fixed_buffer_allocator.end_index != 0)
        {
            _ = try stdout.write(stdout_allocator.buffer[0..stdout_allocator.fixed_buffer_allocator.end_index]);

            stdout_allocator.fixed_buffer_allocator.reset();
        }

        _ = execute_result catch |e|
        {
            try stdout.print("Error: {}\n", .{ e });
        };
    }
}