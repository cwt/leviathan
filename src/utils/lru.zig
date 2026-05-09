const std = @import("std");

pub fn LRUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        
        pub const Node = struct {
            key: K,
            value: V,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        allocator: std.mem.Allocator,
        capacity: usize,
        map: std.AutoHashMap(K, *Node),
        head: ?*Node = null,
        tail: ?*Node = null,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
            return .{
                .allocator = allocator,
                .capacity = capacity,
                .map = std.AutoHashMap(K, *Node).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.map.deinit();
        }

        pub fn get(self: *Self, key: K) ?V {
            if (self.map.get(key)) |node| {
                self.move_to_front(node);
                return node.value;
            }
            return null;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.map.get(key)) |node| {
                node.value = value;
                self.move_to_front(node);
                return;
            }

            if (self.map.count() >= self.capacity) {
                self.evict_last();
            }

            const node = try self.allocator.create(Node);
            node.* = .{
                .key = key,
                .value = value,
            };
            
            try self.map.put(key, node);
            self.prepend(node);
        }

        fn move_to_front(self: *Self, node: *Node) void {
            if (node == self.head) return;
            
            self.remove_node(node);
            self.prepend(node);
        }

        fn prepend(self: *Self, node: *Node) void {
            node.next = self.head;
            node.prev = null;
            if (self.head) |h| {
                h.prev = node;
            }
            self.head = node;
            if (self.tail == null) {
                self.tail = node;
            }
        }

        fn remove_node(self: *Self, node: *Node) void {
            if (node.prev) |p| {
                p.next = node.next;
            } else {
                self.head = node.next;
            }
            if (node.next) |n| {
                n.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
        }

        fn evict_last(self: *Self) void {
            if (self.tail) |node| {
                _ = self.map.remove(node.key);
                self.remove_node(node);
                self.allocator.destroy(node);
            }
        }
    };
}

test "LRUCache basic" {
    const allocator = std.testing.allocator;
    var cache = LRUCache(u32, u32).init(allocator, 2);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);
    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));
    
    try cache.put(3, 300); // Should evict 2 (1 was used recently)
    try std.testing.expectEqual(@as(?u32, null), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 300), cache.get(3));
}
