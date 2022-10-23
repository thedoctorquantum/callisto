const Debugger = @This();
const std = @import("std");
const callisto = @import("callisto");

allocator: std.mem.Allocator,
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

pub fn init(self: *Debugger) void 
{
    self.vm = .{};
}

pub fn deinit(self: *Debugger) void
{
    self.break_points.deinit(self.allocator);

    callisto.Loader.unload(self.allocator, self.module_instance);

    self.* = undefined;
}

pub const StepResult = union(enum)
{
    termination,
    break_point: struct 
    {
        address: u32,
    },
};

pub fn step(self: *Debugger) !StepResult 
{
    const result = self.vm.execute(self.module_instance, .unbounded, {});

    if (result.trap) |trap|
    {
        switch (trap)
        {
            .break_instruction => {
                const instructions_begin = @ptrCast([*]align(2) u8, self.module_instance.instructions.ptr);
                
                const address = @ptrToInt(result.last_instruction) - @ptrToInt(instructions_begin);

                var original_opcode: ?callisto.Vm.OpCode = null;

                const is_user_made: bool = block: {
                    for (self.break_points.items) |break_point|
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

                    self.vm.instruction_pointer = result.last_instruction;

                    _ = self.vm.execute(self.module_instance, .bounded, 1);

                    current_header.opcode = .ebreak;
                }

                return .{ 
                    .break_point = .{
                        .address = @intCast(u32, address),
                    } 
                };
            },
            else => return error.ErrorTrap,
        }
    }

    return .termination;
}

pub fn setBreakPoint(self: *Debugger, address: u32) !void 
{
    if (address % 2 != 0)
    {
        return error.InvalidAddress;
    }

    if (address > self.module_instance.instructions.len * 2)
    {
        return error.InvalidAddress;
    }

    const header = @ptrCast(*callisto.Vm.InstructionHeader, &self.module_instance.instructions[address / 2]);

    try self.break_points.append(self.allocator, .{
        .address = address,
        .original_opcode = header.opcode,
    });

    header.opcode = .ebreak;
}

pub fn unsetBreakPoint(self: *Debugger, address: u32) !void 
{
    if (address % 2 != 0)
    {
        return error.InvalidAddress;
    }

    if (address > self.module_instance.instructions.len * 2)
    {
        return error.InvalidAddress;
    }

    var break_point_index: usize = 0;

    const is_user_made: bool = block: {
        for (self.break_points.items) |break_point, i|
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
        return error.NotUserMade;
    }

    const break_point = self.break_points.swapRemove(break_point_index);

    const header = @ptrCast(*callisto.Vm.InstructionHeader, &self.module_instance.instructions[break_point.address / 2]);

    header.opcode = break_point.original_opcode; 
}