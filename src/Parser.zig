const std = @import("std");
const LinkedList = @import("LinkedList.zig").LinkedList;
const String = []const u8;

const oom = @import("oom.zig");

const Lujo = @import("Lujo.zig");
const LujoValue = Lujo.LujoValue;

const tk = @import("Tokenizer.zig");
const Token = tk.Token;
const Tokenizer = tk.Tokenizer;
const TokenType = tk.TokenType;


pub const NodeType = enum {
    ExprLiteral,
    ExprGrouping,
    ExprUnary,
    ExprBinary,
    ExprIdentifier,
    ExprAssignment,
    ExprLogicOr,
    ExprLogicAnd,
    ExprCallable,

    StmtExpression,
    StmtPrint,
    StmtBlock,
    StmtIf,
    StmtFor,
    StmtBreak,
    StmtContinue,
    StmtReturn,

    DeclVar,
    DeclFunction
};

pub const ExprUnaryNode = struct {
    operator: Token,
    right: *Node
};

pub const ExprBinaryNode = struct {
    left: *Node,
    operator: Token,
    right: *Node
};

pub const ExprAssignmentNode = struct {
    lValue: *Node,
    rValue: *Node
};

pub const StmtBlockNode = std.ArrayList(*Node);

pub const DeclVarNode = struct {
    variableName: Token,
    rValue: ?*Node
};

pub const StmtIfNode = struct {
    condition: *Node,
    ifBranch: *Node,
    elseBranch: ?*Node
};

pub const ExprLogicOrNode = struct {
    left: *Node,
    right: *Node
};

pub const ExprLogicAndNode = struct {
    left: *Node,
    right: *Node
};

pub const StmtForNode = struct {
    initialization: ?*Node,
    condition: ?*Node,
    increment: ?*Node,
    body: *Node
};

pub const ExprCallableNode = struct {
    location: Token, // location in source code. Only used for error reporting
    callee: *Node,
    arguments: LinkedList(*Node)
};

pub const DeclFunctionNode = struct {
    name: String,
    parameters: LinkedList(String),
    block: *Node
};

pub const NodeData = union(NodeType) {
    ExprLiteral: LujoValue,
    ExprGrouping: *Node,
    ExprUnary: ExprUnaryNode,
    ExprBinary: ExprBinaryNode,
    ExprIdentifier: Token,
    ExprAssignment: ExprAssignmentNode,
    ExprLogicOr: ExprLogicOrNode,
    ExprLogicAnd: ExprLogicAndNode,
    ExprCallable: ExprCallableNode,

    StmtExpression: *Node,
    StmtPrint: *Node,
    StmtBlock: StmtBlockNode, // TODO: Replace with Singly Linked-List that inserts in order in constant time
    StmtIf: StmtIfNode,
    StmtFor: StmtForNode,
    StmtBreak,
    StmtContinue,
    StmtReturn: ?*Node,

    DeclVar: DeclVarNode,
    DeclFunction: DeclFunctionNode
};

pub const Node = struct {
    data: NodeData
};

const ParentBlock = struct {
    isLoop: bool,
    isFunction: bool
};

pub const ParseMessage = struct {
    filePath: String,
    token: Token,
    message: String
};

pub const ParseResult = struct {
    ast: []*Node,
    hasErrors: bool,
    messages: LinkedList(ParseMessage),

    pub fn addErrorMessage(self: *ParseResult, msg: String, token: Token, filePath: String) void {
        self.messages.append(ParseMessage {
            .filePath = filePath,
            .token = token,
            .message = msg
        });
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    sourceFile: Lujo.SourceFile,

    pub fn init(allocator: std.mem.Allocator, tokenizer: Tokenizer, sourceFile: Lujo.SourceFile) Parser {
        // tokenList must not contain any invalid tokens
        var ret = Parser {
            .allocator = allocator,
            .tokenizer = tokenizer,
            .sourceFile = sourceFile
        };
        return ret;
    }

    pub fn parse(self: *Parser) ParseResult {
        var declarations = std.ArrayListUnmanaged(*Node).initCapacity(self.allocator, 2048) catch oom.handleOutOfMemoryError();
        var ret = ParseResult {
            .ast = declarations.items,
            .hasErrors = false,
            .messages = LinkedList(ParseMessage).init(self.allocator)
        };

        var peekToken = self.tokenizer.peekToken();
        while (peekToken.type != TokenType.EOF) : (peekToken = self.tokenizer.peekToken()) {
            const parentBlock = ParentBlock {
                .isLoop = false,
                .isFunction = false
            };
            const statement = self.parseDeclaration(&ret, parentBlock);
            // TODO: Implement panic mode. We are stopping parsing at the first error encontered.
            if (statement) |stmt| {
                declarations.append(self.allocator, stmt) catch oom.handleOutOfMemoryError();
            } else {
                ret.hasErrors = true;
                ret.addErrorMessage("Invalid declaration, statement or expression", peekToken, self.sourceFile.filePath);
                break;
            }
        }

        ret.ast = declarations.items;
        return ret;
    }

    fn parseDeclaration(self: *Parser, parseResult: *ParseResult, parent: ParentBlock) ?*Node {
        var peekToken = self.tokenizer.peekToken();
        if (peekToken.type == TokenType.Var) {
            const varDecl = self.parseVarDeclaration(parseResult);
            return varDecl;
        } else if (peekToken.type == TokenType.Fun) {
            const funDecl = self.parseFunctionDeclaration(parseResult);
            return funDecl;
        } else {
            const statement = self.parseStatement(parseResult, parent);
            return statement;
        }
    }

    fn parseVarDeclaration(self: *Parser, parseResult: *ParseResult) ?*Node {
        var token = self.tokenizer.nextToken();
        std.debug.assert(token.type == TokenType.Var);

        const identifier = self.tokenizer.nextToken();
        const newNode = self.allocateNode(Node {
            .data = NodeData {
                .DeclVar = DeclVarNode {
                    .variableName = identifier,
                    .rValue = null
                }
            }
        });

        var peekToken = self.tokenizer.peekToken();
        if (peekToken.type == TokenType.Equal) {
            self.tokenizer.eatToken();
            const expr = self.parseExpression(parseResult);
            newNode.data.DeclVar.rValue = expr;
        }

        token = self.tokenizer.nextToken();
        if (token.type != TokenType.Semicolon) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Missing ';'", token, self.sourceFile.filePath);
            return null;
        }

        return newNode;
    }

    fn parseFunctionDeclaration(self: *Parser, parseResult: *ParseResult) ?*Node {
        self.tokenizer.eatToken();

        // Function name
        var nextToken = self.tokenizer.nextToken();
        const functionName = self.tokenizer.getLexeme(nextToken);
        if (nextToken.type != TokenType.Identifier) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected function name", nextToken, self.sourceFile.filePath);
            return null;
        }

        // Function parameters
        nextToken = self.tokenizer.nextToken();
        if (nextToken.type != TokenType.LeftParenthesis) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected '(' after function name", nextToken, self.sourceFile.filePath);
            return null;
        }

        var parameters = LinkedList(String).init(self.allocator);
        var peekToken = self.tokenizer.peekToken();
        if (peekToken.type != TokenType.RightParenthesis) {
            const param = self.tokenizer.nextToken();
            if (param.type != TokenType.Identifier) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("Expected a valid parameter name", param, self.sourceFile.filePath);
                return null;
            }

            const firstParamName = self.tokenizer.getLexeme(param);
            parameters.append(firstParamName);

            peekToken = self.tokenizer.peekToken();
            while (peekToken.type != TokenType.RightParenthesis) : (peekToken = self.tokenizer.peekToken()) {
                if (parameters.length >= 255) {
                    parseResult.hasErrors = true;
                    parseResult.addErrorMessage("Can't have more than 255 parameters in a function", peekToken, self.sourceFile.filePath);
                    return null;
                }

                const comma = self.tokenizer.nextToken();
                if (comma.type != TokenType.Comma) {
                    parseResult.hasErrors = true;
                    parseResult.addErrorMessage("Expected comma for parameter separation", comma, self.sourceFile.filePath);
                    return null;
                }

                const nextParam = self.tokenizer.nextToken();
                const nextParamName = self.tokenizer.getLexeme(nextParam);
                if (nextParam.type != TokenType.Identifier) {
                    parseResult.hasErrors = true;
                    parseResult.addErrorMessage("Missing parameter name after comma", comma, self.sourceFile.filePath);
                    return null;
                }

                // Check if parameter name is duplicated
                var paramIsDuplicated = false;
                var pa = parameters.first;
                while (pa) |p| : (pa = p.next) {
                    if (std.mem.eql(u8, p.data, nextParamName)) {
                        paramIsDuplicated = true;
                        break;
                    }
                }

                if (paramIsDuplicated) {
                    parseResult.hasErrors = true;
                    parseResult.addErrorMessage("Duplicated parameter name", nextParam, self.sourceFile.filePath);
                    return null;
                }

                parameters.append(nextParamName);
            }
        }

        nextToken = self.tokenizer.nextToken();
        if (nextToken.type != TokenType.RightParenthesis) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected ')' after function parameters", nextToken, self.sourceFile.filePath);
            return null;
        }

        // Function block
        const parentBlock = ParentBlock {
            .isFunction = true,
            .isLoop = false
        };
        const block = self.parseBlock(parseResult, parentBlock);
        if (block == null) return null;

        const newNode = self.allocateNode(Node {
            .data = NodeData {
                .DeclFunction = .{
                    .name = functionName,
                    .parameters = parameters,
                    .block = block.?
                }
            }
        });
        return newNode;
    }

    fn parseStatement(self: *Parser, parseResult: *ParseResult, parent: ParentBlock) ?*Node {
        var peekToken = self.tokenizer.peekToken();
        if (peekToken.type == TokenType.Print) {
            const printStmt = self.parsePrintStatement(parseResult);
            return printStmt;
        } else if (peekToken.type == TokenType.LeftBrace) {
            return self.parseBlock(parseResult, parent);
        } else if (peekToken.type == TokenType.If) {
            return self.parseIf(parseResult, parent);
        } else if (peekToken.type == TokenType.While) {
            return self.parseWhile(parseResult, parent);
        } else if (peekToken.type == TokenType.For) {
            return self.parseFor(parseResult, parent);
        } else if (peekToken.type == TokenType.Break) {
            self.tokenizer.eatToken();
            const nextToken = self.tokenizer.nextToken();
            if (nextToken.type != TokenType.Semicolon) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("Expected ';' after break statement", peekToken, self.sourceFile.filePath);
                return null;
            }

            if (! parent.isLoop) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("break must be inside a loop", peekToken, self.sourceFile.filePath);
                return null;
            }

            const newNode = self.allocateNode(Node {
                .data = NodeData.StmtBreak
            });
            return newNode;
        } else if (peekToken.type == TokenType.Continue) {
            self.tokenizer.eatToken();
            const nextToken = self.tokenizer.nextToken();
            if (nextToken.type != TokenType.Semicolon) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("Expected ';' after continue statement", peekToken, self.sourceFile.filePath);
                return null;
            }

            if (! parent.isLoop) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("continue must be inside a loop", peekToken, self.sourceFile.filePath);
                return null;
            }

            const newNode = self.allocateNode(Node {
                .data = NodeData.StmtContinue
            });
            return newNode;
        } else if (peekToken.type == TokenType.Return) {
            self.tokenizer.eatToken();

            var returnNode: ?*Node = null;

            // Optional return value
            peekToken = self.tokenizer.peekToken();
            if (peekToken.type != TokenType.Semicolon) {
                returnNode = self.parseExpression(parseResult);
                if (returnNode == null) return null;
            }

            const nextToken = self.tokenizer.nextToken();
            if (nextToken.type != TokenType.Semicolon) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("Expected ';' after return statement", peekToken, self.sourceFile.filePath);
                return null;
            }

            if (! parent.isFunction) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("return must be inside a function", peekToken, self.sourceFile.filePath);
                return null;
            }

            const newNode = self.allocateNode(Node {
                .data = NodeData {
                    .StmtReturn = returnNode
                }
            });
            return newNode;
        } else {
            const exprStmt = self.parseExpressionStatement(parseResult);
            return exprStmt;
        }
    }

    fn parseBlock(self: *Parser, parseResult: *ParseResult, parent: ParentBlock) ?*Node {
        self.tokenizer.eatToken();

        const newNode = self.allocateNode(Node {
            .data = NodeData {
                .StmtBlock = StmtBlockNode.init(self.allocator)
            }
        });

        var peekToken = self.tokenizer.peekToken();
        while (true) : (peekToken = self.tokenizer.peekToken()) {
            if (peekToken.type == TokenType.EOF) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("Unmatched close brace. Expected '}'", peekToken, self.sourceFile.filePath);
                return null;
            }

            if (peekToken.type == TokenType.RightBrace) {
                self.tokenizer.eatToken();
                break;
            }

            var stmtNode = self.parseDeclaration(parseResult, parent);
            if (stmtNode == null) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("Expected valid declaration, statement or expression", peekToken, self.sourceFile.filePath);
                return null;
            }

            newNode.data.StmtBlock.append(stmtNode.?) catch oom.handleOutOfMemoryError();
        }

        return newNode;
    }

    fn parseIf(self: *Parser, parseResult: *ParseResult, parent: ParentBlock) ?*Node {
        self.tokenizer.eatToken(); // Eat If token

        const leftParen = self.tokenizer.nextToken();
        if (leftParen.type != TokenType.LeftParenthesis) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected '(' after if statement", leftParen, self.sourceFile.filePath);
            return null;
        }

        const conditionNode = self.parseExpression(parseResult);
        if (conditionNode == null) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("If statement needs a valid expression to evaluate", leftParen, self.sourceFile.filePath);
            return null;
        }

        const rightParen = self.tokenizer.nextToken();
        if (rightParen.type != TokenType.RightParenthesis) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected ')' after if condition", rightParen, self.sourceFile.filePath);
            return null;
        }

        const ifBranch = self.parseStatement(parseResult, parent);
        if (ifBranch == null) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Empty if branch", rightParen, self.sourceFile.filePath);
            return null;
        }

        // Optional else branch
        var elseBranch: ?*Node = null;
        const peekToken = self.tokenizer.peekToken();
        if (peekToken.type == TokenType.Else) {
            self.tokenizer.eatToken();

            elseBranch = self.parseStatement(parseResult, parent);
            if (elseBranch == null) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("Empty else branch", peekToken, self.sourceFile.filePath);
                return null;
            }
        }

        const newNode = self.allocateNode(Node {
            .data = NodeData {
                .StmtIf = .{
                    .condition = conditionNode.?,
                    .ifBranch = ifBranch.?,
                    .elseBranch = elseBranch
                }
            }
        });
        return newNode;
    }

    fn parseWhile(self: *Parser, parseResult: *ParseResult, parentBlock: ParentBlock) ?*Node {
        self.tokenizer.eatToken();

        var nextToken = self.tokenizer.nextToken();
        if (nextToken.type != TokenType.LeftParenthesis) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected '(' after while keyword", nextToken, self.sourceFile.filePath);
            return null;
        }

        const condition = self.parseExpression(parseResult);
        if (condition == null) return null;

        nextToken = self.tokenizer.nextToken();
        if (nextToken.type != TokenType.RightParenthesis) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected ')' after while condition", nextToken, self.sourceFile.filePath);
            return null;
        }

        const body = self.parseStatement(parseResult, .{ .isLoop = true, .isFunction = parentBlock.isFunction });
        if (body == null) return null;

        const newNode = self.allocateNode(Node {
            .data = NodeData {
                .StmtFor = StmtForNode {
                    .initialization = null,
                    .condition = condition,
                    .increment = null,
                    .body = body.?
                }
            }
        });
        return newNode;
    }

    fn parseFor(self: *Parser, parseResult: *ParseResult, parentBlock: ParentBlock) ?*Node {
        // A for loop is constructed as a while loop in the AST
        self.tokenizer.eatToken();

        var nextToken = self.tokenizer.nextToken();
        if (nextToken.type != TokenType.LeftParenthesis) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected '(' after for keyword", nextToken, self.sourceFile.filePath);
            return null;
        }


        // Initializer
        var initialization: ?*Node = null;

        var peekToken = self.tokenizer.peekToken();
        if (peekToken.type == TokenType.Semicolon) {
            // No initializer
            self.tokenizer.eatToken();
        } else if (peekToken.type == TokenType.Var) {
            initialization = self.parseVarDeclaration(parseResult);
            if (initialization == null) return null;
        } else {
            initialization = self.parseExpressionStatement(parseResult);
            if (initialization == null) return null;
        }


        // Condition
        var condition: ?*Node = null;
        peekToken = self.tokenizer.peekToken();
        if (peekToken.type != TokenType.Semicolon) {
            condition = self.parseExpression(parseResult);
            if (condition == null) return null;
        }

        nextToken = self.tokenizer.nextToken();
        if (nextToken.type != TokenType.Semicolon) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected ';' after for condition", nextToken, self.sourceFile.filePath);
            return null;
        }


        // Increment
        var increment: ?*Node = null;
        peekToken = self.tokenizer.peekToken();
        if (peekToken.type != TokenType.RightParenthesis) {
            increment = self.parseExpression(parseResult);
            if (increment == null) return null;
        }

        nextToken = self.tokenizer.nextToken();
        if (nextToken.type != TokenType.RightParenthesis) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Expected ')' after for clauses", nextToken, self.sourceFile.filePath);
            return null;
        }


        // For body
        const body = self.parseStatement(parseResult, .{ .isLoop = true, .isFunction = parentBlock.isFunction });
        if (body == null) return null;

        const newNode = self.allocateNode(Node {
            .data = NodeData {
                .StmtBlock = StmtBlockNode.init(self.allocator)
            }
        });
        const forNode = self.allocateNode(Node {
            .data = NodeData {
                .StmtFor = .{
                    .initialization = initialization,
                    .condition = condition,
                    .increment = increment,
                    .body = body.?
                }
            }
        });
        newNode.data.StmtBlock.append(forNode) catch oom.handleOutOfMemoryError();
        return newNode;
    }

    fn parsePrintStatement(self: *Parser, parseResult: *ParseResult) ?*Node {
        var token = self.tokenizer.nextToken();
        std.debug.assert(token.type == TokenType.Print);

        const expr = self.parseExpression(parseResult);
        if (expr == null) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Invalid print statement. print must be followed by a single expression", token, self.sourceFile.filePath);
            return null;
        }

        token = self.tokenizer.nextToken();
        if (token.type != TokenType.Semicolon) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Missing ';'", token, self.sourceFile.filePath);
            return null;
        }

        const newNode = self.allocateNode(Node {
            .data = NodeData {
                .StmtPrint = expr.?
            }
        });
        return newNode;
    }

    fn parseExpressionStatement(self: *Parser, parseResult: *ParseResult) ?*Node {
        const expr = self.parseExpression(parseResult);
        if (expr == null) return null;

        var token = self.tokenizer.nextToken();
        if (token.type != TokenType.Semicolon) {
            parseResult.hasErrors = true;
            parseResult.addErrorMessage("Missing ';'", token, self.sourceFile.filePath);
            return null;
        }

        const newNode = self.allocateNode(Node {
            .data = NodeData {
                .StmtExpression = expr.?
            }
        });
        return newNode;
    }

    fn parseExpression(self: *Parser, parseResult: *ParseResult) ?*Node {
        var ret = self.parseAssignment(parseResult);
        return ret;
    }

    fn parseAssignment(self: *Parser, parseResult: *ParseResult) ?*Node {
        var lValue = self.parseLogicOr(parseResult);
        if (lValue == null) return null;

        var peekToken = self.tokenizer.peekToken();
        if (peekToken.type == TokenType.Equal) {
            self.tokenizer.eatToken();
            if (lValue.?.data != NodeType.ExprIdentifier) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("Cannot assign value. Left side must be a variable", peekToken, self.sourceFile.filePath);
                return null;
            }

            var rValue = self.parseAssignment(parseResult);
            if (rValue == null) return null;

            const newNode = self.allocateNode(Node {
                .data = NodeData {
                    .ExprAssignment = ExprAssignmentNode {
                        .lValue = lValue.?,
                        .rValue = rValue.?
                    }
                }
            });
            return newNode;
        }

        return lValue;
    }

    fn parseLogicOr(self: *Parser, parseResult: *ParseResult) ?*Node {
        var node = self.parseLogicAnd(parseResult);
        if (node == null) return null;

        var peekToken = self.tokenizer.peekToken();
        while (peekToken.type == TokenType.Or) : (peekToken = self.tokenizer.peekToken()) {
            self.tokenizer.eatToken();

            const right = self.parseLogicOr(parseResult);
            if (right == null) return null;

            var newNode = self.allocateNode(Node {
                .data = NodeData {
                    .ExprLogicOr = ExprLogicOrNode {
                        .left = node.?,
                        .right = right.?
                    }
                }
            });
            node = newNode;
        }

        return node;
    }

    fn parseLogicAnd(self: *Parser, parseResult: *ParseResult) ?*Node {
        var node = self.parseEquality(parseResult);
        if (node == null) return null;

        var peekToken = self.tokenizer.peekToken();
        while (peekToken.type == TokenType.And) : (peekToken = self.tokenizer.peekToken()) {
            self.tokenizer.eatToken();

            const right = self.parseLogicAnd(parseResult);
            if (right == null) return null;

            var newNode = self.allocateNode(Node {
                .data = NodeData {
                    .ExprLogicAnd = ExprLogicAndNode {
                        .left = node.?,
                        .right = right.?
                    }
                }
            });
            node = newNode;
        }

        return node;
    }

    fn parseEquality(self: *Parser, parseResult: *ParseResult) ?*Node {
        var node = self.parseComparison(parseResult);
        if (node == null) return null;

        var peek = self.tokenizer.peekToken();
        while (peek.type == TokenType.BangEqual or peek.type == TokenType.EqualEqual) : (peek = self.tokenizer.peekToken()) {
            const op = self.tokenizer.nextToken();
            var right = self.parseComparison(parseResult);
            if (right == null) return null;

            const newNode = self.allocateNode(Node {
                .data = NodeData {
                    .ExprBinary = ExprBinaryNode {
                        .left = node.?,
                        .operator = op,
                        .right = right.?
                    }
                }
            });
            node = newNode;
        }

        return node;
    }

    fn parseComparison(self: *Parser, parseResult: *ParseResult) ?*Node {
        var node = self.parseTerm(parseResult);
        if (node == null) return null;

        var peek = self.tokenizer.peekToken();
        while (peek.type == TokenType.Greater or
               peek.type == TokenType.GreaterEqual or
               peek.type == TokenType.Less or
               peek.type == TokenType.LessEqual) : (peek = self.tokenizer.peekToken()) {
            const op = self.tokenizer.nextToken();
            var right = self.parseTerm(parseResult);
            if (right == null) return null;

            const newNode = self.allocateNode(Node {
                .data = NodeData {
                    .ExprBinary = ExprBinaryNode {
                        .left = node.?,
                        .operator = op,
                        .right = right.?
                    }
                }
            });
            node = newNode;
        }

        return node;
    }

    fn parseTerm(self: *Parser, parseResult: *ParseResult) ?*Node {
        var node = self.parseFactor(parseResult);
        if (node == null) return null;

        var peek = self.tokenizer.peekToken();
        while (peek.type == TokenType.Minus or peek.type == TokenType.Plus) : (peek = self.tokenizer.peekToken()) {
            const op = self.tokenizer.nextToken();
            var right = self.parseFactor(parseResult);
            if (right == null) return null;

            const newNode = self.allocateNode(Node {
                .data = NodeData {
                    .ExprBinary = ExprBinaryNode {
                        .left = node.?,
                        .operator = op,
                        .right = right.?
                    }
                }
            });
            node = newNode;
        }

        return node;
    }

    fn parseFactor(self: *Parser, parseResult: *ParseResult) ?*Node {
        var node = self.parseUnary(parseResult);
        if (node == null) return null;

        var peek = self.tokenizer.peekToken();
        while (peek.type == TokenType.Slash or peek.type == TokenType.Star) : (peek = self.tokenizer.peekToken()) {
            const op = self.tokenizer.nextToken();
            var right = self.parseUnary(parseResult);
            if (right == null) return null;

            const newNode = self.allocateNode(Node {
                .data = NodeData {
                    .ExprBinary = ExprBinaryNode {
                        .left = node.?,
                        .operator = op,
                        .right = right.?
                    }
                }
            });
            node = newNode;
        }

        return node;
    }

    fn parseUnary(self: *Parser, parseResult: *ParseResult) ?*Node {
        var peek = self.tokenizer.peekToken();
        if (peek.type == TokenType.Bang or peek.type == TokenType.Minus) {
            const op = self.tokenizer.nextToken();
            var right = self.parseUnary(parseResult);
            if (right == null) return null;

            const newNode = self.allocateNode(Node {
                .data = NodeData {
                    .ExprUnary = ExprUnaryNode {
                        .operator = op,
                        .right = right.?
                    }
                }
            });
            return newNode;
        } else {
            var ret = self.parseCallable(parseResult);
            return ret;
        }
    }

    fn parseCallable(self: *Parser, parseResult: *ParseResult) ?*Node {
        const firstToken = self.tokenizer.peekToken();

        const primary = self.parsePrimary(parseResult);
        if (primary == null) return null;

        var peekToken = self.tokenizer.peekToken();
        if (peekToken.type == TokenType.LeftParenthesis) {
            self.tokenizer.eatToken();

            // Parse arguments
            var numArguments: usize = 0;
            _ = numArguments;
            var arguments = LinkedList(*Node).init(self.allocator);

            peekToken = self.tokenizer.peekToken();
            if (peekToken.type != TokenType.RightParenthesis) {
                const firstArgumentExpr = self.parseExpression(parseResult);
                if (firstArgumentExpr == null) return null;
                arguments.append(firstArgumentExpr.?);

                peekToken = self.tokenizer.peekToken();
                while (peekToken.type != TokenType.RightParenthesis) : (peekToken = self.tokenizer.peekToken()) {
                    if (arguments.length >= 255) {
                        parseResult.hasErrors = true;
                        parseResult.addErrorMessage("Can't pass more than 255 arguments in this call", peekToken, self.sourceFile.filePath);
                        return null;
                    }

                    const comma = self.tokenizer.nextToken();
                    if (comma.type != TokenType.Comma) {
                        parseResult.hasErrors = true;
                        parseResult.addErrorMessage("Expected comma for argument separation", comma, self.sourceFile.filePath);
                        return null;
                    }

                    const nextParamExpr = self.parseExpression(parseResult);
                    if (nextParamExpr == null) return null;

                    arguments.append(nextParamExpr.?);
                }
            }

            const nextToken = self.tokenizer.nextToken();
            if (nextToken.type != TokenType.RightParenthesis) {
                parseResult.hasErrors = true;
                parseResult.addErrorMessage("Expected ')' after function arguments", nextToken, self.sourceFile.filePath);
                return null;
            }

            const newNode = self.allocateNode(Node {
                .data = NodeData {
                    .ExprCallable = .{
                        .location = firstToken,
                        .callee = primary.?,
                        .arguments = arguments
                    }
                }
            });
            return newNode;
        } else {
            return primary;
        }
    }

    fn parsePrimary(self: *Parser, parseResult: *ParseResult) ?*Node {
        var peek = self.tokenizer.peekToken();
        switch (peek.type) {
            TokenType.Number => {
                const numToken = self.tokenizer.nextToken();
                const lexeme = self.tokenizer.getLexeme(numToken);
                const num = std.fmt.parseFloat(f32, lexeme) catch {
                    parseResult.hasErrors = true;
                    parseResult.addErrorMessage("Invalid number", peek, self.sourceFile.filePath);
                    return null;
                };

                const newNode = self.allocateNode(Node {
                    .data = NodeData {
                        .ExprLiteral = LujoValue { .number = num }
                    }
                });
                return newNode;
            },
            TokenType.String => {
                const op = self.tokenizer.nextToken();
                const lexeme = self.tokenizer.getLexeme(op);

                // Remove surrounding double quotes to the string literal
                const str = lexeme[1..(lexeme.len - 1)];

                const newNode = self.allocateNode(Node {
                    .data = NodeData {
                        .ExprLiteral = LujoValue { .string = str }
                    }
                });
                return newNode;
            },
            TokenType.True => {
                self.tokenizer.eatToken();
                const newNode = self.allocateNode(Node {
                    .data = NodeData {
                        .ExprLiteral = LujoValue { .boolean = true }
                    }
                });
                return newNode;
            },
            TokenType.False => {
                self.tokenizer.eatToken();
                const newNode = self.allocateNode(Node {
                    .data = NodeData {
                        .ExprLiteral = LujoValue { .boolean = false }
                    }
                });
                return newNode;
            },
            TokenType.Nil => {
                self.tokenizer.eatToken();
                const newNode = self.allocateNode(Node {
                    .data = NodeData {
                        .ExprLiteral = LujoValue.nil
                    }
                });
                return newNode;
            },
            TokenType.LeftParenthesis => {
                self.tokenizer.eatToken();
                var node = self.parseExpression(parseResult);
                if (node == null) return null;

                const newNode = self.allocateNode(Node {
                    .data = NodeData {
                        .ExprGrouping = node.?
                    }
                });
                const next = self.tokenizer.nextToken();
                if (next.type != TokenType.RightParenthesis) {
                    parseResult.hasErrors = true;
                    parseResult.addErrorMessage("Unmatched close parenthesis. Expected ')'", peek, self.sourceFile.filePath);
                    return null;
                }

                return newNode;
            },
            TokenType.Identifier => {
                const identifier = self.tokenizer.nextToken();
                const newNode = self.allocateNode(Node {
                    .data = NodeData {
                        .ExprIdentifier = identifier
                    }
                });
                return newNode;
            },
            TokenType.Error => {
                parseResult.hasErrors = true;

                switch (peek.errorKind) {
                    .None => parseResult.addErrorMessage("Invalid syntax", peek, self.sourceFile.filePath),
                    .InvalidSingleLineString => parseResult.addErrorMessage("Multi-line strings are not supported. The string must be declared in one line.", peek, self.sourceFile.filePath),
                    .InvalidToken => parseResult.addErrorMessage("Invalid syntax", peek, self.sourceFile.filePath),
                    .NumberMissingDecimal => parseResult.addErrorMessage("Invalid number. Missing decimal part.", peek, self.sourceFile.filePath),
                }

                return null;
            },
            else => {
                // We let the caller function handle this error condition and add the appropriate error message
                parseResult.hasErrors = true;
                return null;
            }
        }
    }

    fn allocateNode(self: *Parser, node: Node) *Node {
        var newNode = self.allocator.create(Node) catch oom.handleOutOfMemoryError();
        newNode.* = node;
        return newNode;
    }
};

