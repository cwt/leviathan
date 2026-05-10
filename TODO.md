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

## 🟡 PRIORITY 2: Network & Transport — ALL DONE (7/7)

### 2.1 — `create_connection` — ✅ DONE

Full async DNS→socket→connect→transport pipeline with happy eyeballs multi-address support.
11 tests pass (basic, send/recv, close, refused, multi-msg, extra_info, missing_args, invalid_factory, lambda, write_eof, is_closing).

**Bugs found & fixed:**
- **Double-decref on `protocol_factory`**: Borrowed reference from `args` was decref'd in `defer` block → segfault in error path. Fixed.
- **`undefined` field cleanup segfault**: `SocketCreationData` fields were `undefined` before initialization, but `errdefer` called `deinitialize_object_fields` which touched them. Fixed by making fields optional/null.
- **Memory leak in result tuples**: `PyTuple_New` result was incref'd by `future_fast_set_result` but never released. Added `defer py_decref(result_tuple)`.
- **Double-close on connected socket**: `defer` in connect callback closed `fd` even on success. Fixed with `fd_created` toggle.
- **Filename typo**: Renamed `create_connnection.zig` to `create_connection.zig`.
- **`is_closing` always False**: `transport_close` didn't set the `closed` flag. Fixed.
- **Intermittent hang in free-threading**: Race condition in `poll_blocking_events` where the loop could block even if callbacks were queued by other threads. Fixed by checking `ready_queue.empty()` before blocking.
- **`Abort` crashes on signals**: `io_uring` operations (submit/poll) were interrupted by signals (EINTR), causing Zig panics or inconsistent returns to Python. Fixed by implementing silent retries on `SignalInterrupt` and removing all remaining `@panic`/`unreachable` calls in the core IO path.
- **GC instability in Subprocess**: `SubprocessTransport` was crashing during GC cycles. Switched to stable manual reference counting and fixed struct initialization to prevent clobbering the Python object head.

---

## 🧠 Lessons Learned: The Journey to 100% Stability

### 1. Free-Threading & The "Atomic Sleep"
In standard Python, the GIL hides many race conditions. In free-threading (3.13t/3.14t), the window between "checking for work" and "going to sleep" is a deadly trap.
*   **The Bug:** The loop checks the queue, sees it empty, then blocks in `io_uring`. A background thread adds a task *after* the check but *before* the block.
*   **The Lesson:** The decision to sleep must be **atomic**. Always check the ready queue while holding the loop mutex immediately before dropping the GIL and calling into the kernel.

### 2. Signal Resilience (EINTR is a Constant)
Signals (like `SIGCHLD` from subprocesses) can "stab" the process at any time, causing system calls to return `EINTR`.
*   **The Bug:** `io_uring_submit` or `io_uring_wait` returns `SignalInterrupt`. If not handled, this propagates as a Zig panic or an unexpected Python exception, often leading to a process `Abort`.
*   **The Lesson:** Every kernel-level interaction (`submit`, `wait`, `waitpid`) **must** be wrapped in a retry loop or a silent ignore for `SignalInterrupt`. The event loop should never exit due to a signal.

### 3. The "Ghost Reference" Cycle (GC invisibility)
Holding Python objects inside native Zig collections (std.ArrayList, BTree, etc.) without `tp_traverse` creates "Ghost References" that are invisible to the Garbage Collector.
*   **The Bug:** A Loop holds a Task, which holds a Future, which holds a callback pointing back to the Loop. Since Zig's memory isn't scanned by Python's GC, these cycles are never broken, leading to 30GB+ OOM events in long-running suites.
*   **The Lesson:** Any native structure holding a `PyObject` **must** be reachable via `tp_traverse`. Standard reference counting is insufficient for event loops due to inevitable complex cycles.

### 4. Safe Traversal of Execution Queues
Updating a progress marker *after* an operation is standard, but for GC safety, it must be **precise**.
*   **The Bug:** GC runs while a callback is halfway through a queue. If the queue is scanned from the start, GC visits already-executed and decref'd objects.
*   **The Lesson:** Immediately nullify references or update the traversal `offset` as each item is consumed. GC and execution are concurrent in free-threading; there is no "safe time" to have invalid pointers in a queue.

### 5. Standard Resilience (Loop never quits)
Asyncio event loops are designed to survive individual user-code failures.
*   **The Bug:** A single misbehaving callback could raise an exception that bubbled up to the Zig loop runner, causing the entire loop to stop.
*   **The Lesson:** Catch all exceptions at the callback boundary, route them to the loop's exception handler, and **continue** to the next event. The loop should only exit via explicit `stop()` or fatal signals.

---

## 🏗 Architectural Mandates (Rules for the Future)

1.  **NO PANICS in the IO Path:** Use `handle_zig_function_error` to convert Zig errors to Python exceptions. Never use `@panic` or `unreachable` in code that runs during the normal loop cycle.
2.  **EINTR Safety:** All `io_uring` submissions must use `IO.submit_guaranteed()`.
3.  **Thread-Safe Dispatches:** Any function that can be called from a background thread (like `call_soon_threadsafe`) must trigger the `eventfd` wakeup *only if* the loop is actually blocked.
4.  **Null Discovery:** In free-threading, GC can null out fields concurrently. Always use `?PyObject` and handle `null` gracefully in callbacks.

## 🔵 PRIORITY 4: Standard Compatibility & GC Stability — ✅ DONE (2026-05-10)

Full compatibility with standard `test.test_asyncio` suite modules. 185 internal tests + 400+ standard tests passing.

**Bugs found & fixed:**
- **Massive Memory Leak (35GB RSS OOM)**: Hidden reference cycles between `Loop`, `Task`, and `Future` objects stored in native Zig collections (queues, BTrees, DNS sets) were invisible to Python's GC. Implemented comprehensive `tp_traverse` for all core types.
- **GC Segfault on Deallocated Callbacks**: `tp_traverse` was visiting already-executed callbacks in internal queues that had already decref'd their Python objects. Fixed by updating queue offsets and adding `executed` flags to prevent visiting deallocated memory.
- **`ValueError` on Specialized Callables**: `_asyncio.TaskStepMethWrapper` (used by standard Task subclasses) failed with `Vectorcall`. Switched `Handle` execution to `PyObject_Call` for 100% compatibility.
- **DNS Lookup GC Blind Spot**: Pending async DNS queries were holding strong references to loop callbacks. Added `pending_queries` tracking list to DNS resolver for GC traversal.
- **Loop Abort on Callback Error**: Loop would stop abruptly on individual callback exceptions. Refactored `CallbackManager` to call the exception handler but continue processing subsequent events, matching standard `asyncio` behavior.
- **Exception Handler Signature Mismatch**: `leviathan/loop.py` used `_call_exception_handler` with an incompatible signature, causing "NoneType" logs. Fixed to pass `call_exception_handler` directly to Zig.

---

## 🔴 PRIORITY 5: Stability Hardening & Multi-Platform Support

Remaining architectural and feature gaps required for production readiness.

### 5.1 — Remove @panic and unreachable from IO Path — ✅ DONE (2026-05-10)
Convert all remaining hard failures to Python exceptions via `handle_zig_function_error`.
- `src/loop/python/io/watchers.zig`: removed `unreachable` in `cancel_watcher` and `@panic` on blocking_task_id.
- `src/loop/scheduling/soon.zig`: handled `ready_queue` overflow gracefully.
- `src/loop/scheduling/io/main.zig`: handled `BlockingTasksSet` overflow gracefully.
- `src/callback_manager.zig`: removed `@panic` from `append` and added unit test.
- Core: removed all `unreachable` and `@panic` from core IO path and data structures.

### 5.2 — Complete Happy Eyeballs — ✅ DONE (2026-05-10)
Implemented the `all_errors` path in `src/loop/python/io/client/create_connection.zig` to collect and report multiple connection failures using `ExceptionGroup` instead of panicking.

### 5.3 — DNS Resolver Enhancements
- Implement `EDNS0` and `DNSSEC` support in `src/loop/dns/resolv.zig`.
- Support full `resolv.conf` options in `src/loop/dns/parsers.zig`.

### 5.4 — Loop Lifecycle Refactoring — ✅ DONE (2026-05-10)
Raised Python `RuntimeError` or `RuntimeWarning` in `src/loop/main.zig` for double-init or dealloc-while-running instead of hard-panicking.

### 5.5 — GC Hardening for IO Callbacks — ✅ DONE (2026-05-10)
Added recursive `traverse` support to `CallbackData` and implementation for all `create_connection` related native structures. Fixed critical refcount leaks in exception paths.

### 5.6 — Multi-Platform Support (macOS / BSD / Windows)
Implement abstraction layer for `io_uring` and add backends for:
- `kqueue` (macOS / BSD)
- `epoll` (Linux fallback)
- `IOCP` (Windows)

---

## 🟢 PRIORITY 6: Long-term Risk Mitigation — ✅ DONE (2026-05-10)

Maintenance hazards and concurrency risks discovered during architectural audit.

### 6.1 — Eliminate PyTuple_SetItem Ref-Stealing Leaks — ✅ DONE (2026-05-10)
Replaced `PyTuple_SetItem` with `PyTuple_Pack` or wrapped in helpers to ensure references are correctly handled on all error paths. Affected `create_connection.zig`, `unix.zig`, `socket/ops.zig`, `datagram/main.zig`, and `subprocess/exec.zig`.

### 6.2 — Automated GC Traversal Checks — ✅ DONE (2026-05-10)
Added `verify_gc_coverage` compile-time assertions to ensure the `traverse` functions for complex structs stay in sync with their field definitions. Enhanced `py_visit` to generically visit all PyObject subclasses.

### 6.3 — DNS Arena Cleanup Consistency — ✅ DONE (2026-05-10)
Audited all async DNS paths and refactored `DNS.deinit` to properly release pending queries. Fixed critical `reserved_slots` leaks and group dispatch imbalances.

### 6.4 — Safe Initialization of Loop Fields — ✅ DONE (2026-05-10)
Replaced `undefined` initializations in `Loop.init` with safe `.{}` defaults, ensuring deterministic state during partial failures.

---

## 🔴 Known Issues & Potential Bugs

### 1. Blocking DNS in `create_server` — ✅ FIXED
### 2. Hardcoded IPv4 / Lack of DNS in Datagram — ✅ FIXED
### 3. Unix Connection Hangs — ✅ FIXED

### 4. DNS io_uring UDP Fallback (Incorrect Claim) — ✅ CLEANED UP
The claim that “io_uring UDP is broken on kernel 6.19.14” was incorrect.
Real testing confirmed UDP DNS works fine on this kernel.
Removed the dead `resolve_via_python_getaddrinfo` function from `src/loop/dns/main.zig`.

### 5. Watcher Cancel / Re-arm Race Condition
FD watcher state machine can occasionally hit a state where `blocking_task_id` is 0 during cancellation (src/loop/python/io/watchers.zig:322), indicating a tracking bug under heavy concurrency.

---

## 🔴 PRIORITY 7: New Bugs Found (2026-05-11)

Critical and high-priority bugs discovered during deep code analysis.

### 7.1 — Watcher Replacement Double-Fire — 🔴 CRITICAL
**File:** `src/loop/python/io/watchers.zig:203-209`

**Analysis:** The original claim of "memory leak" was incorrect — the `FDWatcher` struct is reused (not leaked), and `loop_watchers_cleanup_callback` properly frees it (line 32). The actual bug is a **potential double-fire**:

When replacing a watcher (e.g. `add_reader(fd, cb2)` after `add_reader(fd, cb1)`):
- The old in-flight `io_uring` operation was **never cancelled**
- The handle was swapped, but the old IO operation still completed via the same struct
- The new callback would fire **twice**: once from the old IO completion, once from the re-armed IO
- In testing, this caused a **segfault** during `loop.close()` due to the old IO completing on a repurposed struct at shutdown

**Fix applied:**
1. Remove old watcher from hash map via `watchers.delete(fd)`
2. Cancel old in-flight IO op (set `fd = -1` so cancel cleanup skips hash map)
3. If no in-flight IO, clean up the old struct immediately
4. Fall through to allocate a **new** `FDWatcher` struct, insert into hash map, and queue fresh IO
5. Added `test_rewrite_reader_old_callback_not_called` in `tests/loop/test_loop_watchers.py`

**Test results:** 191/191 internal tests + standard asyncio suite pass across all 4 Python versions (3.13, 3.14, 3.13t, 3.14t) + Zig unit tests.

### 7.2 — Subprocess PIDs Never Cleaned on Success — 🔴 CRITICAL
**File:** `leviathan/loop.py:727-744`

On successful `subprocess_exec`:
- `popen.pid` is added to `_subprocess_popens` (line 734)
- Only removed on exception path (line 743)
- On success, pid stays in dict forever

**Impact:** Memory leak of Popen objects on every successful subprocess call.

**Fix needed:** Add `_subprocess_popens.pop(popen.pid, None)` in the success path after `_Loop.subprocess_exec()` completes.

### 7.3 — Global `_subprocess_popens` Never Cleaned — 🟠 HIGH
**File:** `leviathan/loop.py:26,734,743`

The global dict keeps Popen objects alive until interpreter exit. No cleanup mechanism when loop closes.

**Fix needed:** Add cleanup in loop `close()` method or `shutdown_default_executor()`.

### 7.4 — ThreadPoolExecutor Leak on Loop Close — 🟠 HIGH
**File:** `leviathan/loop.py:91-92`

If loop closes without calling `shutdown_default_executor()`, the `ThreadPoolExecutor` leaks. No `close()` method in `Loop` class to clean this up automatically.

**Fix needed:** Implement `close()` method that cleans up `_default_executor`.

### 7.5 — `asyncio.get_running_loop()` Misuse — 🟠 HIGH
**Files:** `leviathan/future.py:7-8`, `leviathan/task.py:15-16`

Using `asyncio.get_running_loop()` will raise `RuntimeError` outside async context. Unlike deprecated `get_event_loop()`, it doesn't auto-create.

**Fix needed:** Use `asyncio.get_event_loop()` for backwards compatibility, or document that these require an active loop.

### 7.6 — Dead Code in `create_connection` — 🟡 MEDIUM
**File:** `leviathan/loop.py:276-277`

```python
if ssl is not None:
    kwargs["ssl"] = ssl  # Dead code - function returns at line 265 before this
```

### 7.7 — Typo in Error Message — 🟡 MEDIUM
**File:** `leviathan/loop.py:199`

```python
"Default executor shutted down"  # Should be "shutdown"
```

### 7.8 — Bare `except` in `run_until_complete` — 🟡 MEDIUM
**File:** `leviathan/loop.py:180-185`

Catches everything including `KeyboardInterrupt` and `SystemExit`.

### 7.9 — Incomplete SSL unwrap Error Handling — 🟡 MEDIUM
**File:** `leviathan/loop.py:41-45`

Missing `SSLWantReadError` and `SSLWantWriteError` in exception handling for `unwrap()`.

### 7.10 — `ssl_shutdown_timeout` Parameter Ignored — 🟡 MEDIUM
**File:** `leviathan/loop.py:259,403`

Parameter accepted but never used in `_create_ssl_server` or elsewhere.

---

## 🚀 Recommended Next Steps

1.  **Refactor `create_server` DNS**: Implement an async state machine for `create_server` resolution, similar to `create_connection`.
2.  **Universal Sockaddr Handling**: Abstract IPv4/IPv6/Unix address handling into a unified utility to remove hardcoded `AF_INET` dependencies.
3.  **Implement `getnameinfo`**: Complete the DNS suite by adding `loop.getnameinfo`.

---

## 🛠 Scripts

- `scripts/test_all.sh` — Automated build+test for all 4 Python versions (3.13, 3.14, 3.13t, 3.14t). Auto-detects free-threading, runs zig unit tests, and verifies standard `test.test_asyncio` modules.

---

## Reference

- **uvloop source:** https://github.com/MagicStack/uvloop
- **Zig 0.15.2 docs:** `docs/zig-0.15.2/langref.md`
- **Test results:** 189 internal tests + standard asyncio suite modules PASS on all 4 versions.
