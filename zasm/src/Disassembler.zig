const Disassembler = @This();

const CodeGenerator = @import("CodeGenerator.zig");
const Instruction = CodeGenerator.Instruction;
const zyte = @import("zyte");
const Module = zyte.Module;

pub fn dissassemble(module: Module) ![]Instruction 
{
    const code_point_bytes = module.getSectionData(.instructions, 0) orelse return error.NoInstructionSection;
    const code_points = @ptrCast([*]u16, @alignCast(@alignOf(u16), code_point_bytes.ptr))[0..code_point_bytes.len / 2];

    var code_point_index: usize = 0;

    while (code_point_index < code_points.len)
    {
        
    }
}