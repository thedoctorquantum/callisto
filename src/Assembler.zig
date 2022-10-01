const Assembler = @This();

const std = @import("std");
const Vm = @import("Vm.zig");
const Tokenizer = @import("Tokenizer.zig");
const Module = @import("Module.zig");

allocator: std.mem.Allocator,

pub const Operand = union(enum)
{
    register: u4,
    literal_integer: u64,
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
    
    var instructions = std.ArrayList(Vm.Instruction).init(self.allocator);
    defer instructions.deinit();

    var instruction: Vm.Instruction = .{ .opcode = .nullop, .operands = [_]Vm.Instruction.Operand { .{ .register = 0 }, .{ .register = 0 }, .{ .register = 0 } } }; 
    var operand_index: usize = 0;

    var preinit_data = std.ArrayList(u8).init(self.allocator);
    defer preinit_data.deinit();

    var exported_symbols = std.ArrayList(Module.SymbolExport).init(self.allocator);
    defer exported_symbols.deinit();

    var exported_symbol_text = std.ArrayList(u8).init(self.allocator);
    defer exported_symbol_text.deinit();

    const LabelType = enum 
    {
        instruction,
        data
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

    while (tokenizer.next()) |token|
    {
        std.log.info("token({}): {s}", .{ token.tag, source[token.start..token.end] });
        
        switch (state)
        {
            .start => {
                switch (token.tag)
                {
                    .opcode => {
                        state = .instruction;
                        instruction.opcode = Tokenizer.Token.getOpcode(source[token.start..token.end]) orelse unreachable;
                    },
                    .keyword_export => {
                        is_export = true;
                    },
                    .identifier => {
                        //Should use look ahead
                        var next = tokenizer.next() orelse break;

                        std.log.info("token({}): {s}", .{ next.tag, source[next.start..next.end] });

                        if (next.tag != .colon) continue;

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

                            try preinit_data.appendSlice(source[token.start..token.end]);
                        }

                        tokenizer.index -= next.end - next.start;
                    },
                    else => {},
                }
            },
            .instruction => {
                switch (token.tag)
                {
                    .comma => {
                        operand_index += 1;
                    },
                    .context_register => {
                        const register = try std.fmt.parseUnsigned(u4, source[token.start + 1..token.end], 10);

                        instruction.operands[operand_index] = .{
                            .register = register
                        };
                    },
                    .argument_register => {
                        const register = try std.fmt.parseUnsigned(u4, source[token.start + 1..token.end], 10);

                        instruction.operands[operand_index] = .{
                            .register = 8 + register
                        };
                    },
                    .literal_integer => {
                        instruction.operands[operand_index] = .{
                            .immediate = @bitCast(u64, try std.fmt.parseInt(i64, source[token.start..token.end], 10))
                        };
                    },
                    .literal_hex => {
                        instruction.operands[operand_index] = .{
                            .immediate = @bitCast(u64, try std.fmt.parseInt(i64, source[token.start + 2..token.end], 16))
                        };
                    },
                    .literal_binary => {
                        instruction.operands[operand_index] = .{
                            .immediate = @bitCast(u64, try std.fmt.parseInt(i64, source[token.start + 2..token.end], 2))
                        };
                    },
                    .literal_char => {
                        instruction.operands[operand_index] = .{
                            .immediate = source[token.start + 1]
                        };
                    },
                    .identifier => {
                        try label_patches.append(.{ 
                            .instruction_index = instructions.items.len, 
                            .operand_index = operand_index,
                            .label_name = source[token.start..token.end],
                        });
                    },
                    .semicolon => {
                        try instructions.append(instruction);

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

    for (label_patches.items) |patch|
    {
        instructions.items[patch.instruction_index].operands[patch.operand_index] = .{                            
            .immediate = (labels.get(patch.label_name) orelse {
                std.log.info("Label {s} not found", .{ patch.label_name });

                return error.LabelNotFound;
            }).address
        };        
    }    

    var module = Module {
        .allocator = self.allocator,
        .sections = .{},
        .sections_content = .{},
    };

    _ = try module.addSectionData(.instructions, @ptrCast([*]u8, instructions.items.ptr)[0 .. instructions.items.len * @sizeOf(Vm.Instruction)]);

    if (preinit_data.items.len != 0)
    {
        _ = try module.addSectionData(.data, preinit_data.items);
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

    _ = try module.addSectionData(.exports, export_section_data);

    return module;
}