const std = @import("std");

const CallbackManager = @import("callback_manager");
const IO = @import("main.zig");

pub const PerformData = struct {
    fd: std.posix.fd_t,
    callback: CallbackManager.Callback,
    data: std.os.linux.IoUring.ReadBuffer,
    offset: usize = 0,
    timeout: ?std.os.linux.kernel_timespec = null,
    zero_copy: bool = false
};

pub const RecvMsgData = struct {
    fd: std.posix.fd_t,
    callback: CallbackManager.Callback,
    msg: *std.posix.msghdr,
    flags: u32 = 0,
};

pub fn wait_ready(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: IO.WaitData) !usize {
    const data_ptr = try set.push(.WaitReadable, &data.callback);
    errdefer data_ptr.discard();

    const sqe = try ring.poll_add(@intCast(@intFromPtr(data_ptr)), data.fd, std.c.POLL.IN);
    sqe.flags |= std.os.linux.IOSQE_ASYNC;

    if (data.timeout) |*timeout| {
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;
        const timeout_sqe = try ring.link_timeout(0, timeout, 0);
        timeout_sqe.flags |= std.os.linux.IOSQE_ASYNC;
    }

    // POLL_ADD has no pointer args — safe to defer submission.
    // Will be flushed by poll_blocking_events().
    return @intFromPtr(data_ptr);
}

pub fn recvmsg(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: RecvMsgData) !usize {
    const data_ptr = try set.push(.PerformRecvMsg, &data.callback);
    errdefer data_ptr.discard();

    const sqe = try ring.recvmsg(@intCast(@intFromPtr(data_ptr)), data.fd, data.msg, data.flags);
    sqe.flags |= std.os.linux.IOSQE_ASYNC;

    // Immediate submit: recvmsg stores msghdr pointer in sqe.addr.
    // msghdr is heap-allocated in transport data (safe), but latency-sensitive.
    const ret = try IO.submit_guaranteed(ring);
    if (ret == 0) return error.SQENotSubmitted;
    return @intFromPtr(data_ptr);
}

pub fn perform(ring: *std.os.linux.IoUring, set: *IO.BlockingTasksSet, data: PerformData) !usize {
    const data_ptr = try set.push(.PerformRead, &data.callback);
    errdefer data_ptr.discard();

    const sqe = blk: {
        if (data.zero_copy) {
            var msghr = comptime std.mem.zeroes(std.posix.msghdr);

            switch (data.data) {
                .buffer_selection => return error.NotImplemented,
                .iovecs => |iovecs| {
                    msghr.iov = @constCast(iovecs.ptr);
                    msghr.iovlen = @intCast(iovecs.len);
                },
                .buffer => {
                    const sqe = try ring.read(@intCast(@intFromPtr(data_ptr)), data.fd, data.data, data.offset);
                    sqe.flags |= std.os.linux.IOSQE_ASYNC;
                    break :blk sqe;
                }
            }

            const sqe = try ring.recvmsg(@intCast(@intFromPtr(data_ptr)), data.fd, &msghr, std.posix.MSG.ZEROCOPY);
            sqe.flags |= std.os.linux.IOSQE_ASYNC;

            // Immediate submit: msghr is on the stack.
            const ret = try IO.submit_guaranteed(ring);
            if (ret == 0) return error.SQENotSubmitted;
            break :blk sqe;
        }
        const sqe = try ring.read(@intCast(@intFromPtr(data_ptr)), data.fd, data.data, data.offset);
        sqe.flags |= std.os.linux.IOSQE_ASYNC;
        break :blk sqe;
    };

    if (data.timeout) |*timeout| {
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;
        const timeout_sqe = try ring.link_timeout(0, timeout, 0);
        timeout_sqe.flags |= std.os.linux.IOSQE_ASYNC;
    }

    // Deferred: ring.read stores buffer pointer. Buffer is in transport
    // struct (heap) — safe until completion. Flushed by poll_blocking_events().
    return @intFromPtr(data_ptr);
}
