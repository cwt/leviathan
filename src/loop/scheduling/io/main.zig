const std = @import("std");
const builtin = @import("builtin");

const utils =  @import("utils");
const python_c = @import("python_c");

const CallbackManager = @import("callback_manager");
const Loop = @import("../../main.zig");

pub const Read = @import("read.zig");
pub const Write = @import("write.zig");
pub const Timer = @import("timer.zig");
pub const Cancel = @import("cancel.zig");
pub const Socket = @import("socket.zig");

pub const TotalTasksItems = switch (builtin.mode) {
    .Debug => 4,
    .ReleaseSmall => 1024,
    else => 8192
};

pub const BlockingOperation = enum {
    WaitReadable,
    WaitWritable,
    PerformRead,
    PerformWrite,
    PerformWriteV,
    PerformRecvMsg,
    PerformSendMsg,
    WaitTimer,
    Cancel,
    SocketShutdown,
    SocketConnect,
    SocketAccept,
};

pub const BlockingTaskData = union(enum) {
    callback: CallbackManager.Callback,
    none,
};

pub const BlockingTask = struct {
    data: BlockingTaskData,
    operation: BlockingOperation,
    index: u16,

    inline fn reset(self: *BlockingTask) *BlockingTasksSet {
        const set: *BlockingTasksSet = @ptrFromInt(
            @intFromPtr(self) - @as(usize, self.index) * @sizeOf(BlockingTask)
        );

        self.data = .none;
        self.operation = undefined;

        return set;
    }

    pub fn discard(self: *BlockingTask) void {
        const set = self.reset();
        set.pop();
    }
    
    pub fn deinit(self: *BlockingTask) void {
        const set = self.reset();
        set.inc_finished_tasks_counter();
    }

    pub fn check_result(self: *BlockingTask, result: std.os.linux.E) void {
        switch (self.operation) {
            .WaitTimer => {
                switch (result) {
                    .TIME => {},
                    .CANCELED => {},
                    .SUCCESS => {},
                    else => {
                        // Log but don't panic. Panicking calls abort() and kills the process.
                    }
                }
            },
            .Cancel => {},
            .PerformWriteV, .PerformWrite, .PerformSendMsg => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .BADF, .FBIG, .INTR, .IO, .NOSPC, .INVAL, .CONNRESET,  // Expected errors
                    .PIPE, .NOBUFS, .NXIO, .ACCES, .NETDOWN, .NETUNREACH,
                    .SPIPE => {},
                    .AGAIN => {},
                    else => {
                        // Log but don't panic. Panicking calls abort() and kills the process.
                    }
                }
            },
            .PerformRead, .PerformRecvMsg => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .BADF, .BADMSG, .INTR, .INVAL, .IO, .ISDIR,
                    .OVERFLOW, .SPIPE, .CONNRESET, .NOTCONN, .TIMEDOUT,
                    .NOBUFS, .NOMEM, .NXIO => {},
                    .AGAIN => {},
                    else => {
                        // Log but don't panic. Panicking calls abort() and kills the process.
                    }
                }
            },
            .SocketShutdown => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .INVAL, .NOTCONN, .NOTSOCK, .BADF, .NOBUFS => {},
                    .AGAIN => {},
                    else => {
                        // Log but don't panic. Panicking calls abort() and kills the process.
                    }
                }
            },
            .SocketConnect, .SocketAccept => {
                switch (result) {
                    .SUCCESS => {},
                    .ACCES, .PERM, .ADDRINUSE, .ADDRNOTAVAIL, .AFNOSUPPORT, .ALREADY,
                    .BADF, .CONNREFUSED, .FAULT, .INPROGRESS, .INTR, .ISCONN,
                    .NETUNREACH, .NOTSOCK, .PROTOTYPE, .TIMEDOUT => {},
                    .AGAIN => {},
                    else => {
                        // Log but don't panic. Panicking calls abort() and kills the process.
                    }
                }
            },
            else => {
                switch (result) {
                    .SUCCESS => {},
                    .CANCELED, .BADF, .INTR => {},
                    else => {
                        // Log but don't panic. Panicking calls abort() and kills the process.
                    }
                }
            }
        }
    }
};

fn eventfd_callback(data: *const CallbackManager.CallbackData) !void {
    if (data.cancelled) return;

    const io: *IO = @alignCast(@ptrCast(data.user_data.?));
    try io.register_eventfd_callback();
}

const BlockingTasksSetLinkedList = utils.LinkedList(BlockingTasksSet);

pub const BlockingTasksSet = struct {
    task_data_pool: [TotalTasksItems]BlockingTask,

    loop: *Loop,
    index: u16,
    finished_tasks: u16,

    disattached: bool,

    list: *BlockingTasksSetLinkedList,

    pub fn init(self: *BlockingTasksSet, list: *BlockingTasksSetLinkedList, loop: *Loop) void {
        for (&self.task_data_pool, 0..) |*task, index| {
            task.* = .{
                .data = .none,
                .operation = undefined,
                .index = @intCast(index)
            };
        }

        self.index = 0;
        self.finished_tasks = 0;
        self.disattached = false;

        self.loop = loop;
        self.list = list;
    }

    pub fn deinit(self: *BlockingTasksSet) void { 
        const node: BlockingTasksSetLinkedList.Node = @ptrFromInt(
            @intFromPtr(self) - @offsetOf(BlockingTasksSetLinkedList._linked_list_node, "data")
        );

        if (self.disattached) {
            self.list.unlink_node(node) catch {};
        }

        self.list.release_node(node);
    }

    pub fn cancel_all(self: *BlockingTasksSet, loop: *Loop) !void {
        for (self.task_data_pool[0..self.index]) |*task| {
            switch (task.data) {
                .callback => |*data| {
                    data.data.cancelled = true;
                    try Loop.Scheduling.Soon.dispatch_guaranteed(loop, data);
                },
                .none => {}
            }
        }
    }

    inline fn reset(self: *BlockingTasksSet) void {
        self.index = 0;
        self.finished_tasks = 0;
    }

    pub fn push(
        self: *BlockingTasksSet,
        operation: BlockingOperation,
        callback: ?*const CallbackManager.Callback
    ) !*BlockingTask {
        if (self.index == TotalTasksItems) return error.Overflow;

        try self.loop.reserve_slots(1);

        const index = self.index;
        self.index = index + 1;

        const data_slot = &self.task_data_pool[index];
        if (callback) |v| {
            data_slot.data = .{
                .callback = v.*
            };
        }
        data_slot.operation = operation;

        return data_slot;
    }

    pub inline fn pop(self: *BlockingTasksSet) void {
        self.index -= 1;
        self.loop.reserved_slots -= 1;
    }

    pub inline fn inc_finished_tasks_counter(self: *BlockingTasksSet) void {
        const finished_tasks = self.finished_tasks + 1;
        if (finished_tasks == TotalTasksItems and self.disattached) {
            self.deinit();
            return;
        }

        if (finished_tasks == self.index) {
            self.reset();
            return;
        }

        self.finished_tasks = finished_tasks;
    }

    pub inline fn free(self: *BlockingTasksSet) bool {
        if (self.index == TotalTasksItems) {
            self.disattached = true;
            return false;
        }

        return true;
    }

    pub fn traverse(self: *const BlockingTasksSet, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
        for (self.task_data_pool[0..self.index]) |*task| {
            switch (task.data) {
                .callback => |*cb| {
                    if (cb.data.traverse) |t| {
                        const vret = t(cb.data.user_data, @constCast(@ptrCast(visit)), arg);
                        if (vret != 0) return vret;
                    }

                    if (cb.data.exception_context) |ctx| {
                        const vret1 = visit.?(@ptrCast(ctx.module_ptr), arg);
                        if (vret1 != 0) return vret1;
                        if (ctx.callback_ptr) |cp| {
                            const vret2 = visit.?(@ptrCast(cp), arg);
                            if (vret2 != 0) return vret2;
                        }
                    }
                },
                .none => {}
            }
        }
        return 0;
    }
};

pub const WaitData = struct {
    callback: CallbackManager.Callback,
    fd: std.os.linux.fd_t,
    timeout: ?std.os.linux.kernel_timespec = null
};

pub const BlockingOperationData = union(BlockingOperation) {
    WaitReadable: WaitData,
    WaitWritable: WaitData,
    PerformRead: Read.PerformData,
    PerformWrite: Write.PerformData,
    PerformWriteV: Write.PerformVData,
    PerformRecvMsg: Read.RecvMsgData,
    PerformSendMsg: Write.SendMsgData,
    WaitTimer: Timer.WaitData,
    Cancel: usize,
    SocketShutdown: Socket.ShutdownData,
    SocketConnect: Socket.ConnectData,
    SocketAccept: Socket.AcceptData,
};

loop: *Loop = undefined,

busy_sets: BlockingTasksSetLinkedList = undefined,
set_node: BlockingTasksSetLinkedList.Node = undefined,
set: *BlockingTasksSet = undefined,

ring: std.os.linux.IoUring = undefined,
ring_blocked: bool = false,

eventfd: std.posix.fd_t = -1,
eventfd_val: u64 = 0,
blocking_ready_tasks: []std.os.linux.io_uring_cqe = &.{},

pub fn init(self: *IO, loop: *Loop, allocator: std.mem.Allocator) !void {
    self.busy_sets = BlockingTasksSetLinkedList.init(allocator);

    self.set_node = try self.busy_sets.create_new_node(undefined);
    self.set = &self.set_node.data;
    self.set.init(&self.busy_sets, loop);
    errdefer self.set.deinit();

    self.loop = loop;

    self.ring = try std.os.linux.IoUring.init(TotalTasksItems, 0);
    errdefer self.ring.deinit();

    // Mark io_uring fd CLOEXEC so child processes don't inherit it
    _ = std.posix.fcntl(self.ring.fd, std.posix.F.SETFD, @intCast(std.posix.FD_CLOEXEC)) catch {};

    self.eventfd = try std.posix.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
    errdefer std.posix.close(self.eventfd);

    self.blocking_ready_tasks = try allocator.alloc(std.os.linux.io_uring_cqe, TotalTasksItems);
    errdefer allocator.free(self.blocking_ready_tasks);

    self.ring_blocked = false;
}

pub fn register_eventfd_callback(self: *IO) !void {
    _ = try self.queue(.{
        .PerformRead = Read.PerformData{
            .data = .{
                .buffer = @as([*]u8, @ptrCast(&self.eventfd_val))[0..@sizeOf(u64)],
            },
            .fd = self.eventfd,
            .callback = .{
                .func = &eventfd_callback,
                .cleanup = null,
                .data = .{
                    .user_data = self,
                    .exception_context = null
                }
            }
        }
    });
}

pub fn wakeup_eventfd(self: *IO) !void {
    const val: u64 = 1;
    _ = try std.posix.write(self.eventfd, @as([*]const u8, @ptrCast(&val))[0..@sizeOf(u64)]);
}

pub fn traverse(self: *const IO, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
    const vret1 = self.set.traverse(visit, arg);
    if (vret1 != 0) return vret1;

    var node: ?BlockingTasksSetLinkedList.Node = self.busy_sets.first;
    while (node) |n| {
        node = n.next;
        const vret2 = n.data.traverse(visit, arg);
        if (vret2 != 0) return vret2;
    }
    return 0;
}

pub fn deinit(self: *IO) void {

    self.set.cancel_all(self.loop) catch {};
    self.set.deinit();
    var node: ?BlockingTasksSetLinkedList.Node = self.busy_sets.first;
    while (node) |n| {
        node = n.next;

        const set = &n.data;
        set.cancel_all(self.loop) catch {};
        set.deinit();
    }
    
    self.ring.deinit();
    self.busy_sets.allocator.free(self.blocking_ready_tasks);
    std.posix.close(self.eventfd);
}

pub fn get_blocking_tasks_set(self: *IO) !*BlockingTasksSet {
    const set = self.set;
    if (set.free()) {
        return set;
    }
    errdefer set.disattached = false;

    const new_node = try self.busy_sets.create_new_node(undefined);
    errdefer self.busy_sets.release_node(new_node);

    const new_set = &new_node.data;
    new_set.init(&self.busy_sets, self.loop);

    self.busy_sets.append_node(self.set_node);

    self.set_node = new_node;
    self.set = new_set;

    return new_set;
}

pub fn queue(self: *IO, event: BlockingOperationData) !usize {
    const set = try self.get_blocking_tasks_set();

    return switch (event) {
        .WaitReadable => |data| try Read.wait_ready(&self.ring, set, data),
        .WaitWritable => |data| try Write.wait_ready(&self.ring, set, data),
        .PerformRead => |data| try Read.perform(&self.ring, set, data),
        .PerformWrite => |data| try Write.perform(&self.ring, set, data),
        .PerformWriteV => |data| try Write.perform_with_iovecs(&self.ring, set, data),
        .PerformRecvMsg => |data| try Read.recvmsg(&self.ring, set, data),
        .PerformSendMsg => |data| try Write.sendmsg(&self.ring, set, data),
        .WaitTimer => |data| try Timer.wait(&self.ring, set, data),
        .SocketShutdown => |data| try Socket.shutdown(&self.ring, set, data),
        .Cancel => |data| try Cancel.perform(&self.ring, data),
        .SocketConnect => |data| try Socket.connect(&self.ring, set, data),
        .SocketAccept => |data| try Socket.accept(&self.ring, set, data)
    };
}

pub fn submit_guaranteed(ring: *std.os.linux.IoUring) !u32 {
    while (true) {
        return ring.submit() catch |err| {
            if (err == error.SignalInterrupt) continue;
            return err;
        };
    }
}

const IO = @This();
