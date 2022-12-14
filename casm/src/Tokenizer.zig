const Tokenizer = @This();

const std = @import("std");
const IR = @import("IR.zig");

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
        literal_char,
        literal_string,
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
            .start => switch (char)
            {
                0 => break,
                ' ', '\t', '\r', '\n', => {
                    result.start = self.index + 1;
                },
                'a'...'z', 'A'...'Z', '_', => {
                    state = .identifier;
                    result.tag = .identifier;
                },
                '\'' => {
                    state = .literal_char;
                    result.tag = .literal_char;
                },
                '"' => {
                    state = .literal_string;
                    result.tag = .literal_string;
                },
                '0'...'9', '-', => {
                    if (char == '-')
                    {
                        state = .literal_integer;
                        result.tag = .literal_integer;
                    }
                    else 
                    {
                        switch (self.source[self.index + 1])
                        {
                            'B', 'b' => {
                                state = .literal_binary;
                                result.tag = .literal_binary;
                            },
                            'X', 'x' => {
                                state = .literal_hex;
                                result.tag = .literal_hex;
                            },
                            else => {
                                state = .literal_integer;
                                result.tag = .literal_integer;
                            },
                        }
                    }
                },
                '/' => {
                    state = .slash;
                },
                '{' => {
                    result.tag = .left_brace;
                    self.index += 1;

                    break;
                },
                '}' => {
                    result.tag = .right_brace;
                    self.index += 1;

                    break;
                },
                '(' => {
                    result.tag = .left_paren;
                    self.index += 1;

                    break;
                },
                ')' => {
                    result.tag = .right_paren;
                    self.index += 1;

                    break;
                },
                '$' => {
                    result.tag = .dollar;
                    self.index += 1;

                    break;
                }, 
                '=' => {
                    result.tag = .equals;
                    self.index += 1;

                    break;
                },
                ',' => {
                    result.tag = .comma;
                    self.index += 1;

                    break;
                },
                '.' => {
                    result.tag = .dot;
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
            },
            .identifier => {
                switch (char) 
                {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                    else => {
                        const string = self.source[result.start..self.index];

                        if (Token.isOperation(string))
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
                        else if (Token.getKeyword(string)) |keyword_tag|
                        {
                            result.tag = keyword_tag;
                        }

                        break;
                    },
                }
            },
            .literal_integer => {
                switch (char)
                {
                    '0'...'9', '_' => {},
                    else => break,
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
            .literal_char => {
                switch (char)
                {
                    else => {},
                    '\'' => {
                        self.index += 1;
                        break;
                    },
                }
            },
            .literal_string => {
                switch (char)
                {
                    else => {},
                    '\\' => {
                        self.index += 1;
                    },
                    '\"' => {
                        self.index += 1;
                        break;
                    },
                }
            },
            .slash => {
                switch (char)
                {
                    '/' => {
                        state = .single_comment;
                    },
                    '*' => {
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
        left_brace,
        right_brace,
        left_paren,
        right_paren,
        equals,
        dollar,
        dot,
        literal_integer,
        literal_hex,
        literal_binary,
        literal_char,
        literal_string,
        opcode,
        context_register,
        argument_register,
        keyword_import,
        keyword_export,
        keyword_entry,
        keyword_proc,
        keyword_var,
    };

    pub fn lexeme(tag: Tag) ?[]const u8
    {
        return switch (tag)
        {
            .end, 
            .identifier, 
            .literal_binary, 
            .literal_hex, 
            .literal_integer, 
            .literal_string,
            .literal_char,
            .opcode,
            .context_register,
            .argument_register,
            => null,
            .keyword_import => "import",
            .keyword_export => "export",
            .keyword_entry => "entry",
            .keyword_proc => "proc",
            .keyword_var => "var",
            .comma => ",",
            .semicolon => ";",
            .colon => ":",
            .equals => "=",
            .left_brace => "{",
            .right_brace => "}",
            .left_paren => "(",
            .right_paren => ")",
            .dollar => "$",
            .dot => ".",
        };
    }

    pub fn getOperation(string: []const u8) ?IR.Statement.Instruction.Operation
    {
        inline for (comptime std.meta.fieldNames(IR.Statement.Instruction.Operation)) |name|
        {
            if (std.mem.eql(u8, string, name))
            {
                return std.enums.nameCast(IR.Statement.Instruction.Operation, name);
            }
        }

        return null;
    }

    pub fn isOperation(string: []const u8) bool
    {
        return getOperation(string) != null;
    }

    pub fn getContextRegister(string: []const u8) ?IR.Statement.Instruction.Register
    {
        inline for (comptime std.meta.fieldNames(IR.Statement.Instruction.Register)) |name|
        {
            if (std.mem.eql(u8, string, name))
            {
                return switch (std.enums.nameCast(IR.Statement.Instruction.Register, name))
                {
                    .c0, .c1, .c2, .c3, .c4, .c5, .c6, .c7 => std.enums.nameCast(IR.Statement.Instruction.Register, name),
                    else => null,
                };
            }
        }

        return null;
    }

    pub fn isContextRegister(string: []const u8) bool 
    {
        return getContextRegister(string) != null;
    }

    pub fn getArgumentRegister(string: []const u8) ?IR.Statement.Instruction.Register
    {
        inline for (comptime std.meta.fieldNames(IR.Statement.Instruction.Register)) |name|
        {
            if (std.mem.eql(u8, string, name))
            {
                return switch (std.enums.nameCast(IR.Statement.Instruction.Register, name))
                {
                    .a0, .a1, .a2, .a3, .a4, .a5, .a6, .a7 => std.enums.nameCast(IR.Statement.Instruction.Register, name),
                    else => null,
                };
            }
        }

        return null;
    }

    pub fn isArgumentRegister(string: []const u8) bool
    {
        return getArgumentRegister(string) != null;
    }

    pub fn isKeyword(string: []const u8, comptime tag: Tag) bool
    {
        if (@tagName(tag).len < @sizeOf(@TypeOf("keyword_"))) return false;

        return std.mem.eql(u8, string, @tagName(tag)[@sizeOf(@TypeOf("keyword_"))..]);
    }

    pub fn getKeyword(string: []const u8) ?Tag
    {
        inline for (comptime std.enums.values(Tag)) |tag|
        {
            if (isKeyword(string, tag))
            {
                return tag;
            }
        }

        return null;
    }
};