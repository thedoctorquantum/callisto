const std = @import("std");
const zyte = @import("zyte");
const IR = @import("IR.zig");

pub const Instruction = struct 
{
    opcode: zyte.Vm.OpCode,
    write_operand: Operand,
    read_operands: [2]Operand,

    pub const Operand = union(enum)
    {
        empty,
        register: zyte.Vm.Register,
        immediate: u64,
        instruction_index: u32,
    };
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
                    immediate_sizes[i + 1] = @sizeOf(u16);
                }
                else if (immediate > std.math.maxInt(u8) and immediate <= std.math.maxInt(u16))
                {
                    immediate_sizes[i + 1] = @sizeOf(u16);
                }
                else if (immediate > std.math.maxInt(u16) and immediate <= std.math.maxInt(u32))
                {
                    immediate_sizes[i + 1] = @sizeOf(u32);
                }
                else
                {
                    immediate_sizes[i + 1] = @sizeOf(u64);
                }
            },
            .instruction_index => {
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

    return @sizeOf(zyte.Vm.InstructionHeader) + registers_size + (immediate_size * immediate_count);
}

pub fn encodeInstruction() void
{

}

///Selects the zyte opcode/operands for the corresponding IR instruction
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
        .@"break" => instruction.opcode = .@"break",
        .move => instruction.opcode = .@"move",
        .clear => instruction.opcode = .@"clear",
        .read8 => instruction.opcode = .@"read8",
        .read16 => instruction.opcode = .@"read16",
        .read32 => instruction.opcode = .@"read32",
        .read64 => instruction.opcode = .@"read64",
        .write8 => instruction.opcode = .@"write8",
        .write16 => instruction.opcode = .@"write16",
        .write32 => instruction.opcode = .@"write32",
        .write64 => instruction.opcode = .@"write64",
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
                        .imported_procedure_index => {
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
            instruction.write_operand = .{ .register = @intToEnum(zyte.Vm.Register, @enumToInt(instruction_statement.write_operand.register)) };
        },
        else => {},
    }

    for (instruction_statement.read_operands) |operand, i|
    {
        switch (operand)
        {
            .empty => {},
            .register => |register| {
                instruction.read_operands[i] = .{ .register = @intToEnum(zyte.Vm.Register, @enumToInt(register)) };
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
                    .imported_procedure_index => unreachable,
                    .data => {},
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

        std.log.info("basic_block_index: {}", .{ basic_block_index });

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

                                    var already_generated: bool = block: {
                                        for (procedure_queue.items) |procedure|
                                        {
                                            if (procedure.index == procedure_symbol.procedure_index)
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
                                else => {},
                            }
                        },
                        else => {},
                    }

                    const zyte_instruction = try selectInstruction(ir, instructions.items, instruction, @intCast(u32, i));

                    try instructions.append(allocator, zyte_instruction);
                }
            }
        }
    }

    for (procedure_queue.items[procedure_queue_start..]) |procedure|
    {
        try generateProcedure(allocator, ir, instructions, block_instruction_indices, procedure.index, procedure_queue);
    }
}

pub fn generate(allocator: std.mem.Allocator, ir: IR) !zyte.Module 
{
    var instructions = std.ArrayListUnmanaged(Instruction) {};
    defer instructions.deinit(allocator);

    var procedure_queue = std.ArrayListUnmanaged(Procedure) {};
    defer procedure_queue.deinit(allocator);

    const block_instruction_indices = try allocator.alloc(u32, ir.basic_blocks.items.len);
    defer allocator.free(block_instruction_indices);

    std.mem.set(u32, block_instruction_indices, 69);

    //Should really traverse a DAG (Directed Acyclic Graph) of procedures
    for (ir.entry_points.items) |entry_point|
    {
        try generateProcedure(allocator, ir, &instructions, block_instruction_indices, entry_point, &procedure_queue);
    }

    //Resolve block indices to instruction indices

    std.log.info("block_instruction_indices: {any}", .{ block_instruction_indices });

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

    std.debug.print("\nCodeGenIR: \n\n", .{});

    for (instructions.items) |instruction, current_instruction_index|
    {
        std.debug.print("{:0>4}: {s}", .{ current_instruction_index, @tagName(instruction.opcode) });

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

        for (instruction.read_operands) |operand, i|
        {
            if (i != 0 and i != instruction.read_operands.len and operand != .empty)
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
                    std.debug.print(" &[i{}]", .{ instruction_index });
                },
            }
        }

        std.debug.print(";\n", .{});
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

    for (instruction_addresses) |address, i|
    {
        std.log.info("{}: {}", .{ i, address });
    }

    std.debug.print("\nAddress mapped CodeGenIR: \n\n", .{});

    for (instructions.items) |instruction, current_instruction_index|
    {
        std.debug.print("{:0>4}: {s}", .{ instruction_addresses[current_instruction_index], @tagName(instruction.opcode) });

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

        for (instruction.read_operands) |operand, i|
        {
            if (i != 0 and i != instruction.read_operands.len and operand != .empty)
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
                    std.debug.print(" (0x{})", .{ instruction_addresses[instruction_index] });
                },
            }
        }

        std.debug.print(";\n", .{});
    }

    var module = zyte.Module {
        .allocator = allocator,
        .sections = .{},
        .sections_content = .{},
    };

    return module;
}