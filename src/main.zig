const std = @import("std");
const clap = @import("clap");

pub const Vm = @import("Vm.zig");
pub const Assembler = @import("Assembler.zig");
pub const Module = @import("Module.zig");

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
    std.io.getStdOut().writer().print("puts: {s}\n", .{ string }) catch unreachable;
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

    const out_module = clap_result.args.out_module orelse "out.qst";

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
        
        try stdout.print("Section count: {}\n", .{module.sections.items.len});

        for (module.sections.items) |section, i| 
        {
            try stdout.print("Section {}: id = {s}, size = {}\n", .{ i, @tagName(section.id), section.content_size });
        }

        try stdout.print("\n", .{});

        const instructions_bytes = module.getSectionData(.instructions, 0) orelse unreachable;
        const instructions = @ptrCast([*]Vm.Instruction, @alignCast(@alignOf(Vm.Instruction), instructions_bytes.ptr))[0 .. instructions_bytes.len / @sizeOf(Vm.Instruction)];

        defer module.sections.deinit(allocator);
        defer module.sections_content.deinit(allocator);

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

        for (instructions) |instruction, i| 
        {
            try std.fmt.format(stdout, "    {x:0>8}: {x:0>2} {s: <15} ", .{ i, @enumToInt(instruction.opcode), @tagName(instruction.opcode) });

            for (instruction.operands) |operand, j| {
                switch (operand) {
                    .register => try std.fmt.format(stdout, "{s}", .{ @tagName(@intToEnum(Vm.Register, operand.register)) }),
                    .immediate => try std.fmt.format(stdout, "${x}", .{ operand.immediate }),
                }

                if (j != instruction.operands.len - 1) {
                    try std.fmt.format(stdout, ", ", .{});
                }
            }
            
            try std.fmt.format(stdout, "\n", .{});
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

        const instructions = @ptrCast([*]Vm.Instruction, @alignCast(@alignOf(Vm.Instruction), instructions_bytes.ptr))[0 .. instructions_bytes.len / @sizeOf(Vm.Instruction)];

        @setRuntimeSafety(false);

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

        if (module.getSectionData(.relocations, 0)) |relocation_data|
        {
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
                        instructions[relocation.instruction_address].operands[relocation.operand_index].immediate += @ptrToInt(data.ptr);
                    },
                    else => unreachable
                }

                offset += @sizeOf(Module.Relocation);
            }
        }

        std.log.info("sussss", .{});

        var stack: [1024 * 8]u64 = undefined;
        var call_stack: [64]Vm.CallFrame = undefined;

        var vm = Vm{
            .stack = &stack,
            .call_stack = &call_stack,
            .natives = &[_]*const fn (*Vm) void {
                &nativeTest,
                Vm.extFn(envMulAdd),
                Vm.extFn(envPow),
                Vm.extFn(puts),
                Vm.extFn(alloc),
            },
        };

        vm.init();
        defer vm.deinit();

        const executable = Vm.Executable {
            .instructions = instructions,
            .data = data,
        };

        if (main_address) |address| 
        {
            vm.execute(executable, address) catch |err| switch (err) 
            {
                error.BreakInstruction => std.log.info("Breakpoint hit", .{}),
                else => return err,
            };
        }

        return;
    }

    return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
}