const std = @import("std");

const CallbackManager = @import("callback_manager");
const IO = @import("main.zig");

pub const PerformData = struct {
    fd: std.posix.fd_t,
    callback: CallbackManager.Callback,
    data: []const u8,
    offset: usize = 0,
    timeout: ?std.os.linux.kernel_timespec = null,
    zero_copy: bool = false
};

pub const PerformVData = struct {
    fd: std.posix.fd_t,
    callback: CallbackManager.Callback,
    data: []const std.posix.iovec_const,
    offset: usize = 0,
    timeout: ?std.os.linux.kernel_timespec = null,
    zero_copy: bool = false
};

pub const SendMsgData = struct {
    fd: std.posix.fd_t,
    callback: CallbackManager.Callback,
    msg: *const std.posix.msghdr_const,
    flags: u32 = 0,
};

pub fn wait_ready(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: IO.WaitData) !usize {
    const data_ptr = try set.push(.WaitWritable, &data.callback);
    errdefer data_ptr.discard();

    const sqe = try ring.poll_add(@intCast(@intFromPtr(data_ptr)), data.fd, std.c.POLL.OUT);
    sqe.flags |= std.os.linux.IOSQE_ASYNC;

    if (data.timeout) |*timeout| {
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;
        const timeout_sqe = try ring.link_timeout(0, timeout, 0);
        timeout_sqe.flags |= std.os.linux.IOSQE_ASYNC;
    }

    // POLL_ADD has no pointer args — safe to defer submission.
    return @intFromPtr(data_ptr);
}

pub fn sendmsg(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: SendMsgData) !usize {
    const data_ptr = try set.push(.PerformSendMsg, &data.callback);
    errdefer data_ptr.discard();

    const sqe = try ring.sendmsg(@intCast(@intFromPtr(data_ptr)), data.fd, data.msg, data.flags);
    sqe.flags |= std.os.linux.IOSQE_ASYNC;

    // Flush SQE to kernel ring for immediate visibility.
    // User-space atomic store, not a syscall.
    _ = ring.flush_sq();

    // Deferred: msghdr_const is heap-allocated in transport struct (SockSendToData).
    return @intFromPtr(data_ptr);
}

pub fn perform(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: PerformData) !usize {
    const data_ptr = try set.push(.PerformWrite, &data.callback);
    errdefer data_ptr.discard();

    const sqe = blk: {
        if (data.zero_copy) {
            data_ptr.write_iov = .{
                .base = @ptrCast(@constCast(data.data.ptr)),
                .len = data.data.len,
            };
            data_ptr.msg_storage.name = null;
            data_ptr.msg_storage.namelen = 0;
            data_ptr.msg_storage.iov = @as([*]std.posix.iovec, @ptrCast(&data_ptr.write_iov));
            data_ptr.msg_storage.iovlen = 1;
            data_ptr.msg_storage.control = null;
            data_ptr.msg_storage.controllen = 0;
            data_ptr.msg_storage.flags = 0;

            const sqe = try ring.sendmsg(
                @intCast(@intFromPtr(data_ptr)), data.fd,
                @as(*const std.posix.msghdr_const, @ptrCast(&data_ptr.msg_storage)),
                std.posix.MSG.ZEROCOPY,
            );
            sqe.flags |= std.os.linux.IOSQE_ASYNC;

            // Deferred: msg_storage and write_iov live in task_data_pool (heap).
            // data.data.ptr points to transport's heap-allocated send buffer.
            break :blk sqe;
        }
        const sqe = try ring.write(@intCast(@intFromPtr(data_ptr)), data.fd, data.data, data.offset);
        sqe.flags |= std.os.linux.IOSQE_ASYNC;
        break :blk sqe;
    };

    if (data.timeout) |*timeout| {
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;
        const timeout_sqe = try ring.link_timeout(0, timeout, 0);
        timeout_sqe.flags |= std.os.linux.IOSQE_ASYNC;
    }

    // Deferred: heap buffer in WriteTransport.busy_buffers — safe.
    return @intFromPtr(data_ptr);
}

pub fn perform_with_iovecs(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: PerformVData) !usize {
    const data_ptr = try set.push(.PerformWriteV, &data.callback);
    errdefer data_ptr.discard();

    const sqe = blk: {
        if (data.zero_copy) {
            data_ptr.msg_storage.name = null;
            data_ptr.msg_storage.namelen = 0;
            data_ptr.msg_storage.iov = @as([*]std.posix.iovec, @ptrCast(@constCast(data.data.ptr)));
            data_ptr.msg_storage.iovlen = @intCast(data.data.len);
            data_ptr.msg_storage.control = null;
            data_ptr.msg_storage.controllen = 0;
            data_ptr.msg_storage.flags = 0;

            const sqe = try ring.sendmsg(
                @intCast(@intFromPtr(data_ptr)), data.fd,
                @as(*const std.posix.msghdr_const, @ptrCast(&data_ptr.msg_storage)),
                std.posix.MSG.ZEROCOPY,
            );
            sqe.flags |= std.os.linux.IOSQE_ASYNC;

            // Deferred: msg_storage lives in task_data_pool.
            // iovecs in data.data.ptr are heap-allocated from transport.
            break :blk sqe;
        }
        const sqe = try ring.writev(@intCast(@intFromPtr(data_ptr)), data.fd, data.data, data.offset);
        sqe.flags |= std.os.linux.IOSQE_ASYNC;
        break :blk sqe;
    };

    if (data.timeout) |*timeout| {
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;
        const timeout_sqe = try ring.link_timeout(0, timeout, 0);
        timeout_sqe.flags |= std.os.linux.IOSQE_ASYNC;
    }

    // Deferred: heap iovecs in WriteTransport.busy_buffers — safe.
    return @intFromPtr(data_ptr);
}
