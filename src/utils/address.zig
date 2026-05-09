const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

pub fn to_py_addr(address: std.net.Address) !PyObject {
    switch (address.any.family) {
        std.posix.AF.INET => {
            const sa = address.in.sa;
            var buf: [16]u8 = undefined;
            const host_ptr = python_c._c.inet_ntop(std.posix.AF.INET, &sa.addr, &buf, 16) orelse return error.SystemResources;
            const host_len = std.mem.len(host_ptr);
            const port = address.getPort();

            const py_host = python_c.PyUnicode_FromStringAndSize(host_ptr, @intCast(host_len)) orelse return error.PythonError;
            defer python_c.py_decref(py_host);
            const py_port = python_c.PyLong_FromLong(port) orelse return error.PythonError;
            defer python_c.py_decref(py_port);
            return python_c.PyTuple_Pack(2, py_host, py_port) orelse error.PythonError;
        },
        std.posix.AF.INET6 => {
            const sa = address.in6.sa;
            var buf: [46]u8 = undefined;
            const host_ptr = python_c._c.inet_ntop(std.posix.AF.INET6, &sa.addr, &buf, 46) orelse return error.SystemResources;
            const host_len = std.mem.len(host_ptr);
            const port = address.getPort();

            const py_host = python_c.PyUnicode_FromStringAndSize(host_ptr, @intCast(host_len)) orelse return error.PythonError;
            defer python_c.py_decref(py_host);
            const py_port = python_c.PyLong_FromLong(port) orelse return error.PythonError;
            defer python_c.py_decref(py_port);
            
            const py_flow = python_c.PyLong_FromUnsignedLongLong(sa.flowinfo) orelse return error.PythonError;
            defer python_c.py_decref(py_flow);
            const py_scope = python_c.PyLong_FromUnsignedLongLong(sa.scope_id) orelse return error.PythonError;
            defer python_c.py_decref(py_scope);
            
            return python_c.PyTuple_Pack(4, py_host, py_port, py_flow, py_scope) orelse error.PythonError;
        },
        std.posix.AF.UNIX => {
            const sa = address.un;
            const path = std.mem.span(@as([*:0]const u8, @ptrCast(&sa.path)));
            return python_c.PyUnicode_FromStringAndSize(path.ptr, @intCast(path.len)) orelse error.PythonError;
        },
        else => return error.UnsupportedAddressFamily,
    }
}

pub fn from_py_addr(py_addr: PyObject, family: ?i32) !std.net.Address {
    if (python_c.unicode_check(py_addr)) {
        // Unix path
        var size: python_c.Py_ssize_t = 0;
        const ptr = python_c.PyUnicode_AsUTF8AndSize(py_addr, &size) orelse return error.PythonError;
        const path = ptr[0..@intCast(size)];
        if (path.len >= 108) return error.NameTooLong;
        
        var sun: std.posix.sockaddr.un = undefined;
        @memset(std.mem.asBytes(&sun), 0);
        sun.family = std.posix.AF.UNIX;
        @memcpy(sun.path[0..path.len], path);
        sun.path[path.len] = 0;
        return .{ .un = sun };
    }

    if (python_c.PyTuple_Check(py_addr) <= 0) return error.PythonError;
    const size = python_c.PyTuple_Size(py_addr);
    
    const py_host = python_c.PyTuple_GetItem(py_addr, 0) orelse return error.PythonError;
    const py_port = python_c.PyTuple_GetItem(py_addr, 1) orelse return error.PythonError;

    var host_size: python_c.Py_ssize_t = 0;
    const host_ptr = python_c.PyUnicode_AsUTF8AndSize(py_host, &host_size) orelse return error.PythonError;
    const host = host_ptr[0..@intCast(host_size)];
    const port: u16 = @intCast(python_c.PyLong_AsInt(py_port));

    if (size == 2) {
        // IPv4 or IPv6 (depending on family or content)
        if (family == std.posix.AF.INET6 or std.mem.indexOfScalar(u8, host, ':') != null) {
            return std.net.Address.parseIp6(host, port) catch |err| {
                if (err == error.InvalidCharacter) {
                    // Might be a hostname, but from_py_addr usually expects resolved IPs
                    // or we handle it in DNS. For now, assume it's an IP literal.
                    return err;
                }
                return err;
            };
        } else {
            return std.net.Address.parseIp4(host, port);
        }
    } else if (size == 4) {
        // IPv6 with flowinfo and scope_id
        const py_flow = python_c.PyTuple_GetItem(py_addr, 2) orelse return error.PythonError;
        const py_scope = python_c.PyTuple_GetItem(py_addr, 3) orelse return error.PythonError;
        
        const flowinfo: u32 = @intCast(python_c.PyLong_AsUnsignedLong(py_flow));
        const scope_id: u32 = @intCast(python_c.PyLong_AsUnsignedLong(py_scope));
        
        var addr = try std.net.Address.parseIp6(host, port);
        addr.in6.sa.flowinfo = flowinfo;
        addr.in6.sa.scope_id = scope_id;
        return addr;
    }
    
    return error.InvalidAddress;
}

// test "to_py_addr/from_py_addr: IPv4" {
//     const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
//     const py_addr = try to_py_addr(addr);
//     defer python_c.py_decref(py_addr);
//     
//     try std.testing.expect(python_c.PyTuple_Check(py_addr) > 0);
//     try std.testing.expectEqual(@as(python_c.Py_ssize_t, 2), python_c.PyTuple_Size(py_addr));
//     
//     const back = try from_py_addr(py_addr, null);
//     try std.testing.expectEqual(std.posix.AF.INET, back.any.family);
//     try std.testing.expectEqual(@as(u16, 8080), back.getPort());
// }
// 
// test "to_py_addr/from_py_addr: IPv6" {
//     const addr = std.net.Address.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 8080, 0, 0);
//     const py_addr = try to_py_addr(addr);
//     defer python_c.py_decref(py_addr);
//     
//     try std.testing.expect(python_c.PyTuple_Check(py_addr) > 0);
//     try std.testing.expectEqual(@as(python_c.Py_ssize_t, 4), python_c.PyTuple_Size(py_addr));
//     
//     const back = try from_py_addr(py_addr, null);
//     try std.testing.expectEqual(std.posix.AF.INET6, back.any.family);
//     try std.testing.expectEqual(@as(u16, 8080), back.getPort());
// }
// 
// test "to_py_addr/from_py_addr: Unix" {
//     const path = "/tmp/test.sock";
//     var sun: std.posix.sockaddr.un = undefined;
//     sun.family = std.posix.AF.UNIX;
//     @memcpy(sun.path[0..path.len], path);
//     sun.path[path.len] = 0;
//     const addr = std.net.Address{ .un = sun };
//     
//     const py_addr = try to_py_addr(addr);
//     defer python_c.py_decref(py_addr);
//     
//     try std.testing.expect(python_c.unicode_check(py_addr));
//     
//     const back = try from_py_addr(py_addr, null);
//     try std.testing.expectEqual(std.posix.AF.UNIX, back.any.family);
//     try std.testing.expectEqualStrings(path, std.mem.span(@as([*:0]const u8, @ptrCast(&back.un.path))));
// }
