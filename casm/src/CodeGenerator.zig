const std = @import("std");
const callisto = @import("callisto");
const IR = @import("IR.zig");

pub const Instruction = struct 
{
    opcode: callisto.Vm.OpCode,
    write_operand: Operand,
    read_operands: [2]Operand,

    pub const Operand = union(enum)
    {
        empty,
        register: callisto.Vm.Register,
        immediate: u64,
        instruction_index: u32,
        data_point_index: u32,
    };
};

pub const DataPoint = struct 
{
    alignment: u32,
    size: u32,
    offset: u32,
};

pub const Procedure = struct 
{
    index: u32,
};

pub fn sizeInstruction(instruction: Instruction) usize
{
    var registers_size: usize = 0;
    var immediate_sizes: [3]usize = .{ 0, 0, 0 };
    var immediate_count: usize = 0;

    if (instruction.write_operand != .empty)
    {
        registers_size = @sizeOf(u16);
    }

    for (instruction.read_operands) |operand, i|
    {
        switch (operand)
        {
            .register => registers_size = @maximum(registers_size, @sizeOf(u16)),
            .immediate => |immediate| {
                immediate_count += 1;

                if (immediate <= std.math.maxInt(u8))
                {
                    immediate_sizes[i] = @sizeOf(u16);
                }
                else if (immediate > std.math.maxInt(u8) and immediate <= std.math.maxInt(u16))
                {
                    immediate_sizes[i] = @sizeOf(u16);
                }
                else if (immediate > std.math.maxInt(u16) and immediate <= std.math.maxInt(u32))
                {
                    immediate_sizes[i] = @sizeOf(u32);
                }
                else
                {
                    immediate_sizes[i] = @sizeOf(u64);
                }
            },
            .instruction_index => {
                immediate_count += 1;
                immediate_sizes[i] = @sizeOf(u64);
            },
            .data_point_index => {
                immediate_count += 1;
                immediate_sizes[i] = @sizeOf(u64);
            },
            .empty => {},
        }
    }

    var immediate_size: usize = 0;

    for (immediate_sizes) |current_immediate_size|
    {
        immediate_size = @maximum(immediate_size, current_immediate_size);
    }

    return @sizeOf(callisto.Vm.InstructionHeader) + registers_size + (immediate_size * immediate_count);
}

pub fn encodeInstruction(code_points: *std.ArrayList(u16), instruction: Instruction, instruction_addresses: []const u32) !usize
{
    const operand_layout = block: {
        var operand_count: usize = 0;
        var current_layout: callisto.Vm.OperandLayout = .none; 

        if (instruction.write_operand != .empty)
        {
            operand_count += 1;
            current_layout = .write_register;
        }

        for (instruction.read_operands) |operand|
        {
            switch (operand)
            {
                .register => {
                    current_layout = switch (current_layout)
                    {
                        .none => .read_register,
                        .write_register => .write_register_read_register,
                        .write_register_read_register => .write_register_read_register_read_register,
                        .write_register_read_register_read_register => unreachable,
                        .write_register_immediate => .write_register_immediate_read_register,
                        .write_register_immediate_immediate => unreachable,
                        .write_register_immediate_read_register => unreachable,
                        .write_register_read_register_immediate => unreachable,
                        .read_register => .read_register_read_register,
                        .read_register_read_register => unreachable,
                        .read_register_immediate => unreachable,
                        .immediate => .immediate_read_register,
                        .immediate_immediate => unreachable,
                        .immediate_read_register => unreachable,
                        _ => unreachable,
                    };

                    operand_count += 1;
                },
                .immediate, .instruction_index, .data_point_index => {
                    current_layout = switch (current_layout)
                    {
                        .none => .immediate,
                        .write_register => .write_register_immediate,
                        .write_register_read_register => .write_register_read_register_immediate,
                        .write_register_read_register_read_register => unreachable,
                        .write_register_immediate => .write_register_immediate_immediate,
                        .write_register_immediate_immediate => unreachable,
                        .write_register_immediate_read_register => unreachable,
                        .write_register_read_register_immediate => unreachable,
                        .read_register => .read_register_immediate,
                        .read_register_read_register => unreachable,
                        .read_register_immediate => unreachable,
                        .immediate => .immediate_immediate,
                        .immediate_immediate => unreachable,
                        .immediate_read_register => unreachable,
                        _ => unreachable,
                    };

                    operand_count += 1;
                },
                .empty => {},
            }
        }

        break :block current_layout;
    };

    const immediate_size: callisto.Vm.OperandAddressingSize = block: {
        var immediate: u64 = 0;

        for (instruction.read_operands) |operand|
        {
            switch (operand)
            {
                .immediate => |operand_immediate| {
                    immediate = operand_immediate;
                    break;
                },
                .instruction_index, .data_point_index => {
                    break: block .@"64";
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

    const header = callisto.Vm.InstructionHeader 
    {
        .opcode = instruction.opcode,
        .operand_layout = operand_layout,
        .operand_size = .@"64",
        .immediate_size = immediate_size,
    };

    const first_code_point = code_points.items.len;

    try code_points.append(@bitCast(u16, header));

    const code_points_per_immediate: usize = switch (immediate_size)
    {
        .@"8" => 1,
        .@"16" => 1,
        .@"32" => 2,
        .@"64" => 4,
    };

    var register_pack: ?callisto.Vm.OperandPack = null;
    var immediates: [2]?Instruction.Operand = .{ null, null };

    switch (header.operand_layout)
    {
        .none => {},
        .write_register => {
            register_pack = callisto.Vm.OperandPack
            {
                .write_operand = instruction.write_operand.register,
            };
        },
        .write_register_read_register => {
            register_pack = callisto.Vm.OperandPack
            {
                .write_operand = instruction.write_operand.register,
                .read_operand = instruction.read_operands[0].register,
            };
        },
        .write_register_read_register_read_register => {
            register_pack = callisto.Vm.OperandPack
            {
                .write_operand = instruction.write_operand.register,
                .read_operand = instruction.read_operands[0].register,
                .read_operand1 = instruction.read_operands[1].register,
            };
        },
        .write_register_immediate => {
            register_pack = callisto.Vm.OperandPack
            {
                .write_operand = instruction.write_operand.register,
            };

            immediates[0] = instruction.read_operands[0];
        },
        .write_register_immediate_immediate => {
            register_pack = callisto.Vm.OperandPack
            {
                .write_operand = instruction.write_operand.register,
            };

            immediates[0] = instruction.read_operands[0];
            immediates[1] = instruction.read_operands[1];
        },
        .write_register_immediate_read_register => {
            register_pack = callisto.Vm.OperandPack
            {
                .write_operand = instruction.write_operand.register,
                .read_operand = instruction.read_operands[1].register,
            };

            immediates[0] = instruction.read_operands[0];
        },
        .write_register_read_register_immediate => {
            register_pack = callisto.Vm.OperandPack
            {
                .write_operand = instruction.write_operand.register,
                .read_operand = instruction.read_operands[0].register,
            };

            immediates[0] = instruction.read_operands[1];
        },
        .read_register => {
            register_pack = callisto.Vm.OperandPack
            {
                .read_operand = instruction.read_operands[0].register,
            };
        },
        .read_register_read_register => {
            register_pack = callisto.Vm.OperandPack
            {
                .read_operand = instruction.read_operands[0].register,
                .read_operand1 = instruction.read_operands[1].register,
            };
        },
        .read_register_immediate => {
            register_pack = callisto.Vm.OperandPack
            {
                .read_operand = instruction.read_operands[0].register,
            };

            immediates[0] = instruction.read_operands[1];
        },
        .immediate => {
            immediates[0] = instruction.read_operands[0];
        },
        .immediate_immediate => {
            immediates[0] = instruction.read_operands[0];
            immediates[1] = instruction.read_operands[1];
        },
        .immediate_read_register => {
            register_pack = callisto.Vm.OperandPack
            {
                .read_operand = instruction.read_operands[1].register,
            };

            immediates[0] = instruction.read_operands[0];
        },
        _ => unreachable,
    }

    if (register_pack != null)
    {
        try code_points.append(@bitCast(u16, register_pack.?));
    }

    for (immediates) |mabye_immediate| 
    {
        if (mabye_immediate == null) continue;

        switch (mabye_immediate.?)
        {
            .immediate => |immediate| {
                try code_points.appendSlice(@ptrCast([*]const u16, &immediate)[0..code_points_per_immediate]);
            },
            .instruction_index => |instruction_index| {
                const immediate: u64 = instruction_addresses[instruction_index];

                try code_points.appendSlice(@ptrCast([*]const u16, &immediate)[0..code_points_per_immediate]);
            },
            .data_point_index => |data_point_index|
            {
                const immediate: u64 = data_point_index;

                try code_points.appendSlice(@ptrCast([*]const u16, &immediate)[0..@sizeOf(u64) / 2]);
            },
            else => unreachable,
        }
    }

    return code_points.items.len - first_code_point;
}

///Selects the callisto opcode/operands for the corresponding IR instruction
///Currently only returns one instruction, but may end up selecting more or less for peephole reduction   
pub fn selectInstruction(
    ir: IR, 
    instructions: []const Instruction, 
    instruction_statement: IR.Statement.Instruction,
    instruction_statement_index: IR.StatementIndex
    ) !Instruction
{
    _ = instructions;
    _ = instruction_statement_index;

    var instruction: Instruction = .{ .opcode = .nullop, .write_operand = .empty, .read_operands = .{ .empty, .empty } };

    switch (instruction_statement.operation)
    {
        .nullop => {},
        .@"unreachable" => instruction.opcode = .@"unreachable",
        .ebreak => instruction.opcode = .ebreak,
        .move => instruction.opcode = .@"move",
        .clear => instruction.opcode = .@"clear",
        .load8 => instruction.opcode = .load8,
        .load16 => instruction.opcode = .load16,
        .load32 => instruction.opcode = .load32,
        .load64 => instruction.opcode = .load64,
        .store8 => instruction.opcode = .store8,
        .store16 => instruction.opcode = .store16,
        .store32 => instruction.opcode = .store32,
        .store64 => instruction.opcode = .store64,
        .iadd => instruction.opcode = .@"iadd",
        .isub => instruction.opcode = .@"isub",
        .imul => instruction.opcode = .@"imul",
        .idiv => instruction.opcode = .@"idiv",
        .islt => instruction.opcode = .@"islt",
        .isgt => instruction.opcode = .@"isgt",
        .isle => instruction.opcode = .@"isle",
        .isge => instruction.opcode = .@"isge",
        .band => instruction.opcode = .@"band",
        .bor => instruction.opcode = .@"bor",
        .bnot => instruction.opcode = .@"bnot",
        .lnot => instruction.opcode = .@"lnot",
        .push => instruction.opcode = .@"push",
        .pop => instruction.opcode = .@"pop",
        .eql => instruction.opcode = .@"eql",
        .neql => instruction.opcode = .@"neql",
        .jump => instruction.opcode = .@"jump",
        .jumpif => instruction.opcode = .@"jumpif",
        .call => {
            switch (instruction_statement.read_operands[0])
            {
                .symbol => |symbol_index| {
                    const symbol = ir.symbol_table.items[symbol_index];

                    switch (symbol)
                    {
                        .procedure_index => {
                            instruction.opcode = .@"call";
                        },
                        .imported_procedure => {
                            instruction.opcode = .@"ecall";          
                        },
                        else => unreachable,
                    } 
                },
                .register => {},
                else => {},
            }
        },
        .@"return" => instruction.opcode = .@"return",
    }

    switch (instruction_statement.write_operand)
    {
        .register => {
            instruction.write_operand = .{ .register = @intToEnum(callisto.Vm.Register, @enumToInt(instruction_statement.write_operand.register)) };
        },
        else => {},
    }

    for (instruction_statement.read_operands) |operand, i|
    {
        switch (operand)
        {
            .empty => {},
            .register => |register| {
                instruction.read_operands[i] = .{ .register = @intToEnum(callisto.Vm.Register, @enumToInt(register)) };
            },
            .immediate => |immediate| {
                instruction.read_operands[i] = .{ .immediate = immediate };
            },
            .symbol => |symbol| {
                const symbol_value = ir.symbol_table.items[symbol];

                switch (symbol_value)
                {
                    .basic_block_index => |basic_block| {
                        instruction.read_operands[i] = .{ .instruction_index = basic_block };
                    },
                    .procedure_index => |procedure_index| {
                        instruction.read_operands[i] = .{ .instruction_index = ir.procedures.items[procedure_index].entry };
                    },
                    .imported_procedure => |procedure| {
                        instruction.read_operands[i] = .{ .immediate = procedure.index };
                    },
                    .data => |data| {
                        instruction.read_operands[i] = .{ .data_point_index = data.offset };
                    },
                    .integer => |integer| {
                        instruction.read_operands[i] = .{ .immediate = integer };
                    },
                }
            },
        }
    }

    return instruction;
}

pub fn generateProcedure(
    allocator: std.mem.Allocator, 
    ir: IR, 
    instructions: *std.ArrayListUnmanaged(Instruction), 
    block_instruction_indices: []u32,
    procedure_index: usize,
    procedure_queue: *std.ArrayListUnmanaged(Procedure),
    ) !void
{
    const procedure_queue_start = procedure_queue.items.len;

    var basic_blocks = ir.constReachableBasicBlockIterator(ir.procedures.items[procedure_index]);

    while (basic_blocks.next()) |basic_block|
    {
        const basic_block_index = basic_blocks.index;

        const statements = ir.statements.items[basic_block.statement_offset..basic_block.statement_offset + basic_block.statement_count];

        block_instruction_indices[basic_block_index] = @intCast(u32, instructions.items.len);

        for (statements) |statement, i|
        {
            switch (statement)
            {
                .instruction => |instruction|
                {
                    switch (instruction.operation)
                    {
                        .call => {
                            switch (instruction.read_operands[0])
                            {
                                .symbol => |symbol| {
                                    const procedure_symbol = ir.symbol_table.items[symbol];

                                    switch (procedure_symbol)
                                    {
                                        .procedure_index => {
                                            var already_generated: bool = block: {
                                                for (procedure_queue.items) |procedure|
                                                {
                                                    if (procedure.index == procedure_symbol.procedure_index)
                                                    {
                                                        break: block true;
                                                    }
                                                }

                                                for (ir.entry_points.items) |entry_point_index|
                                                {
                                                    if (entry_point_index == procedure_symbol.procedure_index)
                                                    {
                                                        break: block true;
                                                    }
                                                }

                                                break: block false;
                                            };

                                            if (!already_generated)
                                            {
                                                try procedure_queue.append(allocator, .{
                                                    .index = procedure_symbol.procedure_index,
                                                });
                                            }
                                        },
                                        .imported_procedure => {},
                                        else => unreachable,
                                    }
                                },
                                else => {},
                            }
                        },
                        else => {},
                    }

                    const callisto_instruction = try selectInstruction(ir, instructions.items, instruction, @intCast(u32, i));

                    try instructions.append(allocator, callisto_instruction);
                }
            }
        }
    }

    for (procedure_queue.items[procedure_queue_start..]) |procedure|
    {
        try generateProcedure(allocator, ir, instructions, block_instruction_indices, procedure.index, procedure_queue);
    }
}

pub fn generate(allocator: std.mem.Allocator, ir: IR) !callisto.Module 
{
    var instructions = std.ArrayListUnmanaged(Instruction) {};
    defer instructions.deinit(allocator);

    var data_points = std.ArrayListUnmanaged(DataPoint) {};
    defer data_points.deinit(allocator);

    for (ir.symbol_table.items) |symbol|
    {
        switch (symbol)
        {
            .data => |data|
            {
                try data_points.append(allocator, .{
                    .alignment = 1,
                    .size = data.size,
                    .offset = data.offset,
                });
            },
            else => {},
        }
    }

    for (data_points.items) |data_point|
    {
        std.log.info("data: align({}), offset: {}, size: {}", .{ data_point.alignment, data_point.offset, data_point.size });
    }

    var procedure_queue = std.ArrayListUnmanaged(Procedure) {};
    defer procedure_queue.deinit(allocator);

    const block_instruction_indices = try allocator.alloc(u32, ir.basic_blocks.items.len);
    defer allocator.free(block_instruction_indices);

    //Should really traverse a DAG (Directed Acyclic Graph) of procedures
    for (ir.entry_points.items) |entry_point|
    {
        try generateProcedure(allocator, ir, &instructions, block_instruction_indices, entry_point, &procedure_queue);
    }

    //Resolve block indices to instruction indices
    for (instructions.items) |*instruction|
    {
        for (instruction.read_operands) |*operand|
        {
            switch (operand.*)
            {
                .instruction_index => |block_index| {
                    operand.instruction_index = block_instruction_indices[block_index];
                },
                else => {},
            }
        }
    }

    const instruction_addresses = try allocator.alloc(u32, instructions.items.len);
    defer allocator.free(instruction_addresses);

    {
        var current_address: usize = 0;

        for (instructions.items) |instruction, i|
        {
            const size = sizeInstruction(instruction);

            instruction_addresses[i] = @intCast(u32, current_address); 

            current_address += size;
        }
    }

    var code_points = std.ArrayList(u16).init(allocator);
    defer code_points.deinit();

    std.mem.set(u16, code_points.items, 0);

    std.debug.print("\nGenerated callisto: \n\n", .{});

    for (instructions.items) |instruction, i|
    {
        const code_point_offset = code_points.items.len;
        const code_point_count = try encodeInstruction(&code_points, instruction, instruction_addresses);

        var desired_alignment: usize = 50;

        desired_alignment -= std.fmt.count("{x:0>4}: ", .{ instruction_addresses[i] });

        std.debug.print("{x:0>4}: ", .{ instruction_addresses[i] });

        for (code_points.items[code_point_offset..code_point_offset + code_point_count]) |code_point|
        {
            desired_alignment -= std.fmt.count("{x:0>2} ", .{ @truncate(u8, code_point >> 8) });
            desired_alignment -= std.fmt.count("{x:0>2} ", .{ @truncate(u8, code_point) });

            const bytes = std.mem.asBytes(&code_point);

            std.debug.print("{x:0>2} ", .{ bytes[0] });
            std.debug.print("{x:0>2} ", .{ bytes[1] });
        }

        try std.io.getStdErr().writer().writeByteNTimes(' ', desired_alignment);

        std.debug.print("{s}", .{ @tagName(instruction.opcode) });

        switch (instruction.write_operand)
        {
            .register => |register| {
                std.debug.print(" %{s}", .{ @tagName(register) });

                if (instruction.read_operands.len != 0)
                {
                    std.debug.print(",", .{});
                }
            },
            else => {},
        }

        for (instruction.read_operands) |operand, j|
        {
            if (j != 0 and j != instruction.read_operands.len and operand != .empty)
            {
                std.debug.print(",", .{});
            }

            switch (operand) 
            {
                .empty => {},
                .register => |register| {
                    std.debug.print(" %{s}", .{ @tagName(register) });
                },
                .immediate => |immediate| {
                    std.debug.print(" {}", .{ immediate });
                },
                .instruction_index => |instruction_index| {
                    std.debug.print(" (0x{x})", .{ instruction_addresses[instruction_index] });
                },
                .data_point_index => |data_point_index| {
                    std.debug.print(" (0x{x})", .{ data_point_index });
                }
            }
        }

        std.debug.print(";\n", .{});
    }

    var module = callisto.Module {
        .allocator = allocator,
        .sections = .{},
        .sections_content = .{},
        .entry_point = instruction_addresses[block_instruction_indices[ir.procedures.items[ir.entry_point_procedure].entry]],
    };

    _ = try module.addSectionData(.instructions, u16, code_points.items);

    var exported_symbols = std.ArrayList(callisto.Module.SymbolExport).init(allocator);
    defer exported_symbols.deinit();

    const main_symbol = "main";

    try exported_symbols.append(.{
        .tag = .procedure,
        .offset = 0,
        .size = main_symbol.len,
        .address = instruction_addresses[block_instruction_indices[ir.procedures.items[ir.entry_points.items[0]].entry]], //yuck
    });

    var exported_symbol_text = std.ArrayList(u8).init(allocator);
    defer exported_symbol_text.deinit();

    try exported_symbol_text.appendSlice(main_symbol);

    const export_section_data = try allocator.alloc(
        u8, 
        @sizeOf(callisto.Module.ExportSectionHeader) + 
        (exported_symbols.items.len * @sizeOf(callisto.Module.SymbolExport)) +
        exported_symbol_text.items.len
    );
    defer allocator.free(export_section_data);

    var export_section_fba = std.heap.FixedBufferAllocator.init(export_section_data);

    const export_section_header = try export_section_fba.allocator().create(callisto.Module.ExportSectionHeader);

    export_section_header.symbol_count = exported_symbols.items.len;

    std.mem.copy(
        callisto.Module.SymbolExport, 
        try export_section_fba.allocator().alloc(callisto.Module.SymbolExport, exported_symbols.items.len), 
        exported_symbols.items
    );

    std.mem.copy(u8, try export_section_fba.allocator().alloc(u8, exported_symbol_text.items.len), exported_symbol_text.items);

    _ = try module.addSectionDataAligned(.exports, u8, export_section_data, @alignOf(callisto.Module.ExportSectionHeader));

    return module;
}