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

///Maps instruction_indicies into byte offsets in the instruction stream
pub fn mapAddresses() void 
{
    unreachable;
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

                        // var statement_index = instruction_statement_index;

                        // var i: u32 = statement_index;

                        // _ = i;

                        // while (i < ir.statements.items.len)
                        // {
                        //     const statement = ir.statements.items[i];

                        //     switch (statement)
                        //     {
                        //         .basic_block_begin => {},
                        //         else => {},
                        //     }
                        // }
                    },
                    .procedure_index => |procedure_index| {
                        instruction.read_operands[i] = .{ .instruction_index = procedure_index };
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
    entry_point: usize,
    procedure_queue: *std.ArrayListUnmanaged(Procedure),
    ) !void
{
    std.debug.print("\n", .{});
    std.log.info("Procedure: \n", .{});

    const procedure_queue_start = procedure_queue.items.len;

    {
        var basic_block_index: usize = entry_point;

        while (basic_block_index < ir.basic_blocks.items.len)
        {
            const basic_block = ir.basic_blocks.items[basic_block_index];
            const statements = ir.statements.items[basic_block.statement_offset..basic_block.statement_offset + basic_block.statement_count];

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

                        std.debug.print("{}: {s} ", .{ instructions.items.len, @tagName(zyte_instruction.opcode) });

                        {
                            var j: usize = 0;

                            for (zyte_instruction.read_operands) |operand|
                            {
                                switch (operand)
                                {
                                    .empty => {},
                                    .register => |register| {
                                        std.debug.print("{s}", .{ @tagName(register) });
                                    },
                                    .immediate => |immediate| {
                                        std.debug.print("{}", .{ immediate });
                                    },
                                    .instruction_index => |instruction_index| {
                                        std.debug.print("{}", .{ instruction_index });
                                    },
                                }

                                if (j < zyte_instruction.read_operands.len - 1 and operand != .empty)
                                {
                                    std.debug.print(", ", .{});
                                }

                                switch (operand) {
                                    .empty => break,
                                    else => j += 1,
                                }
                            }
                        }

                        std.debug.print("\n", .{});

                        try instructions.append(allocator, zyte_instruction);
                    }
                }
            }

            if (basic_block.next) |next|
            {
                basic_block_index = next;
            }
            else 
            {
                break;
            }
        }
    }

    for (procedure_queue.items[procedure_queue_start..]) |procedure|
    {
        try generateProcedure(allocator, ir, instructions, procedure.index, procedure_queue);
    }
}

pub fn generate(allocator: std.mem.Allocator, ir: IR) !zyte.Module 
{
    var instructions = std.ArrayListUnmanaged(Instruction) {};
    defer instructions.deinit(allocator);

    //queue of procedures to be generated
    var procedure_queue = std.ArrayListUnmanaged(Procedure) {};
    defer procedure_queue.deinit(allocator);

    //Should really traverse a DAG (Directed Acyclic Graph) of procedures
    for (ir.entry_points.items) |entry_point|
    {
        std.log.info("Entry point index: {}", .{ entry_point });

        const entry_point_block = ir.procedures.items[entry_point].entry;

        try generateProcedure(allocator, ir, &instructions, entry_point_block, &procedure_queue);
    }

    std.log.info("CodeGenIR: \n", .{});

    for (instructions.items) |instruction, current_instruction_index|
    {
        switch (instruction.write_operand)
        {
            .empty => std.debug.print("{:0>4}: {s}", .{ current_instruction_index, @tagName(instruction.opcode) }),
            .register => |register| std.debug.print("{:0>4}: %{s} = {s}", .{ current_instruction_index, @tagName(register), @tagName(instruction.opcode) }),
            else => unreachable,
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

    var module = zyte.Module {
        .allocator = allocator,
        .sections = .{},
        .sections_content = .{},
    };

    return module;
}