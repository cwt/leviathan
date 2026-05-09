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

const lock = @import("../utils/lock.zig");

const LoopLinkedList = utils.LinkedList(*Loop);
var all_loops: LoopLinkedList = undefined;
var loops_mutex: lock.Mutex = undefined;
var atfork_installed: bool = false;

fn atfork_child() callconv(.c) void {
    var node = all_loops.first;
    while (node) |n| {
        n.data.forked = true;
        node = n.next;
    }
}

fn install_atfork() !void {
    if (atfork_installed) return;
    if (python_c._c.pthread_atfork(null, null, &atfork_child) != 0) {
        return error.SystemResources;
    }
    atfork_installed = true;
}

pub fn init_module(allocator: std.mem.Allocator) void {
    all_loops = LoopLinkedList.init(allocator);
    loops_mutex = lock.init();
}

allocator: std.mem.Allocator,

ready_tasks_queue_index: u8 = 0,

ready_tasks_queues: [2]CallbackManager.CallbacksSetsQueue,
reserved_slots: usize = 0,

io: Scheduling.IO,
dns: DNS,

reader_watchers: WatchersBTree,
writer_watchers: WatchersBTree,

ready_tasks_queue_max_capacity: usize,

mutex: lock.Mutex,

unix_signals: UnixSignals,

running: bool = false,
stopping: bool = false,
initialized: bool = false,
forked: bool = false,

node: ?LoopLinkedList.Node = null,


pub fn init(self: *Loop, allocator: std.mem.Allocator, rtq_max_capacity: usize) !void {
    if (self.initialized) {
        @panic("Loop is already initialized");
    }

    try install_atfork();

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

    loops_mutex.lock();
    defer loops_mutex.unlock();
    self.node = try all_loops.create_new_node(self);
    all_loops.append_node(self.node.?);
}

pub fn release(self: *Loop) void {
    if (self.running) {
        @panic("Loop is running, can't be deallocated");
    }

    loops_mutex.lock();
    if (self.node) |node| {
        all_loops.unlink_node(node);
        all_loops.release_node(node);
        self.node = null;
    }
    loops_mutex.unlock();

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

    self.dns.deinit();
    self.initialized = false;
}

pub inline fn reserve_slots(self: *Loop, amount: usize) !void {
    const new_value = self.reserved_slots + amount;
    try self.ready_tasks_queues[self.ready_tasks_queue_index].ensure_capacity(new_value);
    self.reserved_slots = new_value;
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

const Loop = @This();
