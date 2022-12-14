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
    natives: []*const Vm.NativeProcedure,
};

const natives = struct 
{
    pub const os = struct 
    {
        pub fn mmap(size: u64) ?*anyopaque
        {
            std.log.info("mmap: {}", .{ size });

            return std.c.malloc(size);
        }

        pub fn munmap(ptr: ?*anyopaque, size: u64) void
        {
            std.log.info("munmap: {*}, {}", .{ ptr, size });

            std.c.free(ptr);
        }
    };

    pub fn puts(string: []const u8) void 
    {
        std.io.getStdOut().writer().print("print: {s}\n", .{ string }) catch unreachable;
    }

    pub fn print_int(int: i64) void 
    {
        std.log.info("print_int: {}", .{ int });
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
    const import_section = module.getSectionData(.imports, 0);

    const call_stack_size: usize = 64 * @sizeOf(Vm.CallFrame);
    const data_stack_size: usize = 1024;

    var image_size: usize = 0;

    var native_table_offset: usize = image_size; 

    var native_count: usize = 0;

    const natives_map = NamespaceMap(natives);

    var import_symbols_begin: [*]u8 = undefined;

    //native procedure linking
    if (import_section) |import_bytes|
    {
        var head: usize = 0;
        
        const import_header = @ptrCast(*Module.ImportSectionHeader, @alignCast(@alignOf(Module.ImportSectionHeader), import_bytes.ptr + head)).*;

        head += @sizeOf(Module.ImportSectionHeader);

        native_count = import_header.procedure_count;

        import_symbols_begin = import_bytes.ptr + head + import_header.procedure_count * @sizeOf(Module.ImportProcedure);
    }

    image_size += native_count * @sizeOf(*Vm.NativeProcedure);

    const instructions_offset: usize = image_size;

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
    module_instance.natives = @ptrCast([*]*const Vm.NativeProcedure, @alignCast(@alignOf(*const Vm.NativeProcedure), image.ptr + native_table_offset))[0..native_count];

    //native procedure linking
    if (import_section) |import_bytes|
    {
        var head: usize = 0;
        
        const import_header = @ptrCast(*Module.ImportSectionHeader, @alignCast(@alignOf(Module.ImportSectionHeader), import_bytes.ptr + head)).*;

        head += @sizeOf(Module.ImportSectionHeader);

        native_count = import_header.procedure_count;

        var procedure_index: usize = 0;

        while (procedure_index < native_count) : (procedure_index += 1)
        {
            const procedure = @ptrCast(*Module.ImportProcedure, @alignCast(@alignOf(Module.ImportProcedure), import_bytes.ptr + head)).*;
            head += @sizeOf(Module.ImportProcedure);

            const procedure_name = import_symbols_begin[procedure.offset..procedure.offset + procedure.size];

            std.log.info("importing procedure: {s}...", .{ procedure_name });

            const procedure_pointer = natives_map.get(procedure_name) orelse {
                return error.LinkFailure;
            };

            module_instance.natives[procedure_index] = procedure_pointer;

            std.log.info("procedure '{s}' = {*}\n", .{ procedure_name, procedure_pointer });
        }
    }

    return module_instance;
} 

pub fn unload(allocator: std.mem.Allocator, module_instance: ModuleInstance) void
{
    allocator.free(module_instance.image);
}

const NativeProcedureKV = struct 
{ 
    @"0": []const u8,
    @"1": *const Vm.NativeProcedure,
};

pub fn NamespaceMap(comptime namespace: type) type 
{
    comptime var procedures: []const NativeProcedureKV = &.{};
    
    addNamespaceToMap(&procedures, namespace, namespace);

    comptime var buf: [1024]u8 = undefined;

    for (procedures) |procedure|
    {
        _ = buf;

        _ = procedure;
        // @compileError(procedure.@"0");

        // @compileLog(std.fmt.bufPrint(&buf, "{s}\n", .{ procedure.@"0" }) catch unreachable);
    }

    return std.ComptimeStringMap(
        *const Vm.NativeProcedure, 
        procedures
    );
}

fn addNamespaceToMap(comptime procedures: *[]const NativeProcedureKV, comptime root: type, comptime namespace: type) void
{
    const decls = @typeInfo(namespace).Struct.decls;

    inline for (decls) |decl|
    {
        if (!decl.is_pub) continue;

        const decl_value = @field(namespace, decl.name);

        switch (@typeInfo(@TypeOf(decl_value)))
        {
            .Type => {
                addNamespaceToMap(procedures, root, decl_value);
            },
            .Fn => {
                const mangled_name = (@typeName(namespace) ++ "." ++ decl.name)[@typeName(root).len + 1..];

                procedures.* = procedures.* ++ &[_]NativeProcedureKV 
                { 
                    .{ 
                        .@"0" = mangled_name,
                        .@"1" = &bindProcedure(decl_value),
                    }
                };
            },
            else => comptime unreachable,
        }
    }
}

//Generates a wrapper for any zig function
pub fn bindProcedure(comptime proc: anytype) Vm.NativeProcedure
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
                        args[i] = @bitCast(ArgType, registers[8 + register_index]);
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

                                if (register0 != 0)
                                {
                                    args[i] = @intToPtr([*]std.meta.Child(ArgType), register0)[0..register1];
                                }
                                else 
                                {
                                    args[i] = &.{};
                                }

                            },
                            else => comptime unreachable 
                        }
                    },
                    .Optional => |optional| {
                        switch (@typeInfo(optional.child))
                        {
                            .Pointer => |pointer| {
                                switch (pointer.size)
                                {
                                    .One, .Many => {
                                        args[i] = @intToPtr(ArgType, registers[8 + register_index]);
                                    },
                                    else => comptime unreachable 
                                }
                            },
                            else => comptime unreachable,
                        }
                    },
                    else => comptime unreachable
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
                        else => comptime unreachable 
                    }
                },
                .Void => {},
                .Optional => |optional| {
                    switch (@typeInfo(optional.child))
                    {
                        .Pointer => |pointer| {
                            switch (pointer.size)
                            {
                                .One, .Many => {
                                    registers[15] = @intCast(u64, @ptrToInt(return_value));
                                },
                                else => comptime unreachable 
                            }
                        },
                        else => comptime unreachable,
                    }
                },
                else => comptime unreachable
            }
            
        }
    };

    return S.function;
}