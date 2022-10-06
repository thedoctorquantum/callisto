const std = @import("std");
const Module = @import("Module.zig");
const Vm = @import("Vm.zig");

pub const ModuleInstance = struct 
{
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
    };

    linkNamespace(allocator, &module_instance, natives);

    if (module.getSectionData(.instructions, 0)) |instructions_bytes|
    {
        module_instance.instructions = try allocator.dupe(u16, @ptrCast([*]u16, @alignCast(@alignOf(u16), instructions_bytes.ptr))[0..instructions_bytes.len / @sizeOf(u16)]);
    }

    if (module.getSectionData(.data, 0)) |data|
    {
        module_instance.data = try allocator.dupe(u8, data);
    }

    return module_instance;
} 

pub fn unload(allocator: std.mem.Allocator, module_instance: ModuleInstance) void
{
    allocator.free(module_instance.instructions);

    if (module_instance.data.len > 0)
    {
        allocator.free(module_instance.data);
    }
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