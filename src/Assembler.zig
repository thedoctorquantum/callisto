const Assembler = @This();

const std = @import("std");
const Vm = @import("Vm.zig");
const Tokenizer = @import("Tokenizer.zig");
const Module = @import("Module.zig");

allocator: std.mem.Allocator,

pub const IRInstruction = struct
{
    opcode: Vm.OpCode,
    operands: [3]Operand = .{ .disabled, .disabled, .disabled },

    pub const Operand = union(enum) 
    {
        register: u4,
        immediate: ?u64, //null means relocated?,
        instruction_address: u64,
        disabled,
    };

    ///Returns the size of the instruction when encoded
    pub fn encodedSize(self: IRInstruction) usize
    {
        var registers_size: usize = 0;
        var immediate_sizes: [3]usize = .{ 0, 0, 0 };
        var immediate_count: usize = 0;

        for (self.operands) |operand, i|
        {
            switch (operand)
            {
                .register => registers_size = @sizeOf(u16),
                .immediate => |immediate| {
                    immediate_count += 1;

                    if (immediate == null)
                    {
                        immediate_sizes[i] = @sizeOf(u64);
                    }
                    else 
                    {
                        if (immediate.? <= std.math.maxInt(u8))
                        {
                            immediate_sizes[i] = @sizeOf(u16);
                        }
                        else if (immediate.? > std.math.maxInt(u8) and immediate.? <= std.math.maxInt(u16))
                        {
                            immediate_sizes[i] = @sizeOf(u16);
                        }
                        else if (immediate.? > std.math.maxInt(u16) and immediate.? <= std.math.maxInt(u32))
                        {
                            immediate_sizes[i] = @sizeOf(u32);
                        }
                        else
                        {
                            immediate_sizes[i] = @sizeOf(u64);
                        }
                    }
                },
                .instruction_address => {
                    immediate_count += 1;
                    immediate_sizes[i] = @sizeOf(u64);
                },
                .disabled => {},
            }
        }

        var immediate_size: usize = 0;

        for (immediate_sizes) |current_immediate_size|
        {
            immediate_size = @maximum(immediate_size, current_immediate_size);
        }

        return @sizeOf(Vm.InstructionHeader) + registers_size + (immediate_size * immediate_count);
    }

    pub const encode = @compileError("Not implemented yet");
};

///Simple assembler, not a real parser
pub fn assemble(self: *Assembler, source: []const u8) !Module
{
    var tokenizer = Tokenizer { .source = source, };

    var state: enum 
    {
        start,
        instruction,
    } = .start;
    
    var instructions = std.ArrayList(IRInstruction).init(self.allocator);
    defer instructions.deinit();

    var operand_index: usize = 0;

    var preinit_data = std.ArrayList(u8).init(self.allocator);
    defer preinit_data.deinit();

    var exported_symbols = std.ArrayList(Module.SymbolExport).init(self.allocator);
    defer exported_symbols.deinit();

    var exported_symbol_text = std.ArrayList(u8).init(self.allocator);
    defer exported_symbol_text.deinit();

    var relocations = std.ArrayList(Module.Relocation).init(self.allocator);
    defer relocations.deinit();

    var references = std.ArrayList(Module.Reference).init(self.allocator);
    defer references.deinit();

    var symbol_imports = std.ArrayList(Module.SymbolImport).init(self.allocator);
    defer symbol_imports.deinit();
    
    var symbol_import_text = std.ArrayList(u8).init(self.allocator);
    defer symbol_import_text.deinit();

    const LabelType = enum 
    {
        instruction,
        data,
        extern_instruction,
    };

    const Label = struct 
    {
        address: usize,
        tag: LabelType,
    };

    var labels = std.StringHashMap(Label).init(self.allocator);
    defer labels.deinit(); 

    var label_patches = std.ArrayList(struct 
    { 
        instruction_index: usize,
        operand_index: usize,
        label_name: []const u8,
    }).init(self.allocator);
    defer label_patches.deinit();

    var is_export = false;
    var is_import = false;

    var current_instruction: IRInstruction = .{ .opcode = .nullop }; 

    while (tokenizer.next()) |token|
    {
        std.log.info("token({s}): {s}", .{ @tagName(token.tag), source[token.start..token.end] });
        
        switch (state)
        {
            .start => switch (token.tag)
            {
                .opcode => {
                    state = .instruction;
                    current_instruction.opcode = Tokenizer.Token.getOpcode(source[token.start..token.end]) orelse unreachable;
                },
                .keyword_export => {
                    is_export = true;
                },
                .keyword_import => {
                    is_import = true;
                },
                .identifier => {
                    //Should use look ahead
                    var next = tokenizer.next() orelse break;

                    std.log.info("token({s}): {s}", .{ @tagName(next.tag), source[next.start..next.end] });

                    if (next.tag == .colon) 
                    {
                        next = tokenizer.next() orelse break;

                        if (next.tag == .opcode)
                        {
                            try labels.put(source[token.start..token.end], .{ .address = instructions.items.len, .tag = .instruction });

                            if (is_export)
                            {
                                try exported_symbols.append(.{
                                    .tag = .procedure,
                                    .offset = @intCast(u32, exported_symbol_text.items.len),
                                    .size = @intCast(u32, source[token.start..token.end].len),
                                    .address = instructions.items.len,
                                });

                                try exported_symbol_text.appendSlice(source[token.start..token.end]);

                                is_export = false;
                            }
                        }
                        else if (next.tag == .literal_string)
                        {
                            //static address
                            try labels.put(source[token.start..token.end], .{ .address = preinit_data.items.len, .tag = .data });

                            try preinit_data.appendSlice(source[next.start + 1..next.end - 1]);
                        }

                        tokenizer.index -= next.end - next.start;

                        continue;
                    }

                    next = tokenizer.next() orelse break;

                    if (is_import)
                    {
                        std.log.info("Found import '{s}'", .{ source[token.start..token.end] });

                        labels.put(source[token.start..token.end], .{ .address = 0, .tag = .extern_instruction }) catch unreachable;

                        try symbol_imports.append(
                            .{ 
                                .tag = .procedure, 
                                .offset = @intCast(u32, symbol_import_text.items.len),
                                .size = @intCast(u32, token.end - token.start)
                            }
                        );
                        
                        try symbol_import_text.appendSlice(source[token.start..token.end]);
                    }

                    is_import = false;

                    tokenizer.index -= next.end - next.start;
                },
                else => {},
            },
            .instruction => {
                switch (token.tag)
                {
                    .comma => {
                        operand_index += 1;
                    },
                    .context_register => {
                        const register = try std.fmt.parseUnsigned(u4, source[token.start + 1..token.end], 10);

                        current_instruction.operands[operand_index] = .{
                            .register = register
                        };
                    },
                    .argument_register => {
                        const register = try std.fmt.parseUnsigned(u4, source[token.start + 1..token.end], 10);

                        current_instruction.operands[operand_index] = .{
                            .register = 8 + register
                        };
                    },
                    .literal_integer => {
                        current_instruction.operands[operand_index] = .{
                            .immediate = @bitCast(u64, try std.fmt.parseInt(i64, source[token.start..token.end], 10))
                        };
                    },
                    .literal_hex => {
                        current_instruction.operands[operand_index] = .{
                            .immediate = @bitCast(u64, try std.fmt.parseInt(i64, source[token.start + 2..token.end], 16))
                        };
                    },
                    .literal_binary => {
                        current_instruction.operands[operand_index] = .{
                            .immediate = @bitCast(u64, try std.fmt.parseInt(i64, source[token.start + 2..token.end], 2))
                        };
                    },
                    .literal_char => {
                        current_instruction.operands[operand_index] = .{
                            .immediate = source[token.start + 1]
                        };
                    },
                    .identifier => {
                        current_instruction.operands[operand_index] = .{
                            .immediate = 0,
                        };

                        try label_patches.append(.{ 
                            .instruction_index = instructions.items.len, 
                            .operand_index = operand_index,
                            .label_name = source[token.start..token.end],
                        });
                    },
                    .semicolon => {
                        try instructions.append(current_instruction);

                        current_instruction = .{ .opcode = .nullop };

                        operand_index = 0;                            
                        state = .start;
                    },
                    else => {},
                }
            },
        }
    }

    var labels_iter = labels.iterator();

    while (labels_iter.next()) |item|
    {
        std.log.info("label: {s}, {}", .{ item.key_ptr.*, item.value_ptr.* });
    }

    std.log.info("relocations: {}", .{ relocations.items.len });
    std.log.info("imports: {any}", .{ symbol_imports.items });

    for (label_patches.items) |patch|
    {
        const label = labels.get(patch.label_name) orelse {
            std.log.info("Label {s} not found", .{ patch.label_name });

            return error.LabelNotFound;
        };       

        switch (label.tag)
        {
            .data => {
                try relocations.append(
                    .{ 
                        .address = @intCast(u32, patch.instruction_index), 
                        .address_type = .data 
                    }
                );

                instructions.items[patch.instruction_index].operands[operand_index] = .{
                    .immediate = null,
                };
            },
            .instruction => {
                var address: usize = 0;
                var instruction_index: isize = @intCast(isize, label.address) -% 1;

                while (label.address > 0 and instruction_index >= 0)
                {
                    address += instructions.items[@intCast(usize, instruction_index)].encodedSize();

                    instruction_index -%= 1;
                }

                instructions.items[patch.instruction_index].operands[patch.operand_index] = .{                            
                    .immediate = address
                };
            },
            .extern_instruction => {
                instructions.items[patch.instruction_index].operands[patch.operand_index] = .{                            
                    .immediate = null
                };

                const symbol_index = block: {
                    for (symbol_imports.items) |symbol_import, i|
                    {
                        const symbol_import_name = symbol_import_text.items[symbol_import.offset..symbol_import.size];

                        if (std.mem.eql(u8, symbol_import_name, patch.label_name))
                        {
                            break :block i;
                        }
                    }

                    break :block null;
                };

                std.log.info("symbol_index: {?}", .{ symbol_index });

                try references.append(.{
                    .address = @intCast(u32, patch.instruction_index),
                    .symbol = @intCast(u32, symbol_index orelse unreachable), 
                });
            },
        }
    }    

    std.log.info("references: {any}", .{ references.items });

    var module = Module {
        .allocator = self.allocator,
        .sections = .{},
        .sections_content = .{},
    };

    //generate actual instructions in correct format
    {
        var code_points = std.ArrayList(u16).init(self.allocator);
        defer code_points.deinit();

        for (instructions.items) |instruction|
        {
            const operand_layout = block: {
                var operand_count: usize = 0;
                var current_layout: Vm.OperandLayout = .none; 

                for (instruction.operands) |operand|
                {
                    switch (operand)
                    {
                        .register => {
                            current_layout = switch (operand_count)
                            {
                                0 => .register,
                                1 => switch (current_layout)
                                {
                                    .register => .register_register,
                                    .immediate => .immediate_register,
                                    else => unreachable,
                                },
                                2 => switch (current_layout)
                                {
                                    .register_immediate => .register_immediate_register,
                                    .register_register => .register_register_register,
                                    else => unreachable,
                                },
                                else => unreachable,
                            };

                            operand_count += 1;
                        },
                        .immediate, .instruction_address => {
                            current_layout = switch (operand_count)
                            {
                                0 => .immediate,
                                1 => switch (current_layout)
                                {
                                    .register => .register_immediate,
                                    .immediate => .immediate_immediate,
                                    else => unreachable,
                                },
                                else => unreachable,
                            };

                            operand_count += 1;
                        },
                        .disabled => {},
                    }
                }

                break :block current_layout;
            };

            const immediate_size: Vm.OperandAddressingSize = block: {
                var immediate: u64 = 0;

                for (instruction.operands) |operand|
                {
                    switch (operand)
                    {
                        .immediate => |operand_immediate| {
                            immediate = operand_immediate orelse std.math.maxInt(u64);
                            break;
                        },
                        else => immediate = std.math.maxInt(u64),
                    }
                }

                if (immediate <= std.math.maxInt(u8))
                {
                    break: block .@"8";
                }
                
                if (immediate > std.math.maxInt(u8) and immediate <= std.math.maxInt(u16))
                {
                    break: block .@"16";
                }

                if (immediate > std.math.maxInt(u16) and immediate <= std.math.maxInt(u32))
                {
                    break: block .@"32";
                }

                break: block .@"64";
            };

            const header = Vm.InstructionHeader 
            {
                .opcode = instruction.opcode,
                .operand_layout = operand_layout,
                .operand_size = .@"64",
                .immediate_size = immediate_size,
            };

            const code_points_per_immediate: usize = switch (immediate_size)
            {
                .@"8" => 1,
                .@"16" => 1,
                .@"32" => 2,
                .@"64" => 4,
            };

            const first_code_point = code_points.items.len;

            try code_points.append(@bitCast(u16, header));

            switch (header.operand_layout)
            {
                .none => {},
                .register => {
                    var register_pack = Vm.OperandPack
                    {
                        .read_operand = @intToEnum(Vm.Register, instruction.operands[0].register),
                    };

                    try code_points.append(@bitCast(u16, register_pack));
                },
                .register_register => {
                    var register_pack = Vm.OperandPack
                    {
                        .read_operand = @intToEnum(Vm.Register, instruction.operands[0].register),
                        .write_operand = @intToEnum(Vm.Register, instruction.operands[1].register),
                    };

                    try code_points.append(@bitCast(u16, register_pack));
                },
                .register_register_register => {
                    var register_pack = Vm.OperandPack
                    {
                        .read_operand = @intToEnum(Vm.Register, instruction.operands[0].register),
                        .read_operand1 = @intToEnum(Vm.Register, instruction.operands[1].register),
                        .write_operand = @intToEnum(Vm.Register, instruction.operands[2].register),
                    };

                    try code_points.append(@bitCast(u16, register_pack));
                },
                .register_immediate => {
                    var register_pack = Vm.OperandPack
                    {
                        .read_operand = @intToEnum(Vm.Register, instruction.operands[0].register),
                    };

                    try code_points.append(@bitCast(u16, register_pack));

                    try code_points.appendSlice(@ptrCast([*]const u16, &instruction.operands[1].immediate)[0..code_points_per_immediate]);
                },
                .register_immediate_register => {
                    var register_pack = Vm.OperandPack
                    {
                        .read_operand = @intToEnum(Vm.Register, instruction.operands[0].register),
                        .write_operand = @intToEnum(Vm.Register, instruction.operands[2].register),
                    };

                    try code_points.append(@bitCast(u16, register_pack));

                    try code_points.appendSlice(@ptrCast([*]const u16, &instruction.operands[1].immediate)[0..code_points_per_immediate]);
                },
                .immediate => {
                    try code_points.appendSlice(@ptrCast([*]const u16, &instruction.operands[0].immediate)[0..code_points_per_immediate]);
                },
                .immediate_register => {
                    var register_pack = Vm.OperandPack
                    {
                        .read_operand = .c0,
                        .write_operand = @intToEnum(Vm.Register, instruction.operands[1].register),
                    };

                    try code_points.append(@bitCast(u16, register_pack));

                    try code_points.appendSlice(@ptrCast([*]const u16, &instruction.operands[0].immediate)[0..code_points_per_immediate]);
                },
                .immediate_immediate => {
                    try code_points.appendSlice(@ptrCast([*]const u16, &instruction.operands[0].immediate)[0..code_points_per_immediate]);
                    try code_points.appendSlice(@ptrCast([*]const u16, &instruction.operands[1].immediate)[0..code_points_per_immediate]);
                },
                else => unreachable,
            }

            {
                var i: usize = first_code_point;

                std.debug.print("   {d:0>8}: ", .{ i * 2 });

                var remaining_alignment: usize = 30;

                while (i < code_points.items.len) : (i += 1)
                {
                    const format = "{d} ";

                    std.debug.print(format, .{ code_points.items[i] });

                    remaining_alignment -= std.fmt.count(format, .{ code_points.items[i] });
                }

                i = 0;

                while (i < remaining_alignment) : (i += 1)
                {
                    std.debug.print(" ", .{});
                }
            }

            const instruction_size = (code_points.items.len - first_code_point) * @sizeOf(u16);

            const encoded_size = instruction.encodedSize();

            if (instruction_size != encoded_size)
            {
                std.log.info("instruction_size: {}, encoded_size: {}", .{ instruction_size, encoded_size });
                unreachable;
            }

            std.debug.print(" -> IR instruction(size = {}): {s}, operand_layout: {s}\n", .{ instruction.encodedSize() / 2, @tagName(instruction.opcode), @tagName(operand_layout) });
        }

        _ = try std.io.getStdErr().write("\n");

        std.log.info("code_points: {}, size: {}", .{ code_points.items.len, code_points.items.len * @sizeOf(u16) });

        _ = try module.addSectionData(.instructions, u16, code_points.items);
    }


    if (preinit_data.items.len != 0)
    {
        _ = try module.addSectionData(.data, u8, preinit_data.items);
    }

    const export_section_data = try self.allocator.alloc(
        u8, 
        @sizeOf(Module.ExportSectionHeader) + 
        (exported_symbols.items.len * @sizeOf(Module.SymbolExport)) +
        exported_symbol_text.items.len
    );
    defer self.allocator.free(export_section_data);

    var export_section_fba = std.heap.FixedBufferAllocator.init(export_section_data);

    const export_section_header = try export_section_fba.allocator().create(Module.ExportSectionHeader);

    export_section_header.symbol_count = exported_symbols.items.len;

    std.mem.copy(
        Module.SymbolExport, 
        try export_section_fba.allocator().alloc(Module.SymbolExport, exported_symbols.items.len), 
        exported_symbols.items
    );

    std.mem.copy(u8, try export_section_fba.allocator().alloc(u8, exported_symbol_text.items.len), exported_symbol_text.items);

    _ = try module.addSectionDataAligned(.exports, u8, export_section_data, @alignOf(Module.ExportSectionHeader));

    const relocation_section_data = try self.allocator.alloc(
        u8, 
        @sizeOf(Module.RelocationSectionHeader) + 
        relocations.items.len * @sizeOf(Module.Relocation)
    );
    defer self.allocator.free(relocation_section_data);

    var relocation_section_fba = std.heap.FixedBufferAllocator.init(relocation_section_data);

    const relocation_header = try relocation_section_fba.allocator().create(Module.RelocationSectionHeader);

    relocation_header.relocation_count = relocations.items.len;

    _ = try relocation_section_fba.allocator().dupe(Module.Relocation, relocations.items);

    _ = try module.addSectionDataAligned(.relocations, u8, relocation_section_data, @alignOf(Module.RelocationSectionHeader));

    // const imports_section_data = try module.addSection(
    //     .imports, 
    //     @sizeOf(Module.ImportSectionHeader) + 
    //     (@sizeOf(Module.SymbolImport) * symbol_imports.items.len) + 
    //     symbol_import_text.items.len
    // );

    // var imports_section_data_fba = std.heap.FixedBufferAllocator.init(imports_section_data);

    // const imports_section_header = try imports_section_data_fba.allocator().create(Module.ImportSectionHeader);

    // imports_section_header.symbol_count = symbol_imports.items.len;

    // _ = try imports_section_data_fba.allocator().dupe(Module.SymbolImport, symbol_imports.items);

    // std.log.info("cap: {} size: {}", .{ imports_section_data.len, imports_section_data_fba.end_index });
    // std.log.info("import_symbol_text: {s}", .{ symbol_import_text.items });

    // _ = try imports_section_data_fba.allocator().dupe(u8, symbol_import_text.items);

    return module;
}