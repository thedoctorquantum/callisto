const std = @import("std");
const clap = @import("clap");
const callisto = @import("callisto");

pub usingnamespace if (@import("root") == @This()) struct {
    pub const main = run;
} else struct {};

fn run() !void 
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    // defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    gpa_allocator = allocator;

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

        parseCommand(command_string) catch |e|
        {
            try stdout.print("Error: {}\n", .{ e });
        };
    }
}

const ExecutionContext = struct 
{
    vm: callisto.Vm,
    module: callisto.Module,
    module_instance: callisto.Loader.ModuleInstance,
    module_name: []const u8,
};

var gpa_allocator: std.mem.Allocator = undefined;
var execution_context: ExecutionContext = undefined;

const commands = struct 
{
    pub const module = struct 
    {
        pub fn load(module_path: []const u8) !void 
        {
            std.log.info("Loading module {s}...", .{ module_path });

            const file = try std.fs.cwd().openFile(module_path, .{});
            defer file.close();

            const module_bytes = try file.readToEndAlloc(gpa_allocator, std.math.maxInt(u32));
            defer gpa_allocator.free(module_bytes);

            execution_context.module = try callisto.Module.decode(gpa_allocator, module_bytes);
            execution_context.module_name = module_path;

            execution_context.module_instance = try callisto.Loader.load(gpa_allocator, execution_context.module);

            execution_context.vm.bind(execution_context.module_instance, execution_context.module.entry_point);
        }

        pub fn @"continue"() void 
        {
            execution_context.vm.execute(execution_context.module_instance, .unbounded, 0) catch |e|
            {
                std.debug.print("Module '{s}' returned {}\n", .{ execution_context.module_name, e });
            };
        }

        pub fn show_registers() void
        {
            std.debug.print("   Registers: \n", .{});

            for (execution_context.vm.registers) |register_value, register|
            {
                std.debug.print("       r{}: {x}\n", .{ register, register_value });
            }
        }

        pub fn @"break"(address: u32) void
        {
            std.log.info("breaking at address: {x}", .{ address });
        }
    };
};

const CommandParam = union(enum) 
{
    integer: u64,
    string: []const u8,
};

fn parseCommand(source: []const u8) !void
{
    var tokenizer = Tokenizer 
    {
        .source = source,
        .index = 0,
    };

    var state: enum 
    {
        start,
        namespace,
    } = .start;

    var arguments: [16]CommandParam = undefined;
    var argument_count: usize = 0;

    var command_name_start: usize = 0;
    var command_name_end: usize = 0;

    while (tokenizer.next()) |token|
    {
        switch (state)
        {
            .start => {
                switch (token.tag)
                {
                    .identifier => {
                        state = .namespace;

                        command_name_start = token.start;
                    },
                    .literal_string => {
                        const string = tokenizer.string(token);

                        arguments[argument_count] = .{ .string = string[1..string.len - 1] };
                        argument_count += 1;
                    },
                    .literal_decimal => {
                        arguments[argument_count] = .{ .integer = try std.fmt.parseInt(u64, tokenizer.string(token), 10) };
                        argument_count += 1;
                    },
                    .literal_hex => {
                        arguments[argument_count] = .{ .integer = try std.fmt.parseInt(u64, tokenizer.string(token), 16) };
                        argument_count += 1;
                    },
                    else => unreachable,
                }
            },
            .namespace => {
                switch (token.tag)
                {
                    .identifier => {},
                    .period => {},
                    else => {
                        tokenizer.prev(token);

                        state = .start;
                        command_name_end = tokenizer.index - 1;
                    },
                }                
            },
        }
    }

    switch (state)
    {
        .namespace => {
            command_name_end = tokenizer.index;
        },
        else => {}
    }

    std.log.info("command_name: {s}", .{ tokenizer.source[command_name_start..command_name_end] });

    try dispatchCommand(commands, tokenizer.source[command_name_start..command_name_end], arguments[0..argument_count]);
} 

fn dispatchCommand(comptime namespace: type, command_name: []const u8, arguments: []const CommandParam) !void
{
    const procedure_base_name = "main.commands.";

    const decls = @typeInfo(namespace).Struct.decls; 

    inline for (decls) |decl|
    {
        if (!decl.is_pub) continue;
        if (!@hasDecl(namespace, decl.name)) continue;

        const decl_value = @field(namespace, decl.name);

        if (@TypeOf(decl_value) == type)
        {
            switch (@typeInfo(decl_value))
            {
                .Struct => try dispatchCommand(decl_value, command_name, arguments),
                else => unreachable,
            }
        }
        else 
        {
            const fn_info = @typeInfo(@TypeOf(decl_value)).Fn;
            const full_fn_name = (@typeName(namespace) ++ "." ++ decl.name)[procedure_base_name.len..];

            if (std.mem.eql(u8, full_fn_name, command_name)) 
            {
                const ArgsType = std.meta.ArgsTuple(@TypeOf(decl_value));

                var args: ArgsType = undefined;

                if (arguments.len != fn_info.args.len)
                {
                    std.debug.print("Expected {} arguments, found {}\n", .{ fn_info.args.len, arguments.len });

                    return error.InvalidArgument;
                }

                inline for (fn_info.args) |fn_arg, i|
                {
                    switch (fn_arg.arg_type.?)
                    {
                        []const u8 => {
                            args[i] = arguments[i].string;
                        },
                        i8, i16, i32, i64, u8, u16, u32, u64 => {
                            args[i] = @intCast(fn_arg.arg_type.?, arguments[i].integer);
                        },
                        else => unreachable,
                    }
                }

                switch (@typeInfo(fn_info.return_type.?))
                {
                    .Void => {
                        @call(.{}, decl_value, args);
                    },
                    .ErrorUnion => {
                        _ = try @call(.{}, decl_value, args);
                    },
                    else => unreachable,
                }
            }
        }
    }
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
            literal_decimal,
            literal_hex,
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
                        '0'...'9', '-' => {
                            if (self.index + 1 < self.source.len)
                            {
                                switch (self.source[self.index + 1])
                                {
                                    'X', 'x' => {
                                        state = .literal_hex;
                                        result.tag = .literal_hex;
                                    },
                                    else => {
                                        state = .literal_decimal;
                                        result.tag = .literal_decimal;
                                    },
                                }
                            }
                            else 
                            {
                                state = .literal_decimal;
                            }
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
                .literal_decimal => {
                    switch (char) 
                    {
                        '0'...'9', '_' => {},
                        else => break,
                    }
                },
                .literal_hex => {
                    switch (char) 
                    {
                        '0'...'9', 'a'...'b', 'A'...'B', '_' => {},
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

    pub fn prev(self: *@This(), token: Token) void 
    {
        self.index -= token.end - token.start;
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
            literal_decimal,
            literal_hex,
            period,
        };
    };
};