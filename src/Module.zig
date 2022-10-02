const std = @import("std");

allocator: std.mem.Allocator,

//#!/home/zak/Dev/Zig/Zyte/zig-out/bin/zyte
interpreter: ?[]const u8 = null,
sections: std.ArrayListUnmanaged(Section),
sections_content: std.ArrayListUnmanaged(u8),

pub const Header = extern struct 
{
    identifier: [4]u8 = "zyte".*,
    endianess: Endianess,
    version: u32 = 0,

    section_count: u64,
    section_contents_offset: u64,
    section_contents_size: u64,

    pub const Endianess = enum(u8) 
    {
        little,
        big,
        _
    };
};

pub const Section = extern struct 
{
    id: Id,
    content_size: u64,

    pub const Id = enum(u8)
    {
        custom,
        instructions,
        data,
        imports,
        exports,
        references,
        relocations,
        debug,
        _
    };
};

pub const ImportSectionHeader = extern struct 
{
    symbol_count: u64,
};

pub const SymbolImport = extern struct 
{
    tag: Tag,
    offset: u32,
    size: u32,

    pub const Tag = enum(u8)
    {
        procedure,
        variable,
    };
};

pub const ExportSectionHeader = extern struct 
{
    symbol_count: u64,
};

pub const SymbolExport = extern struct
{
    tag: Tag,
    offset: u32,
    size: u32,
    address: u64,

    pub const Tag = enum(u8)
    {
        procedure,
        variable,
    };
};

pub const ReferenceSectionHeader = extern struct
{
    reference_count: usize,
};

pub const Reference = extern struct 
{
    location: u64,
    symbol: u32,
};

pub const RelocationSectionHeader = extern struct 
{
    relocation_count: usize,
};

pub const Relocation = extern struct
{
    instruction_address: u64,
    operand_index: u8,
    address_type: Tag,

    pub const Tag = enum(u8)
    {
        data,
        _
    };  
};

pub fn addSection(self: *@This(), id: Section.Id, size: usize) !usize
{
    try self.sections.append(self.allocator, .{ .id = id, .content_size = size });

    const offset = self.sections_content.items.len;

    try self.sections_content.appendNTimes(self.allocator, 0, size);

    return offset;
}

pub fn addSectionData(self: *@This(), id: Section.Id, data: []const u8) !usize
{
    const offset = try self.addSection(id, data.len);

    @memcpy(self.sections_content.items.ptr + offset, data.ptr, data.len);

    return offset;
}

pub fn getSectionData(self: @This(), id: Section.Id, index: usize) ?[]u8
{
    var offset: usize = 0;
    var section_type_count: usize = 0; 

    for (self.sections.items) |section|
    {
        defer offset += section.content_size;

        if (section.id == id)
        {
            if (section_type_count == index)
            {
                return self.sections_content.items[offset..offset + section.content_size];
            }

            section_type_count += 1;
        }
    }

    return null;
}

pub fn decode(allocator: std.mem.Allocator, binary: []const u8) !@This()
{
    var self = @This()
    {
        .allocator = allocator,
        .sections = .{},
        .sections_content = .{},
    };
    
    var head: usize = 0;

    //optional interpreter (shebang) section
    if (std.mem.eql(u8, binary[0..2], "#!"))
    {
        head += 2;

        for (binary[2..]) |byte|
        {
            head += 1;

            if (byte == '\n')
            {
                break;
            }
        } 
    }

    @setRuntimeSafety(false);

    const header = @ptrCast(*const Header, @alignCast(@alignOf(Header), binary.ptr + head));

    if (!std.mem.eql(u8, &header.identifier, "zyte")) return error.InvalidIdentifier;

    head += @sizeOf(Header);

    try self.sections.resize(self.allocator, header.section_count);

    //non-memcpy deserialize
    // var section_index: usize = 0;
    // while (section_index < header.section_count) : (section_index += 1)
    // {
    //     const section = @ptrCast(*const Section, binary.ptr + head);
    //     defer head += @sizeOf(Section);

    //     try self.sections.append(self.allocator, section.*);
    // }

    @memcpy(@ptrCast([*]u8, self.sections.items.ptr), binary.ptr + head, header.section_count * @sizeOf(Section));

    head += header.section_count * @sizeOf(Section);

    try self.sections_content.resize(self.allocator, header.section_contents_size);

    std.debug.assert(self.sections_content.items.len != 0);

    @memcpy(self.sections_content.items.ptr, binary.ptr + head, header.section_contents_size);

    return self;
}

pub fn encode(self: @This(), writer: anytype) !void
{
    const header = Header 
    {
        .endianess = .little,
        .section_count = self.sections.items.len,
        .section_contents_offset = @sizeOf(Header) + (self.sections.items.len * @sizeOf(Section)),
        .section_contents_size = self.sections_content.items.len,
    };

    if (self.interpreter) |interpreter|
    {
        _ = try writer.write("#!");
        _ = try writer.write(interpreter);
        _ = try writer.write("\n");
    }

    _ = try writer.write(std.mem.asBytes(&header));
        
    for (self.sections.items) |section|
    {
        _ = try writer.write(std.mem.asBytes(&section));
    }

    _ = try writer.write(self.sections_content.items);
}