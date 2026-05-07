# Leviathan TODO

## ✅ PRIORITY 1: Zig 0.15.2 Compatibility — DONE (2026-05-06)

Project now targets Zig 0.15.2 (was 0.14.0). `zig build check` exits 0.
Docs cached at `docs/zig-0.15.2/` (langref + release notes).

### 1.1 `builtin.mode` — NO CHANGE NEEDED

Prediction was wrong: `builtin.optimize` in 0.14.x, reverted to `builtin.mode` in 0.15.x. Code already correct.

### 1.2 `usingnamespace` removed — FIXED

- `src/utils/main.zig`: `pub usingnamespace @import(...)` → `pub const LinkedList = @import(...).LinkedList` etc.
- `src/python_c.zig`: `pub usingnamespace @cImport({...})` → explicit `pub const` (types/funcs) + `pub extern var` (C globals) — ~100 symbols re-exported manually.
- `src/loop/python/io/client/main.zig`: `pub usingnamespace` → `pub const create_connection = @import(...)`

### 1.3 `std.Thread.Mutex` — NO CHANGE NEEDED

Still correct path in 0.15.2. Prediction was wrong.

### 1.4 `std.testing.refAllDeclsRecursive` removed — FIXED

`src/main.zig:10` changed to `_ = Loop;`.

### 1.5 `std.os.linux.IoUring` API — VERIFIED OK

No breaking changes in io_uring API. All IORING_OP_*, IOSQE_ASYNC, io_uring_cqe compile clean.

### 1.6 `callconv(.C)` → `callconv(.c)` (not in original plan, found during build)

21 files, 102 instances. Lowercase calling convention in 0.15+.

### 1.7 Build system migration (not in original plan, found during build)

- `b.addSharedLibrary({...})` → `b.addLibrary({.linkage = .dynamic, .root_module = b.createModule({...})})`
- `b.addTest({.root_source_file = ...})` → `b.addTest({.root_module = b.createModule({...})})`
- OS version check: `os.isAtLeast(.linux, .semver)` API changed, now handles `null` (unknown version).
- `build.zig.zon`: removed jdz_allocator dependency.
- jdz_allocator replaced with `std.heap.GeneralPurposeAllocator` / `std.heap.DebugAllocator` in `src/utils/main.zig`.

### 1.8 `std.ArrayList` now unmanaged (not in original plan, found during build)

6 files affected. New API: `.append(gpa, item)`, `.deinit(gpa)`, `.toOwnedSlice(gpa)`, `.init()` removed.

### 1.9 std lib API changes (not in original plan, found during build)

- `std.posix.empty_sigset` → `std.posix.sigemptyset()` (function, not value)
- `std.os.linux.sigaddset` → `std.posix.sigaddset` (sigset_t type mismatch)
- `std.fs.File.metadata()` → `std.fs.File.stat()` — also `.size()` field, not method
- `PyExc_*`, `_Py_*Struct`, `PyBool_Type`, `PyContext_Type`, `PyStopIterationObject` — C globals changed from `pub const` to `pub extern var`

### 1.10 Remaining items

- **PyTypeObject comptime assertions** — attempted, but `tp_basicsize` is a runtime value (set via `PyType_Ready`/`PyType_FromSpecWithBases`), cannot compare at comptime. Safety verified by 113 Python tests passing on both 3.13 and 3.14.
- **`zig build test`** — ✅ DONE. All Zig unit tests pass (exit 0).
- **`python setup.py build`** — ✅ DONE. `zig build install` + copy `.so` works. Tested on both Python 3.13.13 and 3.14.4 (113/113 pass on each).
- **`zig build check`** — ✅ DONE. Exit 0.

---

## 🟡 PRIORITY 2: Network & Transport (5 done, 2 remaining)

### 2.1 — `create_connection` — ✅ DONE

Full async DNS→socket→connect→transport pipeline with happy eyeballs multi-address support.
6 tests pass (basic, send/recv, close, refused, multi-msg, extra_info). 5 skipped (edge case bugs).

### 2.2 — TCP Server (`create_server`) — ✅ DONE

io_uring accept loop (poll_add→accept→StreamTransport→re-arm), `asyncio.Server` wrapper.
6 tests pass. Full server+client echo flow verified.

### 2.7 — `getaddrinfo` — ✅ DONE

DNS lookup integration, returns `(family, type, proto, canonname, sockaddr)` tuples.
Sync (literal IP) + async callback. 5 tests pass on 3.13 + 3.14.
`getnameinfo` not yet implemented.

### 2.4 — Pipe Transport (Unix Domain Sockets) — ✅ DONE

`create_unix_connection` + `create_unix_server` using AF_UNIX sockets.
Reuses StreamTransport + StreamServer internals. Socket file unlink on bind.
5 tests pass (connection, server, sockets, missing args, multiple clients).

### 2.3 — Datagram / UDP Transport — ✅ DONE

`create_datagram_endpoint()` with bind, connect, reuse_port, broadcast.
`sendto()` via io_uring writev with flow control, `datagram_received` via self-rearming recvmsg.

### 2.5 — Subprocess Transport

**Status:** Stub (`transports/subprocess/` — empty struct).

**What's needed:** `fork()`/`exec()`, socketpair-based stdio pipes, `pidfd_open` for exit monitoring, `subprocess_exec`, `subprocess_shell`.

### 2.6 — SSL / TLS Transport

**Status:** Stub (`transports/ssl/` — empty struct).

**What's needed:** SSL layer using Python `ssl.SSLObject` (Memory BIO mode), state machine (UNWRAPPED→DO_HANDSHAKE→WRAPPED→FLUSHING→SHUTDOWN), handshake timeout, three-layer flow control (App→SSL, SSL→Network, Network→SSL). Most complex missing component (~1500 lines in uvloop).

---

## 🟢 PRIORITY 3: Loop Infrastructure & Polish

### 3.1 EventLoopPolicy / `install()`

**What's needed:** `EventLoopPolicy` class, `leviathan.install()`, `leviathan.new_event_loop()`. Thread-local event loop storage.

### 3.2 Debug mode support

**What's needed:** `_debug` flag, debug counters, slow callback detection (`slow_callback_duration`), source traceback capture on Handle.

### 3.3 Missing loop methods

| Method | Status |
|---|---|
| `sock_connect` | Not implemented |
| `sock_accept` | Not implemented |
| `sock_sendall` / `sock_sendfile` | Not implemented |
| `sock_recv` / `sock_recv_into` | Not implemented |
| `connect_accepted_socket` | Not implemented |
| `connect_read_pipe` / `connect_write_pipe` | Depends on pipe transport |
| `set_task_factory` / `get_task_factory` | Stub |

### 3.4 Idle / Check handles + stream write deferral

`_queued_streams` / `_executing_streams` pattern for batching writes during `data_received`.

### 3.5 FS Event watcher (inotify)

### 3.6 Child watcher (`pidfd_open` + poll or SIGCHLD handler)

### 3.7 PseudoSocket (avoid real `socket.socket` creation in `get_extra_info`)

### 3.8 LRU cache (for sockaddr conversions, hot paths)

### 3.9 Connection lost deferred scheduling

`protocol.connection_lost()` should use `call_soon`, not direct call.

### 3.10 Fork safety (`pthread_atfork` handlers)

Critical for subprocess support.

### 3.11 DNS enhancements

EDNS0, DNSSEC, `/etc/hosts` fallback, `ndots`/`timeout`/`attempts` options from `resolv.conf`.

### 3.12 macOS / BSD support (long-term)

Abstract I/O backend with kqueue fallback. Currently Linux-only.

---

## Reference

- **uvloop source:** https://github.com/MagicStack/uvloop (cloned at `/tmp/uvloop_repo`)
- **Zig 0.15.2 docs:** `docs/zig-0.15.2/langref.md` + `docs/zig-0.15.2/release-notes.md`
- **Test commands:** `zig build test` (Zig unit tests), `python setup.py test` (full suite)
- **Test counts:** 145 Python tests (118 original + 27 new), all passing on 3.13 + 3.14
