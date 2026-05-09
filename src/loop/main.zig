const std = @import("std");

const python_c = @import("python_c");
const CallbackManager = @import("callback_manager");

const Handle = @import("../handle.zig");


pub const FDWatcher = struct {
    handle: *Handle.PythonHandleObject,
    loop_data: *Loop,
    blocking_task_id: usize = 0,
    event_type: u32,
    fd: std.posix.fd_t
};

const utils = @import("utils");
const WatchersBTree = utils.BTree(std.posix.fd_t, *FDWatcher, 11);
pub const HooksList = utils.LinkedList(CallbackManager.Callback);

const lock = @import("../utils/lock.zig");

pub fn init_module(_: std.mem.Allocator) void {}

allocator: std.mem.Allocator,

ready_tasks_queue_index: u8 = 0,

ready_tasks_queues: [2]CallbackManager.CallbacksSetsQueue,
reserved_slots: usize = 0,

io: Scheduling.IO,
dns: DNS,

reader_watchers: WatchersBTree,
writer_watchers: WatchersBTree,

prepare_hooks: HooksList,
check_hooks: HooksList,
idle_hooks: HooksList,

ready_tasks_queue_max_capacity: usize,

mutex: lock.Mutex,

unix_signals: UnixSignals,

running: bool = false,
stopping: bool = false,
initialized: bool = false,


pub fn init(self: *Loop, allocator: std.mem.Allocator, rtq_max_capacity: usize) !void {
    if (self.initialized) {
        @panic("Loop is already initialized");
    }

    var reader_watchers = try WatchersBTree.init(allocator);
    errdefer reader_watchers.deinit() catch |err| {
        std.debug.panic("Unexpected error while releasing reader watchers: {s}", .{@errorName(err)});
    };

    var writer_watchers = try WatchersBTree.init(allocator);
    errdefer writer_watchers.deinit() catch |err| {
        std.debug.panic("Unexpected error while releasing writer watchers: {s}", .{@errorName(err)});
    };

    self.* = .{
        .allocator = allocator,
        .mutex = lock.init(),
        .ready_tasks_queues = .{
            CallbackManager.CallbacksSetsQueue.init(allocator),
            CallbackManager.CallbacksSetsQueue.init(allocator)
        },
        .ready_tasks_queue_max_capacity = rtq_max_capacity / @sizeOf(CallbackManager.Callback),
        .reader_watchers = reader_watchers,
        .writer_watchers = writer_watchers,
        .prepare_hooks = HooksList.init(allocator),
        .check_hooks = HooksList.init(allocator),
        .idle_hooks = HooksList.init(allocator),
        .unix_signals = undefined,
        .io = undefined,
        .dns = undefined,
    };

    try self.io.init(self, allocator);
    errdefer self.io.deinit();

    try self.io.register_eventfd_callback();

    try UnixSignals.init(self);
    errdefer self.unix_signals.deinit();

    try self.dns.init(self);
    errdefer self.dns.deinit();

    self.initialized = true;
}

pub fn release(self: *Loop) void {
    if (self.running) {
        @panic("Loop is running, can't be deallocated");
    }

    self.io.deinit();
    self.unix_signals.deinit();

    const allocator = self.allocator;
    for (&self.ready_tasks_queues) |*ready_tasks_queue| {
        CallbackManager.release_sets_queue(allocator, ready_tasks_queue);
    }

    // Cancel any remaining watcher I/O before deinit
    {
        var sig: std.posix.fd_t = undefined;
        while (self.reader_watchers.pop(&sig)) |_| {}
        while (self.writer_watchers.pop(&sig)) |_| {}
    }

    self.reader_watchers.deinit() catch |err| {
        std.debug.panic("Unexpected error while releasing reader watchers: {s}", .{@errorName(err)});
    };
    self.writer_watchers.deinit() catch |err| {
        std.debug.panic("Unexpected error while releasing writer watchers: {s}", .{@errorName(err)});
    };

    self.prepare_hooks.clear();
    self.check_hooks.clear();
    self.idle_hooks.clear();

    self.dns.deinit();
    self.initialized = false;
}

pub inline fn reserve_slots(self: *Loop, amount: usize) !void {
    const new_value = self.reserved_slots + amount;
    try self.ready_tasks_queues[self.ready_tasks_queue_index].ensure_capacity(new_value);
    self.reserved_slots = new_value;
}

pub const HookType = enum {
    prepare,
    check,
    idle
};

pub fn add_hook(self: *Loop, hook_type: HookType, callback: CallbackManager.Callback) !HooksList.Node {
    const hooks = switch (hook_type) {
        .prepare => &self.prepare_hooks,
        .check => &self.check_hooks,
        .idle => &self.idle_hooks,
    };
    const node = try hooks.create_new_node(callback);
    hooks.append_node(node);
    return node;
}

pub fn remove_hook(self: *Loop, hook_type: HookType, node: HooksList.Node) void {
    const hooks = switch (hook_type) {
        .prepare => &self.prepare_hooks,
        .check => &self.check_hooks,
        .idle => &self.idle_hooks,
    };
    hooks.unlink_node(node);
    hooks.release_node(node);
}

pub const Runner = @import("runner.zig");
pub const Scheduling = @import("scheduling/main.zig");
pub const UnixSignals = @import("unix_signals.zig");
pub const Python = @import("python/main.zig");
pub const DNS = @import("dns/main.zig");

test {
    _ = Runner;
    _ = Scheduling;
    _ = UnixSignals;
    _ = Python;
    _ = DNS;
}

test "loop hooks" {
    const allocator = std.testing.allocator;
    var loop: Loop = undefined;
    try loop.init(allocator, 1024);
    defer loop.release();

    const Mock = struct {
        called_count: usize = 0,
        fn callback(data: *const CallbackManager.CallbackData) !void {
            const self: *@This() = @alignCast(@ptrCast(data.user_data.?));
            self.called_count += 1;
        }
    };

    var prepare_mock = Mock{};
    var check_mock = Mock{};

    const p_node = try loop.add_hook(.prepare, .{
        .func = &Mock.callback,
        .cleanup = null,
        .data = .{ .user_data = &prepare_mock, .exception_context = null },
    });

    const c_node = try loop.add_hook(.check, .{
        .func = &Mock.callback,
        .cleanup = null,
        .data = .{ .user_data = &check_mock, .exception_context = null },
    });

    // Manually execute hooks since we are not running the full loop
    var node = loop.prepare_hooks.first;
    while (node) |n| {
        try n.data.func(&.{
            .user_data = n.data.data.user_data,
            .exception_context = n.data.data.exception_context,
            .io_uring_res = 0,
            .io_uring_err = .SUCCESS,
            .cancelled = false,
        });
        node = n.next;
    }

    try std.testing.expectEqual(@as(usize, 1), prepare_mock.called_count);
    try std.testing.expectEqual(@as(usize, 0), check_mock.called_count);

    loop.remove_hook(.prepare, p_node);
    loop.remove_hook(.check, c_node);

    try std.testing.expectEqual(@as(usize, 0), loop.prepare_hooks.len);
    try std.testing.expectEqual(@as(usize, 0), loop.check_hooks.len);
}

const Loop = @This();
