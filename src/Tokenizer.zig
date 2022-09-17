const Tokenizer = @This();

const std = @import("std");
const Vm = @import("Vm.zig");

source: []const u8,
index: usize = 0,

pub fn next(self: *Tokenizer) ?Token
{
    var state: enum 
    {
        start,
        identifier,
        literal_integer,
        literal_hex,
        literal_binary,
        slash,
        single_comment,
        multi_comment,
    } = .start;
    
    var result = Token { .start = self.index, .end = 0, .tag = .end, };

    var multi_comment_level: usize = 0;

    while (self.index < self.source.len) : (self.index += 1)
    {
        const char = self.source[self.index];

        switch (state)
        {
            .start => {
                switch (char)
                {
                    ' ', '\t', '\r', '\n', => {
                        result.start = self.index + 1;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .identifier;
                        result.tag = .identifier;
                    },
                    '0'...'9', '-', => {
                        switch (std.ascii.toLower(self.source[self.index + 1]))
                        {
                            'B', 'b' => {
                                state = .literal_binary;
                                result.tag = .literal_binary;
                            },
                            else => {
                                state = .literal_integer;
                                result.tag = .literal_integer;
                            },
                        }

                        if (std.ascii.toLower(self.source[self.index + 1]) == 'x')
                        {
                            state = .literal_hex;
                            result.tag = .literal_hex;
                        }
                        else if (std.ascii.toLower(self.source[self.index + 1]) == 'b')
                        {
                            state = .literal_binary;
                            result.tag = .literal_binary;
                        }
                        else 
                        {
                            state = .literal_integer;
                            result.tag = .literal_integer;
                        }
                    },
                    '/' => {
                        state = .slash;
                    },
                    ',' => {
                        result.tag = .comma;
                        self.index += 1;

                        break;
                    },
                    ':' => {
                        result.tag = .colon;
                        self.index += 1;

                        break;
                    },
                    ';' => {
                        result.tag = .semicolon;
                        self.index += 1;

                        break;
                    },
                    else => {},
                }
            },
            .identifier => {
                switch (char) 
                {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                    else => {
                        const string = self.source[result.start..self.index];

                        if (Token.isOpcode(string))
                        {
                            result.tag = .opcode;
                        }
                        else if (Token.isContextRegister(string))
                        {
                            result.tag = .context_register;
                        }
                        else if (Token.isArgumentRegister(string))
                        {
                            result.tag = .argument_register;
                        }

                        break;
                    },
                }
            },
            .literal_integer => {
                switch (char)
                {
                    '0'...'9', '_' => {},
                    else => {
                        break;
                    },
                }
            },
            .literal_hex => {
                switch (char)
                {
                    '0'...'9', '_', 'x', 'X', 'a'...'f', 'A'...'F' => {},
                    else => break,
                }
            },
            .literal_binary => {
                switch (char)
                {
                    '0', '1', '_', 'b', 'B', => {},
                    else => break,
                }
            },
            .slash => {
                switch (char)
                {
                    '/' => {
                        state = .single_comment;
                    },
                    '*' => {
                        std.debug.assert(multi_comment_level == 0);
                        state = .multi_comment;
                    },
                    else => {},
                }  
            },
            .single_comment => {
                switch (char)
                {
                    '\n' => {
                        state = .start;
                        result.start = self.index + 1;
                    },
                    else => {}
                }
            },
            .multi_comment => {
                switch (char) 
                {
                    '*' => {
                        if (self.source[self.index + 1] == '/')
                        {
                            self.index += 1;

                            if (multi_comment_level == 0)
                            {
                                state = .start;
                            }
                            else
                            {
                                multi_comment_level -= 1;
                            }
                        }                        
                    },
                    '/' => {
                        if (self.source[self.index + 1] == '*')
                        {
                            self.index += 1;
                            multi_comment_level += 1;   
                        }  
                    },
                    else => {}
                }
            },
        }
    }

    if (result.tag == .end or self.index > self.source.len)
    {
        return null;
    }

    result.end = self.index;

    return result;
}

pub const Token = struct
{
    start: usize,
    end: usize,
    tag: Tag,

    pub const Tag = enum 
    {
        end,
        identifier,
        comma,
        colon,
        semicolon,
        literal_integer,
        literal_hex,
        literal_binary,
        opcode,
        context_register,
        argument_register,
        left_brace,
        right_brace,
    };

    pub fn getOpcode(string: []const u8) ?Vm.OpCode
    {
        inline for (comptime std.meta.fieldNames(Vm.OpCode)) |name|
        {
            if (std.mem.eql(u8, string, name))
            {
                return std.enums.nameCast(Vm.OpCode, name);
            }
        }

        return null;
    }

    pub fn isOpcode(string: []const u8) bool
    {
        inline for (comptime std.meta.fieldNames(Vm.OpCode)) |name|
        {
            if (std.mem.eql(u8, string, name))
            {
                return true;
            }
        }

        return false;
    }

    pub fn isContextRegister(string: []const u8) bool 
    {
        comptime var i = 0;

        inline while (i < 8) : (i += 1)
        {
            if (std.mem.eql(u8, string, "c" ++ std.fmt.comptimePrint("{}", .{ i })))
            {
                return true;
            }       
        } 

        return false;
    }

    pub fn isArgumentRegister(string: []const u8) bool
    {
        comptime var i = 0;

        inline while (i < 8) : (i += 1)
        {
            if (std.mem.eql(u8, string, "a" ++ std.fmt.comptimePrint("{}", .{ i })))
            {
                return true;
            }       
        } 

        return false;   
    }
};