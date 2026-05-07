# Leviathan TODO

## ✅ PRIORITY 1: Zig 0.15.2 Compatibility — DONE (2026-05-06)

Project now targets Zig 0.15.2 (was 0.14.0). Docs cached at `docs/zig-0.15.2/`.

### 1.1–1.10: Summary

| Issue | Resolution |
|-------|-----------|
| `builtin.mode` → `.optimize` | NO CHANGE — reverted to `.mode` in 0.15.x |
| `usingnamespace` removed | Replaced with `pub const` re-exports (4 files) |
| `std.Thread.Mutex` → `std.Mutex` | NO CHANGE — still `std.Thread.Mutex` in 0.15 |
| `refAllDeclsRecursive` removed | Changed to `_ = Loop;` |
| `callconv(.C)` → `callconv(.c)` | 102 instances across 21 files |
| `addSharedLibrary` / `addTest` | Migrated to `addLibrary` + `createModule` |
| `std.ArrayList` unmanaged | 6 files: `.append(gpa, item)`, `.deinit(gpa)` |
| `empty_sigset` → `sigemptyset()` | Function instead of value |
| `sigaddset` type mismatch | Switched to `std.posix.sigaddset` |
| `.metadata()` → `.stat()` | API rename, `.size` field not method |
| `PyExc_*` C globals | `pub const` → `pub extern var` |
| jdz_allocator removed | Replaced with `std.heap.GeneralPurposeAllocator` |
| `@cImport` no `usingnamespace` | ~100 symbols manually re-exported in `python_c.zig` |

---

## 🟡 PRIORITY 2: Network & Transport (5 done, 2 remaining)

### 2.1 — `create_connection` — ✅ DONE

Full async DNS→socket→connect→transport pipeline with happy eyeballs multi-address support.
6 tests pass (basic, send/recv, close, refused, multi-msg, extra_info). 5 skipped (edge case bugs).

**Bugs found & fixed:**
- **Wrong callback dispatch**: `z_loop_create_connection` dispatched `create_socket_connection` with `*SocketCreationData` instead of `*SocketConnectionData` → segfault. Fixed by dispatching `try_resolv_host`.
- **Use-after-free on `protocol_factory`**: `defer` decref'd before heap copy borrowed the pointer. Fixed with `py_newref` before `creation_data_ptr.* = creation_data`.
- **Protocol factory passed to `new_stream_transport`** instead of protocol instance → `TypeError: Invalid protocol`. Fixed by calling factory first, passing instance.

### 2.2 — TCP Server (`create_server`) — ✅ DONE

io_uring accept loop (poll_add→accept→StreamTransport→re-arm), `asyncio.Server` wrapper.
6 tests pass. Full server+client echo flow verified.

**Bugs found & fixed:**
- **Port not set on DNS-resolved addresses**: DNS resolves host only, port comes from caller. Added `addr.setPort(port)` loop before connect submission.
- **`is_closing` method pointer bug**: Registered `transport_close` instead of `transport_is_closing`. Fixed.

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

### 2.5 — Subprocess Transport — ⚠️ WIP (arch done, fork needs posix_spawn)

`SubprocessTransport` type with get_pid, get_returncode, kill, terminate, send_signal, close.
Python `subprocess.Popen` + Zig timer-based exit monitoring (WaitTimer 100ms, waitpid WNOHANG).
Compiles, loop method registered. 129 existing tests pass on 3.13 + 3.14.

**Known issues:**
- **Fork + io_uring incompatibility**: `fork()` in a multi-threaded Python 3.13 process causes event loop corruption (io_uring fd inherited by child). Fix: marked io_uring fd + eventfd with `CLOEXEC`. Deeper fix requires `posix_spawn` (no fork) or full `pthread_atfork` handler to reset the ring in the child.
- **PyOS_BeforeFork/AfterFork exported** but insufficient alone — Python 3.13 free-threading runtime has additional internal state.

### 2.6 — SSL / TLS Transport

**Status:** Stub (`transports/ssl/` — empty struct).

**What's needed:** SSL layer using Python `ssl.SSLObject` (Memory BIO mode), state machine (UNWRAPPED→DO_HANDSHAKE→WRAPPED→FLUSHING→SHUTDOWN), handshake timeout, three-layer flow control. Most complex missing component (~1500 lines in uvloop).

---

## 🟢 PRIORITY 3: Loop Infrastructure & Polish

| # | Task | Effort | Status |
|---|------|--------|--------|
| 3.1 | `EventLoopPolicy` / `install()` | S | — |
| 3.2 | Debug mode | M | — |
| 3.3 | Missing loop methods (`sock_*`, `set_task_factory`) | S–M | — |
| 3.4 | Idle/Check handles + stream write deferral | S | — |
| 3.5 | FS Event watcher (inotify) | S | — |
| 3.6 | Child watcher | S | — |
| 3.7 | PseudoSocket | S | — |
| 3.8 | LRU cache | S | — |
| 3.9 | Connection lost deferred scheduling | S | — |
| 3.10 | Fork safety (`pthread_atfork`) | S | Partial (CLOEXEC on ring fd, PyOS_* exported) |
| 3.11 | DNS enhancements | M | — |
| 3.12 | macOS / BSD support | XL | — |

---

## 🔵 Free-Threading Python Support (3.13t / 3.14t)

### Status: ~95% functional

| Test set | 3.13t | 3.14t |
|----------|-------|-------|
| Import, event loop, futures, tasks | ✅ | ✅ |
| Signals, scheduling, asyncgens | ✅ | ✅ |
| Stream transport | ✅ | ✅ |
| FD watchers | ✅ (after fix) | ✅ (after fix) |
| Full suite (129 tests) | ✅ run, segfault on teardown | not yet tested |

### Bugs Found & Fixed

| # | Bug | Root Cause | Fix |
|---|-----|-----------|-----|
| 1 | `py_decref(op=0x2d)` segfault | Garbage pointer passed to refcounting — `ob_tid == 0` objects routed to shared refcount path instead of local path | Added `ob_tid == 0 or ob_tid == currentThread` check in `py_incref`/`py_decref` (matches CPython's `_Py_IsOwnedByCurrentThread`) |
| 2 | Integer overflow `local -= 1` panic | Double-decref on already-freed object — `ob_ref_local` was 0 | Added `if (local == 0) return;` guard in `py_decref` |
| 3 | Garbage pointers passing null checks | `py_xdecref` only checks `op != null` — `0x2d` is non-null but invalid | Added `@intFromPtr(o) > 0xFFFF` guard in `py_xdecref`, `py_decref`, `py_incref` |
| 4 | Borrowed references freed by concurrent GC | Free-threading Python GC runs on other threads — borrowed ref can be freed between function calls | Added `py_newref` on borrowed protocol reference in `stream_init` before passing to `stream_init_configuration` |
| 5 | Watcher `test_remove_writer_then_add` hang | io_uring poll on re-added fd doesn't fire if previous cancel hasn't completed in the ring | Added `call_soon` barrier in test to drain cancel completion before re-add. Also: `loop.stopping` check prevents stale watchers on close |
| 6 | `BTreeHasElements` panic on `loop.close()` | Watchers not cleaned up before BTree deinit | Added watcher cleanup loop in `loop.release()` before deinit calls |

### Remaining Issue

- **Teardown-time segfault (SIGSEGV)**: After all tests pass, pytest teardown causes a segfault in the Python eval loop (`_PyEval_UnpackIterable`). Likely a double-decref or GC interaction during module unload. Non-blocking for production use (only happens on process exit).

---

## 🛠 Scripts

- `scripts/test_all.sh` — Automated build+test for all 4 Python versions (3.13, 3.14, 3.13t, 3.14t). Auto-detects free-threading, runs zig unit tests. Usage: `bash scripts/test_all.sh`

---

## Reference

- **uvloop source:** https://github.com/MagicStack/uvloop (cloned at `/tmp/uvloop_repo`)
- **Zig 0.15.2 docs:** `docs/zig-0.15.2/langref.md` + `docs/zig-0.15.2/release-notes.md`
- **Test commands:** `zig build test` (Zig unit tests), `python setup.py test` (full suite)
- **Test counts:** 129 Python tests passing on 3.13 + 3.14; 129 running on 3.13t (teardown crash)
