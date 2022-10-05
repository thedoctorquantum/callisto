const std = @import("std");
const clap = @import("clap");

pub const Vm = @import("Vm.zig");
pub const Assembler = @import("Assembler.zig");
pub const Module = @import("Module.zig");
pub const Parser = @import("Parser.zig");

comptime {
    _ = Parser;
}

fn nativeTest(vm: *Vm) void 
{    
    const a0 = vm.getRegister(.a0);
    const a1 = vm.getRegister(.a1);
            
    vm.setRegister(.a7, a0.* + a1.*);
    
    std.log.info("Hello from nativeTest!", .{});

    (@intToPtr(*allowzero u8, 0)).* = 0; //lol
}

fn envMulAdd(a: u64, b: u64, c: u64) u64 
{
    const res = a * b + c;

    std.log.info("envMulAdd {}", .{ res });

    return res;
}

fn envPow(a: u64, b: u64) u64 
{
    return std.math.pow(u64, a, b);
}

fn puts(string: []const u8) void 
{
    std.io.getStdOut().writer().print("{s}\n", .{ string }) catch unreachable;
}

fn alloc(size: u64) []const u8
{
    return @ptrCast([*]const u8, std.c.malloc(size))[0..size];
}

pub usingnamespace if (@import("root") == @This()) struct {
    pub const main = run;
} else struct {};

fn run() !void 
{       
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer std.debug.assert(!gpa.deinit());
    
    const allocator = gpa.allocator();

    //decode test
    if (false)
    {
        var instructions_buffer = try gpa.allocator().create([1024]u16);
        defer gpa.allocator().destroy(instructions_buffer);

        var code_point: usize = 0;

        const instruction_headers = @ptrCast([*]Vm.InstructionHeader, instructions_buffer)[0..instructions_buffer.len];
        const instruction_registers = @ptrCast([*]Vm.OperandPack, instructions_buffer)[0..instructions_buffer.len];

        //iadd c0, 32, c1;
        instruction_headers[code_point] = Vm.InstructionHeader {
            .opcode = .@"iadd",
            .operand_layout = .register_immediate_register,
            .operand_size = .@"16",
            .immediate_size = .@"16",
        };
        code_point += 1;

        instruction_registers[code_point] = Vm.OperandPack {
            .read_operand = .c0,
            .write_operand = .c1,

            .read_operand1 = undefined,
            .write_operand1 = undefined,
        };
        code_point += 1;

        instructions_buffer[code_point] = 32;
        code_point += 1;

        instruction_headers[code_point] = Vm.InstructionHeader {
            .opcode = .@"unreachable",
            .operand_layout = .none,
            .operand_size = .@"8",
            .immediate_size = .@"8",
        };
        code_point += 1;

        instruction_headers[code_point] = Vm.InstructionHeader {
            .opcode = .@"break",
            .operand_layout = .none,
            .operand_size = .@"8",
            .immediate_size = .@"8",
        };
        code_point += 1;

        instruction_headers[code_point] = Vm.InstructionHeader {
            .opcode = .@"return",
            .operand_layout = .none,
            .operand_size = .@"8",
            .immediate_size = .@"8",
        };
        code_point += 1;

        std.log.info("{any}", .{ instructions_buffer[0..code_point] });

        Vm.decode(instructions_buffer[0..code_point]);
    }

    if (false)
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
        };    

        try parser.parse();
    }

    const params = comptime clap.parseParamsComptime(
        \\-h, --help Display this help and exit.
        \\-v, --version Display the version and exit.
        \\-s, --source <str>... Specify zyte assembly source code
        \\-m, --module <str>... Specify a module to be loaded
        \\-r, --run <str>... Specify a procedure symbol to run 
        \\-o, --out_module <str> Specify the name of the output module
        \\-d, --disassemble <str> Disassemble the contents of a module
        \\-e, --execute <str> Execute the module
        \\-i, --interpreter <str> Specify an interpreter path
        \\<str>
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

    const out_module = clap_result.args.out_module orelse "out.zt";

    for (clap_result.args.source) |source_file| 
    {
        var assembler = Assembler {
            .allocator = allocator,
        };

        const source = try std.fs.cwd().readFileAlloc(allocator, source_file, std.math.maxInt(usize));
        defer allocator.free(source);

        var module = try assembler.assemble(source);
        defer module.sections.deinit(module.allocator);
        defer module.sections_content.deinit(module.allocator);

        if (clap_result.args.interpreter) |interpreter|
        {
            module.interpreter = interpreter;
        }

        const file = std.fs.cwd().openFile(out_module, .{ .mode = .read_write }) catch try std.fs.cwd().createFile(out_module, .{});
        defer file.close();

        try module.encode(file.writer());
    }

    if (clap_result.args.source.len > 0)    
    {
        return;
    }

    if (clap_result.args.disassemble) |module_file_name| 
    {
        const stdout = std.io.getStdOut().writer();

        const module_bytes = try std.fs.cwd().readFileAlloc(allocator, module_file_name, std.math.maxInt(usize));
        defer allocator.free(module_bytes);

        var module = try Module.decode(allocator, module_bytes);
        defer module.sections.deinit(allocator);
        defer module.sections_content.deinit(allocator);

        try stdout.print("Section count: {}\n", .{module.sections.items.len});

        for (module.sections.items) |section, i| 
        {
            try stdout.print("Section {}: id = {s}, size = {}, alignment = {}\n", .{ i, @tagName(section.id), section.content_size, section.content_alignment });
        }

        try stdout.print("\n", .{});

        if (module.getSectionData(.exports, 0)) |exports_bytes| 
        {
            try stdout.print("Exports: \n", .{});

            var offset: usize = 0;

            @setRuntimeSafety(false);

            const header = @ptrCast(*const Module.ExportSectionHeader, @alignCast(@alignOf(Module.ExportSectionHeader), exports_bytes.ptr));

            offset += @sizeOf(Module.ExportSectionHeader);

            var symbol_index: usize = 0;

            const symbol_strings_offset = offset + header.symbol_count * @sizeOf(Module.SymbolExport);

            while (symbol_index < header.symbol_count) : (symbol_index += 1) {
                const symbol = @ptrCast(*const Module.SymbolExport, @alignCast(@alignOf(Module.SymbolExport), exports_bytes.ptr + offset));
                defer offset += @sizeOf(Module.SymbolExport);

                try stdout.print("  Symbol {}: {s} {s} {x:0>8}\n", .{ symbol_index, @tagName(symbol.tag), exports_bytes.ptr[symbol_strings_offset + symbol.offset .. symbol_strings_offset + symbol.offset + symbol.size], symbol.address });
            }

            try stdout.print("\n", .{});
        }

        try stdout.print("Instructions: \n", .{});
        try std.fmt.format(stdout, "    {s: <8}  {s: >2} {s}\n", .{ "address", "op", "name" });

        const instruction_bytes = module.getSectionData(.instructions, 0) orelse unreachable;
        const instruction_code_points = @ptrCast([*]const u16, @alignCast(@alignOf(u16), instruction_bytes.ptr))[0 .. instruction_bytes.len / @sizeOf(u16)];

        {
            @setRuntimeSafety(false);

            var i: usize = 0;

            while (i < instruction_code_points.len)
            {
                const code_point_offset = i; _ = code_point_offset;
                const code_point = instruction_code_points[i];

                const header = @bitCast(Vm.InstructionHeader, code_point);

                try std.fmt.format(stdout, "    {x:0>8}: {x:0>2} {s: <15} ", .{ i * @sizeOf(u16), @enumToInt(header.opcode), @tagName(header.opcode) });

                i += 1;

                switch (header.operand_layout)
                {
                    .none => {},
                    .register => {
                        const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                        i += 1;

                        try std.fmt.format(stdout, "{s}", .{ @tagName(registers.read_operand) });
                    },
                    .register_register => {
                        const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                        i += 1;

                        try std.fmt.format(stdout, "{s}, {s}", .{ @tagName(registers.read_operand), @tagName(registers.write_operand) });
                    },
                    .register_register_register => {
                        const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                        i += 1;

                        try std.fmt.format(stdout, "{s}, {s}, {s}", .{ @tagName(registers.read_operand), @tagName(registers.read_operand1), @tagName(registers.write_operand) });
                    },
                    .register_immediate => {
                        const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                        i += 1;

                        try std.fmt.format(stdout, "{s}, ", .{ @tagName(registers.read_operand) });

                        switch (header.immediate_size)
                        {
                            .@"8" => { 
                                const immediate = instruction_code_points[i];
                                i += 1;

                                try std.fmt.format(stdout, "{x}", .{ immediate });
                            },
                            .@"16" => { 
                                const immediate = instruction_code_points[i];
                                i += 1;

                                try std.fmt.format(stdout, "{x}", .{ immediate });
                            },
                            .@"32" => {
                                const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                                i += 2;

                                try std.fmt.format(stdout, "{x}", .{ immediate });
                            },
                            .@"64" => {
                                const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;
                                i += 4;

                                try std.fmt.format(stdout, "{x}", .{ immediate });
                            },
                        }
                    },
                    .register_immediate_register => {
                        const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                        i += 1;

                        try std.fmt.format(stdout, "{s}, ", .{ @tagName(registers.read_operand) });

                        switch (header.immediate_size)
                        {
                            .@"8" => { 
                                const immediate = instruction_code_points[i];
                                i += 1;

                                try std.fmt.format(stdout, "{x}, ", .{ immediate });
                            },
                            .@"16" => { 
                                const immediate = instruction_code_points[i];
                                i += 1;

                                try std.fmt.format(stdout, "{x}, ", .{ immediate });
                            },
                            .@"32" => {
                                const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                                i += 2;

                                try std.fmt.format(stdout, "{x}, ", .{ immediate });
                            },
                            .@"64" => {
                                const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;

                                i += 4;

                                try std.fmt.format(stdout, "{x}, ", .{ immediate });
                            },
                        }

                        try std.fmt.format(stdout, "{s}", .{ @tagName(registers.write_operand) });
                    },
                    .immediate => {
                        switch (header.immediate_size)
                        {
                            .@"8" => { 
                                const immediate = instruction_code_points[i];
                                i += 1;

                                try std.fmt.format(stdout, "{x}", .{ immediate });
                            },
                            .@"16" => { 
                                const immediate = instruction_code_points[i];
                                i += 1;

                                try std.fmt.format(stdout, "{x}", .{ immediate });
                            },
                            .@"32" => {
                                const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                                i += 2;

                                try std.fmt.format(stdout, "{x}", .{ immediate });
                            },
                            .@"64" => {
                                const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;

                                i += 4;

                                try std.fmt.format(stdout, "{x}", .{ immediate });
                            },
                        }
                    },
                    .immediate_immediate => {
                        var j: usize = 0;

                        while (j < 2) : (j += 1)
                        {
                            switch (header.immediate_size)
                            {
                                .@"8" => { 
                                    const immediate = instruction_code_points[i];
                                    i += 1;

                                    try std.fmt.format(stdout, "{x}, ", .{ immediate });
                                },
                                .@"16" => { 
                                    const immediate = instruction_code_points[i];
                                    i += 1;

                                    try std.fmt.format(stdout, "{x}, ", .{ immediate });
                                },
                                .@"32" => {
                                    const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                                    i += 2;

                                    try std.fmt.format(stdout, "{x}, ", .{ immediate });
                                },
                                .@"64" => {
                                    const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;

                                    i += 4;

                                    try std.fmt.format(stdout, "{x}, ", .{ immediate });
                                },
                            }
                        }
                    },
                    .immediate_register => {
                        const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                        i += 1;

                        switch (header.immediate_size)
                        {
                            .@"8" => { 
                                const immediate = instruction_code_points[i];
                                i += 1;

                                try std.fmt.format(stdout, "{x}, ", .{ immediate });
                            },
                            .@"16" => { 
                                const immediate = instruction_code_points[i];
                                i += 1;

                                try std.fmt.format(stdout, "{x}, ", .{ immediate });
                            },
                            .@"32" => {
                                const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                                i += 2;

                                try std.fmt.format(stdout, "{x}, ", .{ immediate });
                            },
                            .@"64" => {
                                const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;

                                i += 4;

                                try std.fmt.format(stdout, "{x}, ", .{ immediate });
                            },
                        }

                        try std.fmt.format(stdout, "{s}", .{ @tagName(registers.write_operand) });
                    },
                    .immediate_register_register => unreachable,
                    _ => unreachable,
                }

                try std.fmt.format(stdout, "\n", .{});
            }
        }

        return;
    }

    if (clap_result.args.execute != null or clap_result.positionals.len == 1) 
    {
        const module_file_name = clap_result.args.execute orelse clap_result.positionals[0];

        const module_bytes = try std.fs.cwd().readFileAlloc(allocator, module_file_name, std.math.maxInt(usize));
        defer allocator.free(module_bytes);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var module = try Module.decode(arena.allocator(), module_bytes);
        defer module.sections.deinit(arena.allocator());
        defer module.sections_content.deinit(arena.allocator());

        const instructions_bytes = module.getSectionData(.instructions, 0) orelse unreachable;

        var empty_data: [1]u8 = undefined;

        const data = module.getSectionData(.data, 0) orelse empty_data[0..0];

        const instructions = @ptrCast([*]u16, @alignCast(@alignOf(u16), instructions_bytes.ptr))[0 .. instructions_bytes.len / @sizeOf(u16)];

        @setRuntimeSafety(false);

        const available_symbols = &[_][]const u8 
        {
            "nativeTest",
            "envMulAdd",
            "envPow",
            "puts",
            "alloc",
        };    

        _ = available_symbols;  

        //link
        {
            if (module.getSectionData(.imports, 0)) |import_section_data|
            {
                var offset: usize = 0;

                const header = @ptrCast(*const Module.ImportSectionHeader, @alignCast(@alignOf(Module.ImportSectionHeader), import_section_data.ptr));

                offset += @sizeOf(Module.ImportSectionHeader);

                const symbols = @ptrCast([*]const Module.SymbolImport, @alignCast(@alignOf(Module.SymbolImport), import_section_data.ptr + offset))[0..header.symbol_count];

                std.log.info("symbols.len: {}", .{ symbols.len });

                offset += @sizeOf(Module.SymbolImport) * symbols.len;

                for (symbols) |symbol|
                {
                    const symbol_name = (import_section_data.ptr + offset + symbol.offset)[0..symbol.size];

                    std.log.info("Import Symbol: {s}", .{ symbol_name });
                }
            }
        }

        const main_address = if (module.getSectionData(.exports, 0)) |exports_bytes| block: 
        {
            var offset: usize = 0;

            const header = @ptrCast(*const Module.ExportSectionHeader, @alignCast(@alignOf(Module.ExportSectionHeader), exports_bytes.ptr));

            offset += @sizeOf(Module.ExportSectionHeader);

            var symbol_index: usize = 0;

            const symbol_strings_offset = offset + header.symbol_count * @sizeOf(Module.SymbolExport);

            while (symbol_index < header.symbol_count) : (symbol_index += 1) 
            {
                const symbol = @ptrCast(*const Module.SymbolExport, @alignCast(@alignOf(Module.SymbolExport), exports_bytes.ptr + offset));
                defer offset += @sizeOf(Module.SymbolExport);

                const symbol_name = exports_bytes.ptr[symbol_strings_offset + symbol.offset .. symbol_strings_offset + symbol.offset + symbol.size];

                if (std.mem.eql(u8, symbol_name, "main")) 
                {
                    std.log.info("Found symbol main", .{});

                    break :block symbol.address;
                }
            }

            break :block null;
        } else null;

        if (false) if (module.getSectionData(.relocations, 0)) |relocation_data|
        {
            const code_points = @ptrCast([*]u16, @alignCast(@alignOf(u16), instructions_bytes.ptr))[0..instructions_bytes.len / @sizeOf(u16)];

            _ = code_points;

            var offset: usize = 0;

            const header = @ptrCast(*const Module.RelocationSectionHeader, @alignCast(@alignOf(Module.RelocationSectionHeader), relocation_data.ptr));

            offset += @sizeOf(Module.RelocationSectionHeader);

            var relocation_index: usize = 0;

            while (relocation_index < header.relocation_count) : (relocation_index += 1)
            {
                const relocation = @ptrCast(*const Module.Relocation, @alignCast(@alignOf(Module.Relocation), relocation_data.ptr + offset));

                std.log.info("relocation: {}", .{ relocation });

                switch (relocation.address_type)
                {
                    .data => {
                        // instructions[relocation.instruction_address].operands[relocation.operand_index].immediate += @ptrToInt(data.ptr);

                        @setRuntimeSafety(false);

                        @ptrCast(*u64, @alignCast(@alignOf(u64), instructions_bytes.ptr + relocation.address)).* = @ptrToInt(data.ptr);
                    },
                    else => unreachable
                }

                offset += @sizeOf(Module.Relocation);
            }
        };

        _ = main_address;

        try Vm.decode(instructions);

        // var stack: [1024 * 8]u64 = undefined;
        // var call_stack: [64]Vm.CallFrame = undefined;

        // var vm = Vm{
        //     .stack = &stack,
        //     .call_stack = &call_stack,
        //     .natives = &[_]*const fn (*Vm) void {
        //         &nativeTest,
        //         Vm.extFn(envMulAdd),
        //         Vm.extFn(envPow),
        //         Vm.extFn(puts),
        //         Vm.extFn(alloc),
        //     },
        // };

        // vm.init();
        // defer vm.deinit();

        // const executable = Vm.Executable {
        //     .instructions = instructions,
        //     .data = data,
        // };

        // if (main_address) |address| 
        // {
        //     vm.execute(executable, address) catch |err| switch (err) 
        //     {
        //         error.BreakInstruction => std.log.info("Breakpoint hit", .{}),
        //         else => return err,
        //     };
        // }

        return;
    }

    return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
}