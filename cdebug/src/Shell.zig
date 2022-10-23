const Shell = @This();
const std = @import("std");
const callisto = @import("callisto");

allocator: std.mem.Allocator,
stdout_allocator: std.mem.Allocator,
execution_context: ExecutionContext,

const ExecutionContext = struct 
{
    vm: callisto.Vm,
    module: callisto.Module,
    module_instance: callisto.Loader.ModuleInstance,
    module_name: []const u8,

    break_points: std.ArrayListUnmanaged(BreakPoint),

    pub const BreakPoint = struct
    {
        address: u32,
        original_opcode: callisto.Vm.OpCode,
    };
};

pub fn init(self: Shell) void 
{
    _ = self;
}

pub fn deinit(self: Shell) void 
{
    _ = self;
}

pub fn print(self: Shell, comptime format: []const u8, args: anytype) void 
{
    _ = std.fmt.allocPrint(self.stdout_allocator, format, args) catch unreachable;
}

pub fn execute(self: *Shell, source: []const u8) !void 
{
    try parseCommand(self, source);
}

pub const commands = struct 
{
    pub fn help(shell: Shell) void 
    {
        shell.print("\nCommands:\n", .{});
        defer shell.print("\n", .{});

        printHelp(shell, commands);
    } 

    fn printHelp(shell: Shell, comptime namespace: type) void 
    {
        const decls = @typeInfo(namespace).Struct.decls;

        inline for (decls) |decl|
        {
            if (!decl.is_pub) continue;

            const decl_value = @field(namespace, decl.name);

            if (@TypeOf(decl_value) == type)
            {
                printHelp(shell, decl_value);
            }
            else 
            {
                const name = (@typeName(namespace) ++ "." ++ decl.name)[(@typeName(commands) ++ ".").len..];

                shell.print("   " ++ name, .{});

                const fn_info = @typeInfo(@TypeOf(decl_value)).Fn;

                if (fn_info.args.len > 1)
                {
                    shell.print(":", .{});
                }

                inline for (fn_info.args[1..]) |arg, i|
                {
                    shell.print(" " ++ @typeName(arg.arg_type.?), .{});

                    if (i < fn_info.args.len - 1)
                    {
                        shell.print(",", .{});
                    }
                }

                shell.print("\n", .{});
            }
        }
    }

    pub fn clear(_: Shell) !void 
    {
        return error.NotImplemented;
    }

    pub fn exit(_: Shell) noreturn
    {
        std.os.exit(0);
    } 

    pub const module = struct 
    {
        pub fn load(shell: *Shell, module_path: []const u8) !void 
        {
            shell.print("Loading module {s}...\n", .{ module_path });

            const file = try std.fs.cwd().openFile(module_path, .{});
            defer file.close();

            const module_bytes = try file.readToEndAlloc(shell.allocator, std.math.maxInt(u32));
            defer shell.allocator.free(module_bytes);

            shell.execution_context.module = try callisto.Module.decode(shell.allocator, module_bytes);
            shell.execution_context.module_name = module_path;

            shell.execution_context.module_instance = try callisto.Loader.load(shell.allocator, shell.execution_context.module);

            shell.execution_context.vm.bind(shell.execution_context.module_instance, shell.execution_context.module.entry_point);
            shell.execution_context.break_points = .{};
        }

        pub fn @"continue"(shell: *Shell) !void 
        {
            const result = shell.execution_context.vm.execute(shell.execution_context.module_instance, .unbounded, 0);

            if (result.trap) |trap|
            {
                switch (trap)
                {
                    .break_instruction => {
                        const instructions_begin = @ptrCast([*]align(2) u8, shell.execution_context.module_instance.instructions.ptr);
                        
                        const address = @ptrToInt(result.last_instruction) - @ptrToInt(instructions_begin);

                        var original_opcode: ?callisto.Vm.OpCode = null;

                        const is_user_made: bool = block: {
                            for (shell.execution_context.break_points.items) |break_point|
                            {
                                if (break_point.address == address)
                                {
                                    original_opcode = break_point.original_opcode;

                                    break :block true;
                                }
                            }

                            break :block false;
                        };

                        if (is_user_made)
                        {
                            const instruction_code_point: *u16 = @ptrCast(*u16, result.last_instruction);

                            const current_header = @ptrCast(*callisto.Vm.InstructionHeader, instruction_code_point);

                            current_header.opcode = original_opcode.?;

                            shell.execution_context.vm.instruction_pointer = result.last_instruction;

                            _ = shell.execution_context.vm.execute(shell.execution_context.module_instance, .bounded, 1);

                            current_header.opcode = .ebreak;
                        }

                        shell.print("Hit breakpoint at 0x{x}\n", .{ address });
                    },
                    else => return error.ErrorTrap,
                }
            }
        }

        pub fn show_registers(shell: Shell) void
        {
            shell.print("   Registers: \n", .{});

            for (shell.execution_context.vm.registers) |register_value, register|
            {
                shell.print("       r{}: {x}\n", .{ register, register_value });
            }
        }

        pub fn @"break"(shell: *Shell, address: u32) !void
        {
            if (address % 2 != 0)
            {
                return error.InvalidAddress;
            }

            if (address > shell.execution_context.module_instance.instructions.len * 2)
            {
                return error.InvalidAddress;
            }

            shell.print("breaking at address: 0x{x}\n", .{ address });

            const old_header = @bitCast(callisto.Vm.InstructionHeader, shell.execution_context.module_instance.instructions[address / 2]);

            shell.execution_context.module_instance.instructions[address / 2] = @bitCast(u16, 
                callisto.Vm.InstructionHeader
                {
                    .opcode = .ebreak,
                    .operand_layout = old_header.operand_layout,
                    .operand_size = old_header.operand_size,
                    .immediate_size = old_header.immediate_size,
                }
            );

            try shell.execution_context.break_points.append(shell.allocator, .{
                .address = address,
                .original_opcode = old_header.opcode,
            });
        }

        pub fn unbreak(shell: *Shell, address: u32) !void
        {
            if (address % 2 != 0)
            {
                return error.InvalidAddress;
            }

            if (address > shell.execution_context.module_instance.instructions.len * 2)
            {
                return error.InvalidAddress;
            }

            var break_point_index: usize = 0;

            const is_user_made: bool = block: {
                for (shell.execution_context.break_points.items) |break_point, i|
                {
                    if (break_point.address == address)
                    {
                        break_point_index = i;

                        break :block true;
                    }
                }

                break :block false;
            };

            if (!is_user_made)
            {
                shell.print("Instruction {} is not a user made breakpoint\n", .{ address });

                return error.NotUserMade;
            }

            shell.print("unbreaking at address: 0x{x}\n", .{ address });

            const break_point = shell.execution_context.break_points.swapRemove(break_point_index);

            const header = @ptrCast(*callisto.Vm.InstructionHeader, shell.execution_context.module_instance.instructions.ptr + break_point.address);

            header.opcode = break_point.original_opcode; 
        }
    };
};

const CommandParam = union(enum) 
{
    integer: u64,
    string: []const u8,
};

fn parseCommand(shell: *Shell, source: []const u8) !void
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
                        arguments[argument_count] = .{ .integer = try std.fmt.parseInt(u64, tokenizer.string(token), 0) };
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

    const command_name = tokenizer.source[command_name_start..command_name_end];
    const executed = try dispatchCommand(shell, commands, command_name, arguments[0..argument_count]);

    if (!executed)
    {
        shell.print("Could not find command '{s}'\n", .{ command_name });

        return error.InvalidCommand;
    }
} 

fn dispatchCommand(shell: *Shell, comptime namespace: type, command_name: []const u8, arguments: []const CommandParam) !bool
{
    // const procedure_base_name = "main.commands.";
    const procedure_base_name = @typeName(commands) ++ ".";

    const decls = @typeInfo(namespace).Struct.decls; 

    var executed: bool = false;

    inline for (decls) |decl|
    {
        if (!decl.is_pub) continue;
        if (!@hasDecl(namespace, decl.name)) continue;

        const decl_value = @field(namespace, decl.name);

        if (@TypeOf(decl_value) == type)
        {
            switch (@typeInfo(decl_value))
            {
                .Struct => executed = try dispatchCommand(shell, decl_value, command_name, arguments) or executed,
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

                if (arguments.len != fn_info.args.len - 1)
                {
                    shell.print("Expected {} arguments, found {}\n", .{ fn_info.args.len, arguments.len });

                    return error.InvalidArgument;
                }

                if (@TypeOf(args[0]) == *Shell)
                {
                    args[0] = shell;
                }
                else 
                {
                    args[0] = shell.*;
                }

                inline for (fn_info.args[1..]) |fn_arg, i|
                {
                    switch (fn_arg.arg_type.?)
                    {
                        []const u8 => {
                            args[i + 1] = arguments[i].string;
                        },
                        i8, i16, i32, i64, u8, u16, u32, u64 => {
                            args[i + 1] = @intCast(fn_arg.arg_type.?, arguments[i].integer);
                        },
                        else => comptime unreachable,
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
                    .NoReturn => {
                        @call(.{}, decl_value, args);
                    },
                    else => comptime unreachable,
                }

                executed = true;
            }
        }
    }

    return executed;
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
                        else => {
                            self.index += 1;
                            break;
                        },
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
                        'X', 'x', '0'...'9', 'a'...'f', 'A'...'F', '_' => {},
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
        self.index = token.start;
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