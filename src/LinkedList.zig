const std = @import("std");
const oom = @import("oom.zig");

// Singly linked list which is a simplified version of a linked list that inserts in order and in constant time. The
// interface is similar to std.SinglyLinkedList but in a simplified and cleaner way. Out of memory errors are just ignored.
pub fn LinkedList(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        length: usize,
        first: ?*Node,
        last: ?*Node,

        const Self = @This();

        pub const Node = struct {
            data: T,
            next: ?*Node
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            var ret = Self {
                .allocator = allocator,
                .length = 0,
                .first = null,
                .last = null
            };
            return ret;
        }

        pub fn append(self: *Self, value: T) void {
            var node = Node {
                .data = value,
                .next = null
            };
            var newNode = self.allocator.create(Node) catch oom.handleOutOfMemoryError();
            newNode.* = node;

            if (self.last) |*last| {
                last.*.next = newNode;
                last.* = newNode;
            } else {
                // First node
                self.first = newNode;
                self.last = newNode;
            }

            self.length += 1;
        }
    };
}
