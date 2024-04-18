const std = @import("std");
const String = []const u8;

const VERTICAL_TAB = 0xB;
const EOF = 0x0;

pub const TokenType = enum {
      LeftParenthesis,
      RightParenthesis,

      LeftBrace,
      RightBrace,

      Comma,
      Dot,
      Minus,
      Plus,
      Semicolon,
      Slash,
      Star,

      Bang,
      BangEqual,

      Equal,
      EqualEqual,

      Greater,
      GreaterEqual,

      Less,
      LessEqual,

      Identifier,
      String,
      Number,

      And,
      Class,
      Else,
      False,
      Fun,
      For,
      If,
      Nil,
      Or,
      Print,
      Return,
      Super,
      This,
      True,
      Var,
      While,
      Break,
      Continue,

      EOF,
      Error
};

pub const TokenError = enum {
    None,
    InvalidSingleLineString,
    InvalidToken,
    NumberMissingDecimal
};

pub const Token = struct {
    type: TokenType,
    errorKind: TokenError,
    start: usize,
    len: usize,
};

fn isDigit(c: u8) bool {
    return c >= 48 and c <= 57;
}

fn isAlpha(c: u8) bool {
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122);
}

fn isAlphaNum(c: u8) bool {
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122);
}

pub const Tokenizer = struct {
    sourceCode: String,
    index: usize,

    pub fn init(sourceCode: String) Tokenizer {
        return Tokenizer {
            .sourceCode = sourceCode,
            .index = 0
        };
    }

    pub fn nextToken(self: *Tokenizer) Token {
        var startIndex = self.index;
        while (self.index < self.sourceCode.len) {
            const c = self.sourceCode[self.index];
            self.index += 1;

            switch (c) {
                ' ', '\t', VERTICAL_TAB, '\r', '\n' => startIndex = self.index,

                '(' => return Token { .type = TokenType.LeftParenthesis, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },
                ')' => return Token { .type = TokenType.RightParenthesis, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },

                '{' => return Token { .type = TokenType.LeftBrace, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },
                '}' => return Token { .type = TokenType.RightBrace, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },

                '+' => return Token { .type = TokenType.Plus, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },
                '-' => return Token { .type = TokenType.Minus, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },
                '*' => return Token { .type = TokenType.Star, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },
                '/' => {
                    if (self.peekCharacter() == '/') {
                        // Line comment
                        self.eatCharacter();

                        while (self.index < self.sourceCode.len) {
                            const c2 = self.sourceCode[self.index];
                            self.index += 1;

                            // TODO: Handle CRLF line terminators
                            if (c2 == '\r' or c2 == '\n') {
                                startIndex = self.index;
                                break;
                            }
                        }

                        continue;
                    } else {
                        return Token {
                            .type = TokenType.Slash,
                            .errorKind = TokenError.None,
                            .start = startIndex,
                            .len = self.index - startIndex
                        };
                    }
                },
                ',' => return Token { .type = TokenType.Comma, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },
                '.' => return Token { .type = TokenType.Dot, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },
                ';' => return Token { .type = TokenType.Semicolon, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex },

                '!' => {
                    if (self.peekCharacter() == '=') {
                        self.eatCharacter();
                        return Token { .type = TokenType.BangEqual, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                    } else {
                        return Token { .type = TokenType.Bang, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                    }
                },
                '=' => {
                    if (self.peekCharacter() == '=') {
                        self.eatCharacter();
                        return Token { .type = TokenType.EqualEqual, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                    } else {
                        return Token { .type = TokenType.Equal, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                    }
                },
                '>' => {
                    if (self.peekCharacter() == '=') {
                        self.eatCharacter();
                        return Token { .type = TokenType.GreaterEqual, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                    } else {
                        return Token { .type = TokenType.Greater, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                    }
                },
                '<' => {
                    if (self.peekCharacter() == '=') {
                        self.eatCharacter();
                        return Token { .type = TokenType.LessEqual, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                    } else {
                        return Token { .type = TokenType.Less, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                    }
                },
                '"' => {
                    // String literal
                    while (self.index < self.sourceCode.len) {
                        var c2 = self.sourceCode[self.index];
                        self.index += 1;

                        if (c2 == '\r' or c2 == '\n' or c2 == EOF) {
                            // Multi-line strings are not supported
                            return Token {
                                .type = TokenType.Error,
                                .errorKind = TokenError.InvalidSingleLineString,
                                .start = startIndex,
                                .len = self.index - startIndex
                            };
                        } else if (c2 == '"') {
                            return Token {
                                .type = TokenType.String,
                                .errorKind = TokenError.None,
                                .start = startIndex,
                                .len = self.index - startIndex
                            };
                        }
                    }

                    return Token {
                        .type = TokenType.Error,
                        .errorKind = TokenError.InvalidSingleLineString,
                        .start = startIndex,
                        .len = self.index - startIndex
                    };
                },

                else => {
                    if (isDigit(c)) {
                        while (isDigit(self.peekCharacter())) {
                            self.eatCharacter();
                        }

                        // Optional decimal part. If the next token is '.', then it must be followed by at least one digit
                        if (self.peekCharacter() == '.') {
                            self.eatCharacter();

                            if (!isDigit(self.peekCharacter())) {
                                return Token {
                                    .type = TokenType.Error,
                                    .errorKind = TokenError.NumberMissingDecimal,
                                    .start = startIndex,
                                    .len = self.index - startIndex
                                };
                            }

                            while (isDigit(self.peekCharacter())) {
                                self.eatCharacter();
                            }
                        }

                        return Token {
                            .type = TokenType.Number,
                            .errorKind = TokenError.None,
                            .start = startIndex,
                            .len = self.index - startIndex
                        };
                    } else if (isAlpha(c)) {
                        while (isAlphaNum(self.peekCharacter())) {
                            self.eatCharacter();
                        }

                        const str = self.sourceCode[startIndex..self.index];
                        if (std.mem.eql(u8, str, "and")) {
                            return Token { .type = TokenType.And, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "class")) {
                            return Token { .type = TokenType.Class, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "else")) {
                            return Token { .type = TokenType.Else, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "false")) {
                            return Token { .type = TokenType.False, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "fun")) {
                            return Token { .type = TokenType.Fun, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "for")) {
                            return Token { .type = TokenType.For, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "if")) {
                            return Token { .type = TokenType.If, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "nil")) {
                            return Token { .type = TokenType.Nil, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "or")) {
                            return Token { .type = TokenType.Or, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "print")) {
                            return Token { .type = TokenType.Print, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "return")) {
                            return Token { .type = TokenType.Return, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "super")) {
                            return Token { .type = TokenType.Super, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "this")) {
                            return Token { .type = TokenType.This, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "true")) {
                            return Token { .type = TokenType.True, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "var")) {
                            return Token { .type = TokenType.Var, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "while")) {
                            return Token { .type = TokenType.While, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "break")) {
                            return Token { .type = TokenType.Break, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else if (std.mem.eql(u8, str, "continue")) {
                            return Token { .type = TokenType.Continue, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        } else {
                            return Token { .type = TokenType.Identifier, .errorKind = TokenError.None, .start = startIndex, .len = self.index - startIndex };
                        }
                    }

                    return Token {
                        .type = TokenType.Error,
                        .errorKind = TokenError.InvalidToken,
                        .start = self.index,
                        .len = 0
                    };
                }
            }
        }

        return Token {
            .type = TokenType.EOF,
            .errorKind = TokenError.None,
            .start = self.index,
            .len = 0
        };
    }

    pub fn eatToken(self: *Tokenizer) void {
        _ = self.nextToken();
    }

    pub fn peekToken(self: *Tokenizer) Token {
        const startIndex = self.index;
        const ret = self.nextToken();

        self.index = startIndex;
        return ret;
    }

    pub fn getLexeme(self: *Tokenizer, token: Token) String {
        std.debug.assert(token.start >= 0 and token.start < self.sourceCode.len);
        std.debug.assert(token.start + token.len <= self.sourceCode.len);
        const ret = self.sourceCode[token.start..(token.start + token.len)];
        return ret;
    }


    fn peekCharacter(self: Tokenizer) u8 {
        if (self.index >= self.sourceCode.len) return EOF
        else return self.sourceCode[self.index];
    }

    fn eatCharacter(self: *Tokenizer) void {
        if (self.index < self.sourceCode.len) self.index += 1;
    }
};

