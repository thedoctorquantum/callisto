const std = @import("std");
const Module = @import("Module.zig");
const Vm = @import("Vm.zig");

pub const ModuleInstance = struct 
{
    image: []u8,
    instructions: []u16,
    data: []u8,
    data_stack: []u64,
    call_stack: []Vm.CallFrame,
    natives: []const *const Vm.NativeProcedure,
};

const natives = struct 
{
    pub fn nativeTest(a: u64, b: u64, c: u64) u64 
    {
        const res = a * b + c;

        std.log.info("envMulAdd {}", .{ res });

        return res;
    }

    pub fn alloc(size: u64) []const u8
    {
        const log = std.log.scoped(.Loader);

        log.info("Alloc {}", .{ size });

        return @ptrCast([*]const u8, std.c.malloc(size))[0..size];
    }

    pub fn puts(string: []const u8) void 
    {
        std.io.getStdOut().writer().print("print: {s}\n", .{ string }) catch unreachable;
    }
};

pub fn load(allocator: std.mem.Allocator, module: Module) !ModuleInstance 
{
    var module_instance = ModuleInstance 
    { 
        .instructions = &.{}, 
        .data = &.{}, 
        .data_stack = &.{},
        .call_stack = &.{},
        .natives = &.{},
        .image = &.{},
    };

    const instructions_section = module.getSectionData(.instructions, 0) orelse return error.NoInstructionSection;
    const data_section = module.getSectionData(.data, 0) orelse return error.NoDataSection;

    const call_stack_size: usize = 64 * @sizeOf(Vm.CallFrame);
    const data_stack_size: usize = 1024;

    var image_size: usize = 0;

    const instructions_offset: usize = 0;

    image_size += instructions_section.len;

    const data_offset: usize = image_size;

    image_size += data_section.len;

    image_size = std.mem.alignForward(image_size, @alignOf(Vm.CallFrame));

    const call_stack_offset: usize = image_size;

    image_size += call_stack_size;

    const data_stack_offset: usize = image_size;

    image_size += data_stack_size;

    const image = try allocator.alloc(u8, image_size);

    module_instance.image = image;

    @memset(image.ptr + call_stack_offset, 0, call_stack_size);
    @memset(image.ptr + data_stack_offset, 0, data_stack_size);

    @memcpy(image.ptr + instructions_offset, instructions_section.ptr, instructions_section.len);
    @memcpy(image.ptr + data_offset, data_section.ptr, data_section.len);

    module_instance.instructions = @ptrCast([*]u16, @alignCast(@alignOf(u16), image.ptr + instructions_offset))[0..instructions_section.len / @sizeOf(u16)];
    module_instance.data = image[data_offset..data_offset + data_section.len];
    module_instance.call_stack = @ptrCast([*]Vm.CallFrame, @alignCast(@alignOf(Vm.CallFrame), image[call_stack_offset..call_stack_offset + call_stack_size]))[0..call_stack_size / @sizeOf(Vm.CallFrame)];

    linkNamespace(allocator, &module_instance, natives);

    return module_instance;
} 

pub fn unload(allocator: std.mem.Allocator, module_instance: ModuleInstance) void
{
    allocator.free(module_instance.image);
}

pub fn linkNamespace(allocator: std.mem.Allocator, module_instance: *ModuleInstance, comptime namespace: anytype) void 
{
    _ = allocator;

    const decls = @typeInfo(namespace).Struct.decls;

    comptime var procedures: []const *const Vm.NativeProcedure = &.{};

    inline for (decls) |decl|
    {
        if (!decl.is_pub) continue;

        procedures = procedures ++ &[_]*const Vm.NativeProcedure { &extFn(@field(namespace, decl.name)) };
    }

    module_instance.natives = procedures;
}

//Generates a wrapper for any zig function
pub fn extFn(comptime proc: anytype) Vm.NativeProcedure
{
    const arg_types = @typeInfo(@TypeOf(proc)).Fn.args;

    const S = struct
    {
        pub fn function(registers: *[16]u64, data_stack_pointer: [*]align(8) u8) void
        {
            _ = data_stack_pointer;

            comptime var args_type_fields: [arg_types.len]std.builtin.Type.StructField = undefined;

            inline for (arg_types) |arg_type, i|
            {
                args_type_fields[i] = .{
                    .field_type = arg_type.arg_type.?,
                    .alignment = @alignOf(arg_type.arg_type.?),
                    .default_value = null,
                    .is_comptime = false,
                    .name = comptime std.fmt.comptimePrint("{}", .{ i }),
                };
            }

            const ArgsType = @Type(.{ .Struct = .{ 
                .layout = .Auto,
                .is_tuple = true,
                .fields = &args_type_fields,
                .decls = &[_]std.builtin.Type.Declaration {},
            }});

            var args: ArgsType = undefined;

            comptime var register_index = 0;

            inline for (comptime std.meta.fields(ArgsType)) |_, i|
            {
                const ArgType = @TypeOf(args[i]);

                switch (@typeInfo(ArgType))
                {
                    .Int => {
                        // args[i] = vm.getRegister(@intToEnum(Vm.Register, 8 + register_index)).*;
                        args[i] = registers[8 + register_index];
                    },
                    .Pointer => |pointer| {
                        switch (pointer.size)
                        {
                            .One, .Many => {
                                args[i] = @intToPtr(ArgType, registers[8 + register_index]);
                            },
                            .Slice => {
                                const register0 = registers[8 + register_index];
                                const register1 = registers[8 + register_index + 1];

                                register_index += 1;

                                args[i] = @intToPtr([*]std.meta.Child(ArgType), register0)[0..register1];
                            },
                            else => unreachable 
                        }
                    },
                    else => unreachable
                }

                register_index += 1;
            }

            const return_value = @call(
                .{ .modifier = .always_inline }, 
                proc,
                args,
            );

            switch (@typeInfo(@TypeOf(return_value)))
            {
                .Int => {
                    registers[15] = return_value;
                },
                .Pointer => |pointer| {
                    switch (pointer.size)
                    {
                        .One, .Many => {
                            registers[15] = @intCast(u64, @ptrToInt(return_value));
                        },
                        .Slice => {
                            registers[15] = @intCast(u64, @ptrToInt(return_value.ptr));
                            registers[14] = @intCast(u64, return_value.len);
                        },
                        else => unreachable 
                    }
                },
                .Void => {},
                else => unreachable
            }
            
        }
    };

    return S.function;
}