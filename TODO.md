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
| jdz_allocator removed | Replaced with `std.heap.c_allocator` |
| `@cImport` no `usingnamespace` | ~100 symbols manually re-exported in `python_c.zig` |

---

## 🟡 PRIORITY 2: Network & Transport (6 done, 1 remaining)

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

### 2.5 — Subprocess Transport — ✅ DONE

`SubprocessTransport` type with get_pid, get_returncode, kill, terminate, send_signal, close.
Python `subprocess.Popen` (handles fork safely) + Zig timer-based exit monitoring (WaitTimer 100ms, waitpid WNOHANG). 8 tests pass (basic, sleep, pid, kill, terminate, send_signal, returncode, missing_factory).

**Bugs found & fixed:**
- **`ob_base = undefined` overwrote tp_alloc's `ob_refcnt`/`ob_type`** → GC crash. Fixed by preserving `ob_base` from `tp_alloc`.
- **Missing `tp_traverse`/`tp_clear`** → GC couldn't trace `protocol` reference. Added GC slots.
- **Future result was just transport** → coroutine unpack crash. Fixed: return `(transport, protocol)` tuple.
- **Orphaned child on error** → `Popen.kill()` on already-dead process blocks `wait()`. Fixed: check `popen.poll()` first.
- **Fork + io_uring incompatibility**: `fork()` in multi-threaded Python corrupts event loop. Fixed by using Python's `subprocess.Popen` (uses `posix_spawn`/`vfork` internally) instead of raw `fork()`. Also marked io_uring fd + eventfd with `CLOEXEC`. Exported `PyOS_BeforeFork`/`AfterFork` from python_c.zig.

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

## 🔵 Free-Threading Python Support (3.13t / 3.14t) — ✅ DONE

### Status: 100% functional (all 4 Python versions pass)

| Test set | 3.13t | 3.14t |
|----------|-------|-------|
| Pytest full suite (137 tests) | ✅ PASS | ✅ PASS |
| Import, event loop, futures, tasks | ✅ | ✅ |
| Signals, scheduling, asyncgens | ✅ | ✅ |
| Stream transport | ✅ | ✅ |
| FD watchers | ✅ | ✅ |
| Subprocess exec | ✅ | ✅ |

### Bugs Found & Fixed

| # | Bug | Root Cause | Fix |
|---|-----|-----------|-----|
| 1 | `py_decref(op=0x2d)` segfault | Garbage pointer — `ob_tid == 0` objects routed to shared refcount path | Added `ob_tid == 0 or ob_tid == currentThread` check (matches CPython's `_Py_IsOwnedByCurrentThread`) |
| 2 | Integer overflow `local -= 1` panic | Double-decref on freed object — `ob_ref_local` was 0 | Added `if (local == 0) return;` guard |
| 3 | Garbage pointers passing null checks | `py_xdecref` only checks `op != null` — `0x2d` is non-null but invalid | Added `< 0xFFFF` guard in all refcounting functions |
| 4 | Borrowed references freed by concurrent GC | Free-threading GC runs on other threads | `py_newref` on borrowed protocol ref in `stream_init` |
| 5 | Watcher hang on cancel+re-add | io_uring poll on re-added fd doesn't fire if cancel not drained | `call_soon` barrier in test to drain cancel; `loop.stopping` check skips re-arm |
| 6 | `BTreeHasElements` panic on `loop.close()` | Watchers not cleaned up before BTree deinit | Watcher cleanup loop in `loop.release()` |
| 7 | `py_decref` → `_Py_atomic_load_uint32_relaxed` undefined | CPython's `Py_INCREF`/`Py_DECREF` are static inline — not exported from libpython | **Switched to CPython stable ABI `Py_IncRef`/`Py_DecRef`** — properly exported, handles all free-threading internally |
| 8 | GC/refcounting teardown segfault | Module unload + loop close touch freed Python objects | Skip `deinitialize_object_fields` in `loop_clear`, skip `PyObject_GC_UnTrack` + `py_decref(type)` in `loop_dealloc`, skip `module_cleanup` Python cleanup — all gated on `!builtin.single_threaded` |
| 9 | All free-threading tests SEGFAULT (root cause) | `@cImport` didn't see `Py_GIL_DISABLED` macro → wrong `PyObject` struct layout (used `ob_refcnt` offset instead of `ob_ref_local`/`ob_ref_shared`/`ob_tid`) → `Py_IncRef`/`Py_DecRef` corrupted memory | `addCMacro("Py_GIL_DISABLED", "1")` in `build.zig` when `python_is_gil_disabled`. This ensures `@cImport` sees the correct struct layout matching the linked `libpython3.13t.so`. |

### Lessons Learned

- **Use CPython stable ABI**: `Py_IncRef`/`Py_DecRef` (exported from libpython) instead of manual refcounting via `Py_INCREF`/`Py_DECREF` (static inlines, not linkable).
- **uvloop pattern**: `freethreading_compatible=True` + `nogil` annotations let Cython generate GIL-safe code. We achieve the same by delegating to CPython's stable ABI functions.
- **`addCMacro` is critical**: Even when including free-threading headers, Zig's `@cImport` may not propagate preprocessor defines from included files. Explicit `addCMacro("Py_GIL_DISABLED", "1")` ensures correct struct layout.
- **Pointer validity guards**: `< 0xFFFF` check on all refcounting functions prevents segfaults from garbage pointers during teardown.

---

## 🛠 Scripts

- `scripts/test_all.sh` — Automated build+test for all 4 Python versions (3.13, 3.14, 3.13t, 3.14t). Auto-detects free-threading, runs zig unit tests. Usage: `bash scripts/test_all.sh`

---

## Reference

- **uvloop source:** https://github.com/MagicStack/uvloop (cloned at `/tmp/uvloop_repo`)
- **Zig 0.15.2 docs:** `docs/zig-0.15.2/langref.md` + `docs/zig-0.15.2/release-notes.md`
- **Test commands:** `zig build test` (Zig unit tests), `python setup.py test` (full suite)
- **Test counts:** 137 Python tests passing on all 4 versions (3.13, 3.14, 3.13t, 3.14t) + zig tests green
