const std = @import("std");
const clap = @import("clap");

pub usingnamespace if (@import("root") == @This()) struct {
    pub const main = run;
} else struct {};

fn run() !void 
{
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

    var history_buffer: [1024]u8 = undefined;
    var history_pointer: usize = 0;

    var history_offset_buffer: [32]usize = undefined;
    var history_offset_buffer_pointer: usize = 0;

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    while (true)
    {
        try stdout.print("cdebug:$ ", .{});

        const command_string = try stdin.readUntilDelimiterOrEof(history_buffer[history_pointer..], '\n') orelse {
            try stdout.print("\n", .{});
            return;
        };

        if (command_string.len == 0) continue;

        history_offset_buffer[history_offset_buffer_pointer] = history_pointer;
        history_offset_buffer_pointer += 1;

        history_pointer += command_string.len;

        const command = try parseCommand(command_string);

        switch (command) {
            .exit => return,
            .load => |load| {
                std.log.info("Loading module {s}...", .{ load.module_path });
            }
        }
    }
}

const Command = union(enum)
{
    exit,
    load: struct 
    {
        module_path: []const u8,
    },
};

fn parseCommand(string: []const u8) !Command
{
    var tokenizer = Tokenizer 
    {
        .source = string,
        .index = 0,
    };

    while (tokenizer.next()) |token|
    {
        switch (token.tag)
        {
            .identifier => {
                const identifier = tokenizer.string(token);

                if (std.mem.eql(u8, identifier, "exit"))
                {
                    return .exit;
                }

                if (std.mem.eql(u8, identifier, "load"))
                {
                    const arg_token = try tokenizer.expect(.literal_string);
                    const arg_string = tokenizer.string(arg_token);

                    return .{
                        .load = .{
                            .module_path = arg_string[1..arg_string.len - 1],
                        },
                    };
                }
            },
            else => return error.ExpectedToken,
        }

        std.log.info("{s}: {s}", .{ @tagName(token.tag), tokenizer.string(token) });
    }

    return error.InvalidCommand;
} 

pub const Tokenizer = struct 
{
    source: []const u8,
    index: usize = 0,

    pub fn next(self: *@This()) ?Token
    {
        var state: enum 
        {
            start,  
            identifier,
            literal_string,
        } = .start;

        var result = Token { .tag = .end, .start = self.index, .end = 0, };

        while (self.index < self.source.len) : (self.index += 1)
        {
            const char = self.source[self.index];
            
            switch (state)
            {
                .start => {
                    switch (char)
                    {
                        0 => break,
                        ' ', '\t', '\r', '\n', => {
                            result.start = self.index + 1;
                        },
                        'a'...'z', 'A'...'Z', '_', => {
                            state = .identifier;
                            result.tag = .identifier;
                        },
                        '"' => {
                            state = .literal_string;
                            result.tag = .literal_string;
                        },
                        '.' => {
                            result.tag = .period;
                            self.index += 1;

                            break;
                        },
                        else => {},
                    }
                },
                .identifier => {
                    switch (char) 
                    {
                        'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                        else => break,
                    }
                },
                .literal_string => {
                    switch (char)
                    {
                        'a'...'z', 'A'...'Z', '0'...'9', ',', ' ', '.', '/', '!', '\n', '\t', '\"' => {},
                        else => break,
                    }
                },
            }
        }

        if (result.tag == .end or self.index > self.source.len)
        {
            return null;
        }

        result.end = self.index;

        return result;
    }

    pub fn eat(self: *@This(), tag: Token.Tag) ?Token
    {
        const source_start = self.index; 

        const next_token = self.next();

        if (next_token == null or next_token.?.tag != tag)
        {
            self.index = source_start;

            return null;
        }
        else 
        {
            return next_token.?;
        }
    }

    pub fn expect(self: *@This(), tag: Token.Tag) !Token
    {
        return self.eat(tag) orelse return error.ExpectedTokenTag;
    }

    pub fn string(self: @This(), token: Token) []const u8
    {
        return self.source[token.start..token.end];
    }

    pub const Token = struct 
    {
        tag: Tag,
        start: usize,
        end: usize,

        pub const Tag = enum 
        {
            end,
            identifier,
            literal_string,
            period,
        };
    };
};