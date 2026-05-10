const std = @import("std");
const builtin = @import("builtin");

const Loop = @import("../main.zig");
const utils = @import("utils");
const python_c = @import("python_c");

const Cache = @import("cache.zig");
const Parsers = @import("parsers.zig");
const Resolv = @import("resolv.zig");
const CallbackManager = @import("callback_manager");

const DNSCacheEntries = switch (builtin.mode) {
    .Debug => 4,
    else => 65536,
};

const CACHE_MASK = DNSCacheEntries - 1;

pub const PendingList = utils.LinkedList(*Resolv.ControlData);

loop: *Loop,
arena: std.heap.ArenaAllocator,
allocator: std.mem.Allocator,

configuration: Parsers.Configuration,

cache_entries: [DNSCacheEntries]Cache,
parsed_hostname_buf: [255]u8,

ipv6_supported: bool,

pending_queries: PendingList,

pub fn init(self: *DNS, loop: *Loop) !void {
    self.loop = loop;
    self.arena = std.heap.ArenaAllocator.init(loop.allocator);
    self.allocator = self.arena.allocator();

    for (&self.cache_entries) |*entry| {
        entry.init(self.allocator);
    }

    try self.load_configuration(self.allocator);

    // TODO: Figure out if there is a better way
    const ret = std.posix.socket(std.posix.AF.INET6, std.posix.SOCK.STREAM, 0);
    if (ret) |sock| {
        self.ipv6_supported = true;
        std.posix.close(sock);
    } else |_| {
        self.ipv6_supported = false;
    }

    self.pending_queries = PendingList.init(loop.allocator);
}

fn load_configuration(self: *DNS, allocator: std.mem.Allocator) !void {
    const file = try std.fs.openFileAbsolute("/etc/resolv.conf", .{
        .mode = .read_only,
    });
    defer file.close();

    const stat_data = try file.stat();
    const size = stat_data.size;

    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);

    _ = try file.readAll(content);

    self.configuration = try Parsers.parse_resolv_configuration(allocator, content);
}

pub fn get_cache_slot(self: *DNS, hostname: []const u8) *Cache {
    var h = std.hash.XxHash3.init(0);
    h.update(hostname);
    const index = h.final();

    return &self.cache_entries[index & CACHE_MASK];
}

pub fn lookup(
    self: *DNS,
    hostname: []const u8,
    callback: ?*const CallbackManager.Callback,
) !?[]const std.net.Address {
    const parsed_hostname = std.ascii.lowerString(&self.parsed_hostname_buf, hostname);

    const cache_slot = self.get_cache_slot(parsed_hostname);
    const record = cache_slot.get(parsed_hostname) orelse {
        if (callback == null) return null;

        const ipv6_supported: bool = self.ipv6_supported;

        const address_resolved = try Parsers.resolve_address(parsed_hostname, ipv6_supported);
        if (address_resolved) |v| {
            return v;
        }

        // Use native asynchronous resolver
        try Resolv.queue(cache_slot, self.loop, parsed_hostname, callback.?, self.configuration, ipv6_supported, null);
        return null;
    };

    const address_list = record.get_address_list() orelse {
        if (callback == null) return null;

        try self.loop.reserve_slots(1);
        errdefer self.loop.reserved_slots -= 1;

        try record.append_callback(callback.?);
        return null;
    };

    return address_list;
}

pub fn reverse_lookup(
    self: *DNS,
    address: std.net.Address,
    callback: *const CallbackManager.Callback,
) !void {
    var buf: [128]u8 = undefined;
    const name = try Parsers.build_reverse_name(address, &buf);

    const cache_slot = self.get_cache_slot(name);
    if (cache_slot.get(name)) |record| {
        if (record.state == .ptr) {
            // Already resolved
            try self.loop.reserve_slots(1);
            errdefer self.loop.reserved_slots -= 1;
            try Loop.Scheduling.Soon.dispatch(self.loop, callback);
            return;
        }
    }

    try Resolv.queue(cache_slot, self.loop, name, callback, self.configuration, false, .ptr);
}

fn resolve_via_python_getaddrinfo(hostname: []const u8) ![]std.net.Address {
    // Build Python hostname string
    const py_host = python_c.PyUnicode_FromStringAndSize(hostname.ptr, @intCast(hostname.len))
        orelse return error.PythonError;
    defer python_c.py_decref(py_host);

    // Call socket.getaddrinfo(hostname, 0)
    const socket_module = python_c.PyImport_ImportModule("socket\x00") orelse
        return error.PythonError;
    defer python_c.py_decref(socket_module);

    const getaddrinfo_func = python_c.PyObject_GetAttrString(socket_module, "getaddrinfo\x00")
        orelse return error.PythonError;
    defer python_c.py_decref(getaddrinfo_func);

    const py_port = python_c.PyLong_FromLong(0) orelse return error.PythonError;
    defer python_c.py_decref(py_port);

    const args = python_c.PyTuple_Pack(2, py_host, py_port) orelse return error.PythonError;
    defer python_c.py_decref(args);

    const result = python_c.PyObject_CallObject(getaddrinfo_func, args) orelse
        return error.PythonError;
    defer python_c.py_decref(result);

    if (python_c.PyList_Check(result) <= 0) return error.PythonError;

    const list_len = python_c.PyList_Size(result);
    if (list_len == 0) return error.PythonError;

    const gpa = std.heap.c_allocator;
    var addresses = std.ArrayList(std.net.Address){};
    errdefer addresses.deinit(gpa);

    var i: isize = 0;
    while (i < list_len) : (i += 1) {
        const item = python_c.PyList_GetItem(result, i) orelse continue;
        if (python_c.PyTuple_Check(item) <= 0) continue;
        if (python_c.PyTuple_Size(item) < 5) continue;

        const family_obj = python_c.PyTuple_GetItem(item, 0) orelse continue;
        const sockaddr_obj = python_c.PyTuple_GetItem(item, 4) orelse continue;

        const family = python_c.PyLong_AsLong(family_obj);
        if (family == -1 and python_c.PyErr_Occurred() != null) {
            python_c.PyErr_Clear();
            continue;
        }

        if (family == std.posix.AF.INET) {
            if (python_c.PyTuple_Size(sockaddr_obj) < 2) continue;
            const host_obj = python_c.PyTuple_GetItem(sockaddr_obj, 0) orelse continue;
            const host_bytes = python_c.PyUnicode_AsUTF8(host_obj) orelse continue;
            const host_str = std.mem.span(host_bytes);
            if (std.net.Address.parseIp(host_str, 0)) |addr| {
                try addresses.append(gpa, addr);
            } else |_| {}
        } else if (family == std.posix.AF.INET6) {
            if (python_c.PyTuple_Size(sockaddr_obj) < 4) continue;
            const host_obj = python_c.PyTuple_GetItem(sockaddr_obj, 0) orelse continue;
            const host_bytes = python_c.PyUnicode_AsUTF8(host_obj) orelse continue;
            const host_str = std.mem.span(host_bytes);
            if (std.net.Address.parseIp6(host_str, 0)) |addr| {
                try addresses.append(gpa, addr);
            } else |_| {}
        }
    }

    if (addresses.items.len == 0) return error.PythonError;

    return addresses.toOwnedSlice(gpa) catch {
        addresses.deinit(gpa);
        return error.OutOfMemory;
    };
}

pub fn deinit(self: *DNS) void {
    self.arena.deinit();
}

pub fn traverse(self: *const DNS, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    var node = self.pending_queries.first;
    while (node) |n| {
        const vret = n.data.traverse(visit, arg);
        if (vret != 0) return vret;
        node = n.next;
    }
    return 0;
}

const DNS = @This();

test "get_cache_slot returns consistent slot for same hostname" {
    var dns = DNS{
        .loop = undefined,
        .arena = undefined,
        .allocator = std.testing.allocator,
        .configuration = undefined,
        .cache_entries = undefined,
        .parsed_hostname_buf = undefined,
        .ipv6_supported = false,
        .pending_queries = PendingList.init(std.testing.allocator),
    };

    const hostname1 = "example.com";
    const hostname2 = "example.com";

    const slot1 = dns.get_cache_slot(hostname1);
    const slot2 = dns.get_cache_slot(hostname2);

    try std.testing.expectEqual(slot1, slot2);
}

test "get_cache_slot distributes hostnames across slots" {
    var dns = DNS{
        .loop = undefined,
        .arena = undefined,
        .allocator = std.testing.allocator,
        .configuration = undefined,
        .cache_entries = undefined,
        .parsed_hostname_buf = undefined,
        .ipv6_supported = false,
        .pending_queries = PendingList.init(std.testing.allocator),
    };

    const hostnames = [_][]const u8{
        "example1.com",
        "example2.com",
        "example3.com",
        "example4.com",
        "example5.com",
    };

    var slots = [_]*Cache{undefined} ** hostnames.len;

    for (hostnames, 0..) |hostname, i| {
        slots[i] = dns.get_cache_slot(hostname);
    }

    // Check that not all slots are the same
    var unique_slots = std.ArrayList(*Cache){};
    defer unique_slots.deinit(std.testing.allocator);

    loop: for (slots) |slot| {
        for (unique_slots.items) |existing_slot| {
            if (slot == existing_slot) {
                continue :loop;
            }
        }
        try unique_slots.append(std.testing.allocator, slot);
    }

    try std.testing.expect(unique_slots.items.len > 1);
}

test "get_cache_slot handles different hostname lengths" {
    var dns = DNS{
        .loop = undefined,
        .arena = undefined,
        .allocator = std.testing.allocator,
        .configuration = undefined,
        .cache_entries = undefined,
        .parsed_hostname_buf = undefined,
        .ipv6_supported = false,
        .pending_queries = PendingList.init(std.testing.allocator),
    };

    const hostnames = [_][]const u8{
        "a",
        "ab",
        "abc",
        "abcd",
        "abcde",
        "a" ** 63,
        "a" ** 255,
    };

    var slots = [_]*Cache{undefined} ** hostnames.len;

    for (hostnames, 0..) |hostname, i| {
        slots[i] = dns.get_cache_slot(hostname);
    }

    // Check that different length hostnames can map to different slots
    var unique_slots = std.ArrayList(*Cache){};
    defer unique_slots.deinit(std.testing.allocator);

    loop: for (slots) |slot| {
        for (unique_slots.items) |existing_slot| {
            if (slot == existing_slot) {
                continue :loop;
            }
        }
        try unique_slots.append(std.testing.allocator, slot);
    }

    try std.testing.expect(unique_slots.items.len > 1);
}

test {
    std.testing.refAllDecls(Parsers);
    std.testing.refAllDecls(Cache);
    std.testing.refAllDecls(Resolv);
}
