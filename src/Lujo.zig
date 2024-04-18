const std = @import("std");
const LinkedList = @import("LinkedList.zig").LinkedList;
const String = []const u8;

const tk = @import("Tokenizer.zig");
const Tokenizer = tk.Tokenizer;
const Token = tk.Token;

const pa = @import("Parser.zig");
const Parser = pa.Parser;
const Node = pa.Node;
const ParseMessage = pa.ParseMessage;

const inte = @import("Interpreter.zig");
const Interpreter = inte.Interpreter;
const InterpreterResult = inte.InterpretResult;
const InterpreterResultType = inte.InterpretResultType;

const oom = @import("oom.zig");

const GB = 1024 * 1024 * 1024;
const RESET = "\x1B[0m";
const RED = "\x1B[31m";
const CYAN = "\x1B[96m";

pub const LujoValueType = enum {
    object,
    nil,
    boolean,
    number,
    string,
    callable // functions or class constructors
};

pub const LujoCallableType = enum {
    Callable,
    NativeFunction
};

pub const LujoCallable = union(LujoCallableType) {
    Callable: *Node,
    NativeFunction: *const fn () LujoValue
};

pub const LujoValue = union(LujoValueType) {
    object: void, // TODO: Temporary value until objects are supported
    nil: void,
    boolean: bool,
    number: f64,
    string: []const (u8),
    callable: LujoCallable,

    pub fn ownMemory(self: LujoValue, allocator: std.mem.Allocator) LujoValue {
        switch (self) {
            .object => unreachable, // TODO
            .nil => return self,
            .boolean => return self,
            .number => return self,
            .string => |refStr| {
                const copyStr = allocator.dupe(u8, refStr) catch oom.handleOutOfMemoryError();
                return LujoValue { .string = copyStr };
            },
            .callable => return self
        }
    }

    pub fn getTypeString(self: LujoValue) String {
        switch (self) {
            .object => return "object",
            .nil => return "nil",
            .boolean => return "boolean",
            .number => return "number",
            .string => return "string",
            .callable => return "callable"
        }
    }
};

pub const SourceFile = struct {
    filePath: String,
    content: String
};

pub fn interpretFile(filePath: String) !void {
    var stdout = std.io.getStdOut().writer();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    const fileContent = try std.fs.cwd().readFileAlloc(arena.allocator(), filePath, 4*GB);
    const sourceFile = SourceFile {
        .filePath = filePath,
        .content = fileContent
    };

    var tokenizer = Tokenizer.init(sourceFile.content);
    var parser = Parser.init(arena.allocator(), tokenizer, sourceFile);
    const parseResult = parser.parse();
    if (parseResult.hasErrors) {
        // The AST is in a inconsistent state, cannot interpret it. Show errors and exit.
        printParsingErrors(parseResult.messages, sourceFile, stdout);
        return;
    }

    var interpreter = Interpreter.init();
    const interpretResult = interpreter.interpret(parseResult.ast, sourceFile);
    if (interpretResult == InterpreterResultType.Error) {
        const line = getLineOfSourceCode(sourceFile, interpretResult.Error.atToken);
        stdout.print("{s}:{} {s}runtime error{s}: {s}\n", .{sourceFile.filePath, line, RED, RESET, interpretResult.Error.message}) catch unreachable;
        return;
    }
}

fn printParsingErrors(messageList: LinkedList(ParseMessage), sourceFile: SourceFile, stdout: std.fs.File.Writer) void {
    var node = messageList.first;
    while (node) |msg| : (node = msg.next) {
        // TODO: buffered print
        const fileName = msg.data.filePath;

        var lineNumber: usize = 1;
        var lineStartOffset: usize = 0;
        var columnNumber: usize = 1;
        for (0..msg.data.token.start) |i| {
            const c = sourceFile.content[i];
            if (c == '\n') {
                lineNumber += 1;
                columnNumber = 1;
                lineStartOffset = i+1;
            } else {
                columnNumber += 1;
            }
        }

        var lineEndOffset = lineStartOffset;
        for (lineEndOffset..sourceFile.content.len) |i| {
            lineEndOffset += 1;

            const c = sourceFile.content[i];
            if (c == '\r' or c == '\n') {
                break;
            }
        }

        const errorMsg = msg.data.message;
        const lineOfCode = sourceFile.content[lineStartOffset..lineEndOffset];

        stdout.print("{s}:{}:{}: {s}parse error{s}: {s}\n", .{fileName, lineNumber, columnNumber, RED, RESET, errorMsg}) catch unreachable;
        stdout.print("{s}\n", .{lineOfCode}) catch unreachable;


        // Print cursor
        var offset = lineStartOffset;
        for (lineStartOffset..msg.data.token.start) |_| {
            stdout.print(" ", .{}) catch unreachable;
            offset += 1;
        }

        stdout.print("{s}^", .{CYAN}) catch unreachable;
        offset += 1;

        const endOffset = msg.data.token.start + msg.data.token.len;
        var i = offset;
        while (i < endOffset) : (i += 1) {
            stdout.print("~", .{}) catch unreachable;
        }

        stdout.print("{s}\n\n", .{RESET}) catch unreachable;
    }
    
}

fn getLineOfSourceCode(sourceFile: SourceFile, token: Token) usize {
    var lineNumber: usize = 1;
    for (0..token.start) |i| {
        const c = sourceFile.content[i];
        if (c == '\n') {
            lineNumber += 1;
        }
    }
    return lineNumber;
}
