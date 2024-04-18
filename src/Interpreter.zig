const std = @import("std");
const LinkedList = @import("LinkedList.zig").LinkedList;
const String = []const u8;

const oom = @import("oom.zig");
const Lujo = @import("Lujo.zig");
const LujoMessage = Lujo.LujoMessage;
const LujoValue = Lujo.LujoValue;
const LujoCallableType = Lujo.LujoCallableType;
const LujoValueType = Lujo.LujoValueType;

const Token = @import("Tokenizer.zig").Token;
const Tokenizer = @import("Tokenizer.zig").Tokenizer;
const TokenType = @import("Tokenizer.zig").TokenType;

const Parser = @import("Parser.zig").Parser;
const ParseResult = @import("Parser.zig").ParseResult;
const Node = @import("Parser.zig").Node;
const NodeType = @import("Parser.zig").NodeType;


// Native functions
fn clock() LujoValue {
    const time: f64 = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0;
    return .{ .number = time };
}


pub const InterpretResultType = enum {
    Ok,
    BreakLoop,
    ContinueLoop,
    ReturnFromFunction,
    Error
};

pub const InterpretResult = union(InterpretResultType) {
    Ok: LujoValue,
    BreakLoop,
    ContinueLoop,
    ReturnFromFunction: LujoValue,
    Error: struct {
        message: String,
        atToken: Token
    }
};

const Environment = struct {
    startOffset: usize,
    env: std.StringHashMapUnmanaged(LujoValue)
};

const EnvironmentList = struct {
    const Self = @This();
    const EnvNode = std.SinglyLinkedList(Environment).Node;

    buffer: [2 * 1024 * 1024]u8,
    alloc: std.heap.FixedBufferAllocator,
    env: std.SinglyLinkedList(Environment),

    fn init() Self {
        var ret = Self {
            .buffer = undefined,
            .alloc = undefined,
            .env = std.SinglyLinkedList(Environment) {}
        };
        ret.alloc = std.heap.FixedBufferAllocator.init(&ret.buffer);
        return ret;
    }

    fn addLexicalScope(self: *Self) void {
        const startOffset = self.alloc.end_index;
        var scopeEnv = self.alloc.allocator().create(EnvNode) catch oom.handleOutOfMemoryError();
        scopeEnv.* = Self.EnvNode {
            .data = Environment {
                .startOffset = startOffset,
                .env = std.StringHashMapUnmanaged(LujoValue) {}
            }
        };
        self.env.prepend(scopeEnv);
    }

    fn destroyLexicalScope(self: *Self) void {
        // Global environment must always be available!
        std.debug.assert(self.env.first != null);

        const newOffset = self.env.first.?.data.startOffset;
        _ = self.env.popFirst();
        self.alloc.end_index = newOffset;
    }

    // Creates a new binding between a name and a value in the current environment. It doesn't overwrite any variables
    // with the same name in the parent environments.
    fn declareVariable(self: *Self, varName: String, value: LujoValue) void {
        // Global environment must always be available!
        std.debug.assert(self.env.first != null);

        // Re-declaring existing variables in the same environment is intended behaviour
        self.env.first.?.data.env.put(
            self.alloc.allocator(),
            varName,
            value
        ) catch oom.handleOutOfMemoryError();
    }

    fn getValue(self: *Self, varName: String) ?LujoValue {
        // Global environment must always be available!
        std.debug.assert(self.env.first != null);

        var environment = self.env.first;
        std.debug.assert(environment != null); // Global environment must always be available!
        while (environment) |env| : (environment = env.next) {
            if (env.data.env.get(varName)) |value| {
                return value;
            }
        }

        return null;
    }

    fn getValueRef(self: *Self, varName: String) ?*LujoValue {
        // Global environment must always be available!
        std.debug.assert(self.env.first != null);

        var environment = self.env.first;
        std.debug.assert(environment != null); // Global environment must always be available!
        while (environment) |env| : (environment = env.next) {
            if (env.data.env.getPtr(varName)) |value| {
                return value;
            }
        }

        return null;
    }
};


// TODO: Memory is leaking when evaluating some expressions (strings, objects, etc). Add garbage collector.
pub const Interpreter = struct {
    printScratch: std.heap.ArenaAllocator, // Only used for printing stuff on the screen
    leakingAllocator: std.heap.ArenaAllocator, // TODO: Replace this with a garbage collector
    environment: EnvironmentList,
    stdout: std.fs.File.Writer,
    lastMsgBuffer: [1024]u8,

    pub fn init() Interpreter {
        var ret = Interpreter {
            .printScratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .leakingAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .environment = EnvironmentList.init(),
            .stdout = std.io.getStdOut().writer(),
            .lastMsgBuffer = undefined
        };

        // Add global environment. Must never be deleted.
        ret.environment.addLexicalScope();

        // Expose native functions in the global environment
        ret.environment.declareVariable("clock", LujoValue { .callable = .{ .NativeFunction = &clock } });

        return ret;
    }

    pub fn interpret(self: *Interpreter, ast: []*Node, sourceFile: Lujo.SourceFile) InterpretResult {
        defer _ = self.printScratch.reset(std.heap.ArenaAllocator.ResetMode.retain_capacity);

        for (ast) |decl| {
            const parseResult = self.interpretRecursively(decl, sourceFile);
            if (parseResult == InterpretResultType.Error) {
                // Stop interpreting the AST because any further operations will be nonsense
                return parseResult;
            }
        }

        return InterpretResult { .Ok = LujoValue.nil };
    }

    fn interpretRecursively(self: *Interpreter, node: *Node, sourceFile: Lujo.SourceFile) InterpretResult {
        switch (node.data) {
            // TODO: ownMemory() is leaking. Add garbage collector!
            NodeType.ExprLiteral => |literal| return InterpretResult { .Ok = literal.ownMemory(self.leakingAllocator.allocator()) },
            NodeType.ExprUnary => return self.interpretUnary(node, sourceFile),
            NodeType.ExprBinary => return self.interpretBinary(node, sourceFile),
            NodeType.ExprGrouping => |groupingNode| return self.interpretRecursively(groupingNode, sourceFile),
            NodeType.ExprIdentifier => |identifier| {
                const varName = sourceFile.content[identifier.start..(identifier.start + identifier.len)];

                const value = self.environment.getValue(varName);
                if (value) |val| return .{ .Ok = val };

                // Should only reach this point if the variable has not been declared
                return self.interpretError("Variable \"{s}\" is not defined", .{varName}, identifier);
            },
            NodeType.ExprAssignment => |assignment| {
                const lValue = assignment.lValue;
                const varName = sourceFile.content[lValue.data.ExprIdentifier.start..(lValue.data.ExprIdentifier.start + lValue.data.ExprIdentifier.len)];

                // We should only evaluate the right expression if the variable exists. Otherwise it should not be evaluated to
                // avoid any side-effects.
                if (self.environment.getValueRef(varName)) |bindValue| {
                    const newValue = self.interpretRecursively(assignment.rValue, sourceFile);

                    // Assignment to a variable must never reach a point where a break, continue or return statements execute
                    std.debug.assert(newValue != InterpretResultType.BreakLoop and
                                     newValue != InterpretResultType.ContinueLoop and
                                     newValue != InterpretResultType.ReturnFromFunction);

                    if (newValue == InterpretResultType.Error) {
                        return newValue;
                    } else {
                        bindValue.* = newValue.Ok;
                        return .{ .Ok = newValue.Ok };
                    }
                }

                // Should only reach this point if the variable has not been declared
                std.debug.assert(lValue.data == NodeType.ExprIdentifier);
                const varToken = lValue.data.ExprIdentifier;
                return self.interpretError("Variable \"{s}\" is not defined", .{varName}, varToken);
            },
            NodeType.ExprLogicOr => |logicOrNode| {
                const left = self.interpretRecursively(logicOrNode.left, sourceFile);
                if (left == InterpretResultType.Error) return left;

                // When evaluating the operands it must never reach a point where a break, continue or return statements execute
                std.debug.assert(left != InterpretResultType.BreakLoop and
                                 left != InterpretResultType.ContinueLoop and
                                 left != InterpretResultType.ReturnFromFunction);

                if (isTruthy(left.Ok)) {
                    // No need to evaluate the right operand
                    return .{ .Ok = LujoValue { .boolean = true } };
                }

                const right = self.interpretRecursively(logicOrNode.right, sourceFile);
                if (right == InterpretResultType.Error) return right;

                // When evaluating the operands it must never reach a point where a break, continue or return statements execute
                std.debug.assert(right != InterpretResultType.BreakLoop and
                                 right != InterpretResultType.ContinueLoop and
                                 right != InterpretResultType.ReturnFromFunction);

                if (isTruthy(right.Ok)) {
                    return .{ .Ok = LujoValue { .boolean = true } };
                } else {
                    return .{ .Ok = LujoValue { .boolean = false } };
                }
            },
            NodeType.ExprLogicAnd => |logicAndNode| {
                const left = self.interpretRecursively(logicAndNode.left, sourceFile);
                if (left == InterpretResultType.Error) return left;

                // When evaluating the operands it must never reach a point where a break, continue or return statements execute
                std.debug.assert(left != InterpretResultType.BreakLoop and
                                 left != InterpretResultType.ContinueLoop and
                                 left != InterpretResultType.ReturnFromFunction);

                if (! isTruthy(left.Ok)) {
                    // No need to evaluate the right operand
                    return .{ .Ok = LujoValue { .boolean = false } };
                }

                const right = self.interpretRecursively(logicAndNode.right, sourceFile);
                if (right == InterpretResultType.Error) return right;

                // When evaluating the operands it must never reach a point where a break, continue or return statements execute
                std.debug.assert(right != InterpretResultType.BreakLoop and
                                 right != InterpretResultType.ContinueLoop and
                                 right != InterpretResultType.ReturnFromFunction);

                if (isTruthy(right.Ok)) {
                    return .{ .Ok = LujoValue { .boolean = true } };
                } else {
                    return .{ .Ok = LujoValue { .boolean = false } };
                }
            },
            NodeType.ExprCallable => |callableNode| {
                const callee = self.interpretRecursively(callableNode.callee, sourceFile);
                if (callee == InterpretResultType.Error) return callee;
                if (callee.Ok != LujoValueType.callable) {
                    const calStr = callee.Ok.getTypeString();
                    return self.interpretError("{s} is not callable", .{calStr}, callableNode.location);
                }

                // When evaluating the callee it must never reach a point where a break, continue or return statements execute
                std.debug.assert(callee != InterpretResultType.BreakLoop and
                                 callee != InterpretResultType.ContinueLoop and
                                 callee != InterpretResultType.ReturnFromFunction);

                self.environment.addLexicalScope();
                defer self.environment.destroyLexicalScope();

                // Execute callable
                switch (callee.Ok.callable) {
                    LujoCallableType.Callable => |callable| {
                        // User-defined function in Lujo
                        // TODO: Remove this assert by making a Callable Node to point to a DeclFunctionNode directly
                        std.debug.assert(callable.data == NodeType.DeclFunction); // LujoValue.callable must point to a DeclFunction node
                        const functionDeclNode = callable.data.DeclFunction;

                        // Create a new lexical environment for the function
                        self.environment.addLexicalScope();
                        defer self.environment.destroyLexicalScope();

                        // Check arity
                        const funParamLen = functionDeclNode.parameters.length;
                        const callArgLen = callableNode.arguments.length;
                        if (funParamLen != callArgLen) {
                            return self.interpretError("Expected {} argument(s) to call function \"{s}\". {} argument(s) given.", .{ funParamLen, functionDeclNode.name, callArgLen }, callableNode.location);
                        }

                        // Map parameters to arguments
                        var parameter = functionDeclNode.parameters.first;
                        var argument = callableNode.arguments.first;
                        while (parameter != null) : ({ parameter = parameter.?.next; argument = argument.?.next; }) {
                            const paramName = parameter.?.data;

                            // Evaluate argument
                            const thisArg = self.interpretRecursively(argument.?.data, sourceFile);
                            if (thisArg == InterpretResult.Error) return thisArg;

                            // When evaluating the argument it must never reach a point where a break, continue or return statements execute
                            std.debug.assert(callee != InterpretResultType.BreakLoop and
                                             callee != InterpretResultType.ContinueLoop and
                                             callee != InterpretResultType.ReturnFromFunction);

                            const argumentValue = thisArg.Ok;

                            self.environment.declareVariable(paramName, argumentValue);
                        }

                        // Execute the function
                        var ret: InterpretResult = undefined;

                        const funcBodyResult = self.interpretRecursively(functionDeclNode.block, sourceFile);
                        // When evaluating the function body it must never reach a point where a break or continue statements execute
                        std.debug.assert(funcBodyResult != InterpretResultType.BreakLoop and
                                         funcBodyResult != InterpretResultType.ContinueLoop);

                        switch (funcBodyResult) {
                            .Ok => |val| ret = .{ .Ok = val },
                            .Error => |val| ret = .{ .Error = val },
                            .ReturnFromFunction => |val| ret = .{ .Ok = val },
                            else => unreachable,
                        }

                        std.debug.assert(ret == InterpretResultType.Ok or ret == InterpretResultType.Error);
                        return ret;
                    },
                    LujoCallableType.NativeFunction => |func| {
                        // TODO: add support for arguments in native functions
                        // TODO: check arity
                        // TODO: map parameters to arguments
                        const ret = func();
                        return .{ .Ok = ret };
                    }
                }
            },
            NodeType.StmtPrint => |printNode| {
                defer _ = self.printScratch.reset(std.heap.ArenaAllocator.ResetMode.retain_capacity);

                // TODO: leaks memory if used in a while loop
                const value = self.interpretRecursively(printNode, sourceFile);

                // When evaluating the print expression it must never reach a point where a break, continue or return statements execute
                std.debug.assert(value != InterpretResultType.BreakLoop and
                                 value != InterpretResultType.ContinueLoop and
                                 value != InterpretResultType.ReturnFromFunction);

                if (value == InterpretResultType.Error) {
                    return value;
                } else {
                    const valueStr = stringify(self.printScratch.allocator(), value.Ok);
                    if (self.stdout.print("{s}\n", .{valueStr})) {
                    } else |_| {
                        // Just ignore the error
                    }
                    return InterpretResult { .Ok = LujoValue.nil };
                }
            },
            NodeType.StmtExpression => |stmtExpressionNode| return self.interpretRecursively(stmtExpressionNode, sourceFile),
            NodeType.StmtBlock => |blockNode| {
                self.environment.addLexicalScope();
                defer self.environment.destroyLexicalScope();

                for (blockNode.items) |stmtNode| {
                    const result = self.interpretRecursively(stmtNode, sourceFile);
                    if (result == InterpretResultType.Error or
                        result == InterpretResultType.BreakLoop or
                        result == InterpretResultType.ContinueLoop or
                        result == InterpretResultType.ReturnFromFunction) return result;
                }
            },
            NodeType.StmtIf => |branchNode| {
                const condition = self.interpretRecursively(branchNode.condition, sourceFile);
                if (condition == InterpretResultType.Error) return condition;

                // Evaluate if-else statement
                if (isTruthy(condition.Ok)) {
                    return self.interpretRecursively(branchNode.ifBranch, sourceFile);
                } else if (branchNode.elseBranch) |elseBranch| {
                    return self.interpretRecursively(elseBranch, sourceFile);
                }

                return .{ .Ok = LujoValue.nil };
            },
            NodeType.StmtFor => |forNode| {
                // Loop initialization
                if (forNode.initialization) |initialization| {
                    const initLoop = self.interpretRecursively(initialization, sourceFile);
                    if (initLoop == InterpretResultType.Error) return initLoop;
                }

                while (true) {
                    // Evaluate loop condition
                    var condition: bool = true;
                    if (forNode.condition) |cond| {
                        const conditionExpr = self.interpretRecursively(cond, sourceFile);
                        if (conditionExpr == InterpretResultType.Error) return conditionExpr;

                        condition = isTruthy(conditionExpr.Ok);
                    }

                    if (! condition) break;

                    // Execute loop body
                    const body = self.interpretRecursively(forNode.body, sourceFile);
                    switch (body) {
                        .Error => return body,
                        .BreakLoop => return .{ .Ok = LujoValue.nil },
                        .ReturnFromFunction => return .{ .Ok = LujoValue.nil },
                        else => {} // Ignore Ok and ContinueLoop
                    }

                    // Loop increment. Must always be executed as the last statement, even in a continue statement.
                    if (forNode.increment) |inc| {
                        const increment = self.interpretRecursively(inc, sourceFile);
                        if (increment == InterpretResultType.Error) return increment;
                    }
                }

                return .{ .Ok = LujoValue.nil };
            },
            NodeType.StmtBreak => return InterpretResultType.BreakLoop,
            NodeType.StmtContinue => return InterpretResultType.ContinueLoop,
            NodeType.StmtReturn => |returnNode| {
                var returnValue: LujoValue = LujoValue.nil;

                if (returnNode) |retNode| {
                    const retResult = self.interpretRecursively(retNode, sourceFile);
                    if (retResult == InterpretResultType.Error) return retResult;

                    // When evaluating the return value it must never reach a point where a break, continue or another return statement execute
                    std.debug.assert(retResult != InterpretResultType.BreakLoop and
                                     retResult != InterpretResultType.ContinueLoop and
                                     retResult != InterpretResultType.ReturnFromFunction);

                    returnValue = retResult.Ok;
                }

                return .{ .ReturnFromFunction = returnValue };
            },
            NodeType.DeclVar => |declVarNode| {
                // Re-declaring existing variables is intended behaviour
                const varName = sourceFile.content[declVarNode.variableName.start..(declVarNode.variableName.start + declVarNode.variableName.len)];
                var value: LujoValue = LujoValue.nil;
                if (declVarNode.rValue) |expr| {
                    const result = self.interpretRecursively(expr, sourceFile);
                    if (result == InterpretResultType.Error) {
                        return result;
                    } else {
                        value = result.Ok;
                    }
                }

                self.environment.declareVariable(varName, value);
            },
            NodeType.DeclFunction => |declFunctionNode| {
                // TODO: LujoValue.callable is currently a *Node, but it should point directly to a data structure that represents a Function.
                // You can theoretically point to any arbitrary Node in the AST, but we should narrow it down to a function.
                const functionNode = LujoValue { .callable = .{ .Callable = node } };

                // Declare function in the current environment
                self.environment.declareVariable(declFunctionNode.name, functionNode);

                return .{ .Ok = functionNode };
            },
        }

        return .{ .Ok = LujoValue.nil };
    }

    fn interpretUnary(self: *Interpreter, node: *Node, sourceFile: Lujo.SourceFile) InterpretResult {
        const nodeUnary = node.data.ExprUnary;
        const result = self.interpretRecursively(nodeUnary.right, sourceFile);
        if (result == InterpretResultType.Error) {
            return result;
        } else {
            const right = result.Ok;
            switch (nodeUnary.operator.type) {
                TokenType.Minus => {
                    if (right == LujoValueType.number) {
                        return .{ .Ok = LujoValue { .number = -right.number } };
                    } else {
                        const valueName = right.getTypeString();
                        return self.interpretError("Negation only apply to numbers. Right operand is {s}", .{valueName}, nodeUnary.operator);
                    }
                },
                TokenType.Bang => {
                    const val = isTruthy(right);
                    return .{ .Ok = LujoValue { .boolean = !val } };
                },
                else => unreachable
            }
        }
    }

    fn interpretBinary(self: *Interpreter, node: *Node, sourceFile: Lujo.SourceFile) InterpretResult {
        const binaryNode = node.data.ExprBinary;
        const leftResult = self.interpretRecursively(binaryNode.left, sourceFile);
        if (leftResult == InterpretResultType.Error) return leftResult;

        const rightResult = self.interpretRecursively(binaryNode.right, sourceFile);
        if (rightResult == InterpretResultType.Error) return rightResult;

        const left = leftResult.Ok;
        const right = rightResult.Ok;
        switch (binaryNode.operator.type) {
            TokenType.Minus => {
                if (left != LujoValueType.number) {
                    const leftValueName = left.getTypeString();
                    return self.interpretError("Left operand for subtraction must be a number. {s} given", .{leftValueName}, binaryNode.operator);
                }

                if (right != LujoValueType.number) {
                    const rightValueName = left.getTypeString();
                    return self.interpretError("Right operand for subtraction must be a number. {s} given", .{rightValueName}, binaryNode.operator);
                }

                const res = left.number - right.number;
                return .{ .Ok = LujoValue { .number = res } };
            },
            TokenType.Slash => {
                if (left != LujoValueType.number) {
                    const leftValueName = left.getTypeString();
                    return self.interpretError("Left operand for division must be a number. {s} given", .{leftValueName}, binaryNode.operator);
                }

                if (right != LujoValueType.number) {
                    const rightValueName = left.getTypeString();
                    return self.interpretError("Right operand for division must be a number. {s} given", .{rightValueName}, binaryNode.operator);
                }

                const res = left.number / right.number;
                return .{ .Ok = LujoValue { .number = res } };
            },
            TokenType.Star => {
                if (left != LujoValueType.number) {
                    const leftValueName = left.getTypeString();
                    return self.interpretError("Left operand for multiplication must be a number. {s} given", .{leftValueName}, binaryNode.operator);
                }

                if (right != LujoValueType.number) {
                    const rightValueName = left.getTypeString();
                    return self.interpretError("Right operand for multiplication must be a number. {s} given", .{rightValueName}, binaryNode.operator);
                }

                const res = left.number * right.number;
                return .{ .Ok = LujoValue { .number = res } };
            },
            TokenType.Plus => {
                if (left == LujoValue.number and right == LujoValue.number) {
                    const l = left.number;
                    const r = right.number;
                    const res = l + r;
                    return .{ .Ok = LujoValue { .number = res } };
                } else if (left == LujoValue.string and right == LujoValue.string) {
                    const l = left.string;
                    const r = right.string;
                    const str = std.mem.concat(self.leakingAllocator.allocator(), u8, &[_]String{ l, r }) catch oom.handleOutOfMemoryError();
                    return .{ .Ok = LujoValue { .string = str } };
                } else {
                    const leftValueName = LujoValue.getTypeString(left);
                    const rightValueName = LujoValue.getTypeString(right);
                    return self.interpretError("Invalid addition. Can only use '+' operator with numbers or strings. {s} and {s} given.", .{leftValueName, rightValueName}, binaryNode.operator);
                }
            },
            TokenType.Greater => {
                if (left != LujoValueType.number) {
                    const leftValueName = left.getTypeString();
                    return self.interpretError("Left operand for '>' operator must be a number. {s} given", .{leftValueName}, binaryNode.operator);
                }

                if (right != LujoValueType.number) {
                    const rightValueName = left.getTypeString();
                    return self.interpretError("Right operand for '>' operator must be a number. {s} given", .{rightValueName}, binaryNode.operator);
                }

                const res = left.number > right.number;
                return .{ .Ok = LujoValue { .boolean = res } };
            },
            TokenType.GreaterEqual => {
                if (left != LujoValueType.number) {
                    const leftValueName = left.getTypeString();
                    return self.interpretError("Left operand for '>=' operator must be a number. {s} given", .{leftValueName}, binaryNode.operator);
                }

                if (right != LujoValueType.number) {
                    const rightValueName = left.getTypeString();
                    return self.interpretError("Right operand for '>=' operator must be a number. {s} given", .{rightValueName}, binaryNode.operator);
                }

                const res = left.number >= right.number;
                return .{ .Ok = LujoValue { .boolean = res } };
            },
            TokenType.Less => {
                if (left != LujoValueType.number) {
                    const leftValueName = left.getTypeString();
                    return self.interpretError("Left operand for '<' operator must be a number. {s} given", .{leftValueName}, binaryNode.operator);
                }

                if (right != LujoValueType.number) {
                    const rightValueName = left.getTypeString();
                    return self.interpretError("Right operand for '<' operator must be a number. {s} given", .{rightValueName}, binaryNode.operator);
                }

                const res = left.number < right.number;
                return .{ .Ok = LujoValue { .boolean = res } };
            },
            TokenType.LessEqual => {
                if (left != LujoValueType.number) {
                    const leftValueName = left.getTypeString();
                    return self.interpretError("Left operand for '>=' operator must be a number. {s} given", .{leftValueName}, binaryNode.operator);
                }

                if (right != LujoValueType.number) {
                    const rightValueName = left.getTypeString();
                    return self.interpretError("Right operand for '>=' operator must be a number. {s} given", .{rightValueName}, binaryNode.operator);
                }

                const res = left.number <= right.number;
                return .{ .Ok = LujoValue { .boolean = res } };
            },
            TokenType.EqualEqual => {
                return .{ .Ok = LujoValue { .boolean = isEqual(left, right) } };
            },
            TokenType.BangEqual => {
                return .{ .Ok = LujoValue { .boolean = !isEqual(left, right) } };
            },
            else => unreachable
        }
    }

    fn interpretError(self: *Interpreter, comptime msgTemplate: String, args: anytype, atToken: Token) InterpretResult {
        // TODO: Maybe bufPrint() should be bufAlloc() because we only have a fixed-sized buffer and variable name length
        // is unbounded, at least for now.
        return .{
            .Error = .{
                .message = std.fmt.bufPrint(&self.lastMsgBuffer, msgTemplate, args) catch oom.handleOutOfMemoryError(),
                .atToken = atToken
            }
        };
    }

};

fn stringify(allocator: std.mem.Allocator, value: LujoValue) String {
    switch (value) {
        LujoValue.nil => return "nil",
        LujoValue.object => return "{}",
        LujoValue.boolean => |val| {
            if (val) {
                return "true";
            } else {
                return "false";
            }
        },
        LujoValue.number => |num| return std.fmt.allocPrint(allocator, "{d}", .{num}) catch oom.handleOutOfMemoryError(),
        LujoValue.string => |str| return str,
        LujoValue.callable => return "[callable]"
    }
}

fn isTruthy(value: LujoValue) bool {
    switch (value) {
        .nil => return false,
        .boolean => |val| return val,
        else => return true
    }
}

fn isEqual(left: LujoValue, right: LujoValue) bool {
    if (left == LujoValue.object and right == LujoValue.object) {
        // TODO: handle object equality
        return false;
    } else if (left == LujoValue.nil and right == LujoValue.nil) {
        return true;
    } else if (left == LujoValue.boolean and right == LujoValue.boolean) {
        return left.boolean == right.boolean;
    } else if (left == LujoValue.number and right == LujoValue.number) {
        return left.number == right.number;
    } else if (left == LujoValue.string and right == LujoValue.string) {
        const res = std.mem.eql(u8, left.string, right.string);
        return res;
    } else {
        return false;
    }
}
