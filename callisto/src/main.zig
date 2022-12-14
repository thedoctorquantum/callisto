const std = @import("std");
const clap = @import("clap");
const casm = @import("casm");

const Assembler = casm.Assembler;
const Tokenizer = casm.Tokenizer;
const Parser = casm.Parser;

pub const Vm = @import("Vm.zig");
pub const Module = @import("Module.zig");
pub const Loader = @import("Loader.zig");

pub usingnamespace if (@import("root") == @This()) struct {
    pub const main = run;
} else struct {};

fn run() !void 
{       
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    
    const allocator = gpa.allocator();

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

    const out_module = clap_result.args.out_module orelse "out.zt";

    //Currently the assembler is not compiling
    clap_result.args.source.len = 0;

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

        if (false)
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
                    // .register => {
                    //     const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                    //     i += 1;

                    //     try std.fmt.format(stdout, "{s}", .{ @tagName(registers.read_operand) });
                    // },
                    // .register_register => {
                    //     const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                    //     i += 1;

                    //     try std.fmt.format(stdout, "{s}, {s}", .{ @tagName(registers.read_operand), @tagName(registers.write_operand) });
                    // },
                    // .register_register_register => {
                    //     const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                    //     i += 1;

                    //     try std.fmt.format(stdout, "{s}, {s}, {s}", .{ @tagName(registers.read_operand), @tagName(registers.read_operand1), @tagName(registers.write_operand) });
                    // },
                    // .register_immediate => {
                    //     const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                    //     i += 1;

                    //     try std.fmt.format(stdout, "{s}, ", .{ @tagName(registers.read_operand) });

                    //     switch (header.immediate_size)
                    //     {
                    //         .@"8" => { 
                    //             const immediate = instruction_code_points[i];
                    //             i += 1;

                    //             try std.fmt.format(stdout, "{x}", .{ immediate });
                    //         },
                    //         .@"16" => { 
                    //             const immediate = instruction_code_points[i];
                    //             i += 1;

                    //             try std.fmt.format(stdout, "{x}", .{ immediate });
                    //         },
                    //         .@"32" => {
                    //             const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                    //             i += 2;

                    //             try std.fmt.format(stdout, "{x}", .{ immediate });
                    //         },
                    //         .@"64" => {
                    //             const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;
                    //             i += 4;

                    //             try std.fmt.format(stdout, "{x}", .{ immediate });
                    //         },
                    //     }
                    // },
                    // .register_immediate_register => {
                    //     const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                    //     i += 1;

                    //     try std.fmt.format(stdout, "{s}, ", .{ @tagName(registers.read_operand) });

                    //     switch (header.immediate_size)
                    //     {
                    //         .@"8" => { 
                    //             const immediate = instruction_code_points[i];
                    //             i += 1;

                    //             try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //         },
                    //         .@"16" => { 
                    //             const immediate = instruction_code_points[i];
                    //             i += 1;

                    //             try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //         },
                    //         .@"32" => {
                    //             const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                    //             i += 2;

                    //             try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //         },
                    //         .@"64" => {
                    //             const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;

                    //             i += 4;

                    //             try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //         },
                    //     }

                    //     try std.fmt.format(stdout, "{s}", .{ @tagName(registers.write_operand) });
                    // },
                    // .immediate => {
                    //     switch (header.immediate_size)
                    //     {
                    //         .@"8" => { 
                    //             const immediate = instruction_code_points[i];
                    //             i += 1;

                    //             try std.fmt.format(stdout, "{x}", .{ immediate });
                    //         },
                    //         .@"16" => { 
                    //             const immediate = instruction_code_points[i];
                    //             i += 1;

                    //             try std.fmt.format(stdout, "{x}", .{ immediate });
                    //         },
                    //         .@"32" => {
                    //             const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                    //             i += 2;

                    //             try std.fmt.format(stdout, "{x}", .{ immediate });
                    //         },
                    //         .@"64" => {
                    //             const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;

                    //             i += 4;

                    //             try std.fmt.format(stdout, "{x}", .{ immediate });
                    //         },
                    //     }
                    // },
                    // .immediate_immediate => {
                    //     var j: usize = 0;

                    //     while (j < 2) : (j += 1)
                    //     {
                    //         switch (header.immediate_size)
                    //         {
                    //             .@"8" => { 
                    //                 const immediate = instruction_code_points[i];
                    //                 i += 1;

                    //                 try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //             },
                    //             .@"16" => { 
                    //                 const immediate = instruction_code_points[i];
                    //                 i += 1;

                    //                 try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //             },
                    //             .@"32" => {
                    //                 const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                    //                 i += 2;

                    //                 try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //             },
                    //             .@"64" => {
                    //                 const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;

                    //                 i += 4;

                    //                 try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //             },
                    //         }
                    //     }
                    // },
                    // .immediate_register => {
                    //     const registers = @bitCast(Vm.OperandPack, instruction_code_points[i]);
                    //     i += 1;

                    //     switch (header.immediate_size)
                    //     {
                    //         .@"8" => { 
                    //             const immediate = instruction_code_points[i];
                    //             i += 1;

                    //             try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //         },
                    //         .@"16" => { 
                    //             const immediate = instruction_code_points[i];
                    //             i += 1;

                    //             try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //         },
                    //         .@"32" => {
                    //             const immediate = @ptrCast(*align(1) const u32, &instruction_code_points[i]).*;
                    //             i += 2;

                    //             try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //         },
                    //         .@"64" => {
                    //             const immediate = @ptrCast(*align(1) const u64, &instruction_code_points[i]).*;

                    //             i += 4;

                    //             try std.fmt.format(stdout, "{x}, ", .{ immediate });
                    //         },
                    //     }

                    //     try std.fmt.format(stdout, "{s}", .{ @tagName(registers.write_operand) });
                    // },
                    // .immediate_register_register => unreachable,
                    // _ => unreachable,
                    else => {},
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

        const module_instance = try Loader.load(arena.allocator(), module);
        defer Loader.unload(arena.allocator(), module_instance);

        {
            var vm = Vm { };

            vm.bind(module_instance, module.entry_point);

            while (true)
            {
                const result = vm.execute(module_instance, .unbounded, 0);

                if (result.trap) |trap|
                {
                    switch (trap)
                    {
                        .break_instruction => {
                            continue;
                        },
                        else => {
                            std.debug.print("Error: {}\n", .{ trap });

                            return;
                        },
                    }
                }

                break;
            }
        }

        return;
    }

    return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
}