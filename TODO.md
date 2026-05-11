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

### 7.2 — Subprocess PIDs Never Cleaned on Success — 🔴 CRITICAL — ✅ FIXED
**Files:** `leviathan/loop.py:733-746`, `src/transports/subprocess/transport.zig`, `tests/test_subprocess.py`

**Bug:** On successful `subprocess_exec`, Popen was added to `_subprocess_popens` but only removed on exception path. Pid stayed in dict forever. Worse — `Popen.__del__` (Python 3.13+) calls `_internal_poll()` which uses `waitpid(WNOHANG)`, consuming the exit status. If Popen was garbage-collected before the transport's `pidfd_exit_callback` ran, the transport got `ECHILD` and returncode = -1.

**Fix:**
1. Pop Popen from `_subprocess_popens` in `finally` block (always cleans up).
2. Transfer a reference to the Popen into the transport via `transport._popen = popen` — keeps Popen alive until `pidfd_exit_callback` processes the exit.
3. Added `popen: ?PyObject` field to `SubprocessTransportObject` Zig struct.
4. Expose via `PyGetSetDef` with `_popen` getter/setter, wired through `Py_tp_getset` slot (hardcoded value 73).
5. `pidfd_exit_callback` releases the popen ref on both `ECHILD` path (line 171-174) and normal exit path (line 234-236).
6. `subprocess_dealloc` also releases popen ref as safety net.

**Test:** `test_subprocess_popen_cleaned_on_success` verifies pid is removed from global dict, transport has `._popen` with matching pid, and exit_code == 0.

### 7.3 — Global `_subprocess_popens` Never Cleaned — 🟠 HIGH — ✅ FIXED

Obiated by 7.2 fix — `_subprocess_popens.pop(popen.pid, None)` now runs in `finally` block of `subprocess_exec`, so Popen is removed from the dict immediately after transport creation. No further fix needed.

### 7.4 — ThreadPoolExecutor Leak on Loop Close — 🟠 HIGH — ✅ FIXED
**File:** `leviathan/loop.py:93-99`

Added `close()` override on `Loop` class that shuts down `_default_executor` (with `wait=False`) before calling `_Loop.close()`. Also sets `_shutdown_executor_called = True` to prevent stale executor reuse.

**Note:** `shutdown(wait=False)` is used to avoid blocking during close. If the executor has pending tasks, they won't be waited on — but the loop is closing anyway.

### 7.5 — `asyncio.get_running_loop()` Misuse — NOT A BUG

**Files:** `leviathan/future.py:7-8`, `leviathan/task.py:15-16`

**Analysis:** `get_running_loop()` is the **correct** modern asyncio pattern (PEP 650, Python 3.10+). `get_event_loop()` is deprecated. This only raises `RuntimeError` if called outside an active loop context — same as standard `asyncio.Future()` and `asyncio.Task()` in 3.10+. No fix needed.

### 7.6 — Dead Code in `create_connection` — 🟡 MEDIUM — ✅ FIXED
**File:** `leviathan/loop.py:276-277`

Removed `if ssl is not None: kwargs["ssl"] = ssl` — dead code because the function returns early at the `_create_ssl_connection` branch when ssl is set.

### 7.7 — Typo in Error Message — 🟡 MEDIUM — ✅ FIXED
**File:** `leviathan/loop.py:199`

`"Default executor shutted down"` → `"Default executor shut down"`. Fixed typo.

### 7.8 — Bare `except` in `run_until_complete` — 🟡 MEDIUM — ✅ FIXED
**File:** `leviathan/loop.py:180-185`

Changed bare `except:` to `except BaseException:` — doesn't change runtime behavior (still catches `KeyboardInterrupt`/`SystemExit`, matching CPython's own `run_until_complete`), but suppresses linter warnings.

### 7.9 — Incomplete SSL unwrap Error Handling — 🟡 MEDIUM — ✅ FIXED
**File:** `leviathan/loop.py:41-45`

Added `SSLWantReadError` and `SSLWantWriteError` to the caught exceptions in `_SSLTransportWrapper.close()`. Note: these are subclasses of `SSLError` so they were already caught — the fix just makes the intent explicit for clarity.

### 7.10 — `ssl_shutdown_timeout` Parameter Ignored — 🟡 MEDIUM — ✅ FIXED
**Files:** `leviathan/loop.py:259,403`

- Added `ssl_shutdown_timeout` parameter forwarding from `create_unix_connection` → `_create_ssl_unix_connection` and `create_unix_server` → `_create_ssl_unix_server`.
- Added `ssl_shutdown_timeout` parameter to `_create_ssl_unix_connection` and `_create_ssl_unix_server` function signatures.
- Stored `shutdown_timeout` on `_SSLTransportWrapper` instances via `__init__` parameter.
- All `_SSLTransportWrapper` constructors now receive `shutdown_timeout=ssl_shutdown_timeout`.
- Actual timeout enforcement during SSL shutdown is a future enhancement (requires async wrapper around `unwrap()`).

### 7.11 — `resume_writing` Assertion Failure on Stream Transports — 🔴 CRITICAL — ✅ FIXED

**Context:** Discovered during `benchmark.py` TCP echo and socket ops benchmarks.

**Error:**
```
Failed to complete write operation on transport
transport: <leviathan.StreamTransport object at 0x...>
Traceback (most recent call last):
  File "/usr/lib64/python3.14/asyncio/streams.py", line 142, in resume_writing
    assert self._paused
AssertionError
```

**Root cause (two bugs):**
1. **Zero-init:** `StreamTransportObject.is_writing` defaulted to `false` (zero-init by `tp_alloc`). On first write completion, `write_operation_completed` saw `!is_writing == true` and called `protocol.resume_writing()` even though `pause_writing` was never called.
2. **Close race:** `close_transports()` set `is_writing = false` during close. Pending io_uring write completions that fired after close triggered spurious `resume_writing()`.

**Fix (rev 411–412):**
1. Set `instance.is_writing = true` in `stream_init_configuration()` (`src/transports/stream/constructors.zig:175`).
2. Removed `transport.is_writing = false` from `close_transports()` in `src/transports/stream/lifecycle.zig`.
3. Added `is_closing/closed` guard in `write_operation_completed()` in `src/transports/stream/write.zig`.

**Impact:** All benchmarks using TCP stream transports (TCP echo, Socket Ops) crash or emit hundreds of assertion errors. Connections fail non-deterministically.

### 7.12 — TCP Server SIGSEGV in Subprocess — 🔴 CRITICAL — ✅ FIXED

**Context:** Discovered during `benchmark.py` TCP echo benchmark with leviathan.

**Error:** Process exits with SIGSEGV (signal 11, return code -11), no stdout/stderr output.

**Root cause:** `close_transports()` in `src/transports/stream/lifecycle.zig` set `is_writing = false` during close. Any pending io_uring write completion that fired after close saw `!is_writing == true` and called `protocol.resume_writing()`, even though `pause_writing` was never called. This triggered `assert self._paused` in asyncio/streams.py, cascading into assertion errors that corrupted the C extension's exception handling state in subprocess context.

**Fix (rev 412):**
1. Removed `transport.is_writing = false` from `close_transports()` — redundant and harmful.
2. Added `is_closing/closed` guard in `write_operation_completed()` in `src/transports/stream/write.zig`.

This also resolved the 7.11 `resume_writing` assertion failure.

### 7.13 — UDP `create_datagram_endpoint` Hangs — 🔴 CRITICAL — ✅ FIXED

**Context:** Discovered during `benchmark.py` UDP Ping-Pong benchmark with leviathan.

**Error:** `loop.create_datagram_endpoint()` with a protocol that sends and receives datagrams hangs indefinitely. No timeout fires — the process blocks forever in `run_until_complete`.

**Root Cause (two bugs):**

1. **`sendto` ignored the `addr` argument:** `z_datagram_sendto` in `src/transports/datagram/write.zig` only used `args[0]` (the data) and ignored `args[1]` (the destination address). For unconnected sockets (e.g. an echo server), `sendto(data, addr)` was silently converted to `writev(data)` with no destination — the kernel returned `EDESTADDRREQ` but `error_received` is a no-op in the base protocol. The server's echo response was never actually sent.

2. **`get_extra_info("sockname")` returned `None`:** `src/transports/datagram/extra_info.zig` only handled `"socket"`. No `"sockname"` handler existed, so `transport.get_extra_info("sockname")` returned `None`, making it impossible to discover the dynamically-assigned port.

**Fix:**
1. `src/transports/datagram/write.zig`:
   - When `addr` argument is provided (not None), parse it via `utils.Address.from_py_addr`, allocate a `SendToData` struct on the heap, build a `msghdr` with the destination address, and queue a `PerformSendMsg` instead of `PerformWriteV`.
   - The completion callback `sendto_completed` handles buffer accounting (decrement `buffer_size`, call `resume_writing` if needed) and frees the heap-allocated struct and copied buffer.
   - Extracted shared `buffer_watermark_check` function to eliminate duplication.
   - Added `or self.closed` guard to `write_completed` to prevent post-close callback execution.

2. `src/transports/datagram/extra_info.zig`:
   - Added `"sockname"` handler that calls `getsockname()` on the fd and returns a Python `(host, port)` tuple via `utils.Address.to_py_addr`.

**Tests:** `test_datagram_echo` (full round-trip with unconnected echo server), `test_datagram_get_extra_info_sockname`, `test_datagram_get_extra_info_socket`. All 261 tests pass.

### 7.14 — `create_subprocess_exec` Crashes — 🟠 HIGH — ✅ FIXED

**Context:** Discovered during `benchmark.py` Subprocess benchmark with leviathan.

**Error:** Subprocess execution from a script file (not `-c`) raises an exception.

**Root cause (three issues):**
1. Python `subprocess_exec` used old signature `(protocol_factory, args)` — asyncio 3.13+ expects `(protocol_factory, program, *args)`. Popen received a tuple containing a list instead of string arguments.
2. C extension `SubprocessTransport` lacked `_wait()` (needed by `Process.wait()`) and `get_pipe_transport(fd)` (needed by subprocess protocol). The type has no `__dict__`, so methods couldn't be monkey-patched.
3. SubprocessTransport missing methods caused TypeError when standard asyncio code tried to call them.

**Fix (rev 414):**
1. Changed `subprocess_exec` signature to match CPython's `BaseEventLoop`: `(protocol_factory, program, *args)`.
2. Added `_TransportWrapper` Python class (`leviathan/loop.py:772-819`) that delegates to the C extension transport and provides `async _wait()` via an exit Future resolved when `connection_lost` fires, plus a `get_pipe_transport(fd)` stub returning None (no pipe support yet).
3. Wrapped `protocol_factory` to intercept `connection_made`/`connection_lost`.

**Tests:** 8 subprocess tests pass (basic, sleep, kill, terminate, send_signal, get_pid, returncode, popen cleanup).

---

## 🔴 PRIORITY 8: Performance — Bottleneck Analysis & Improvement Plan (2026-05-11)

Benchmark results (rev 416) reveal leviathan is **2-12× slower** than standard `asyncio` despite using `io_uring`. Analysis identified three systemic root causes.

### Benchmark Summary (rev 416, python3.14)

| Benchmark | vs asyncio | Category | 
|-----------|-----------|----------|
| Event fiesta factory | 0.42× | Task-intensive |
| Producer-consumer | 0.42× | Task-intensive |
| Food delivery | 0.53× | Task-intensive |
| Async task workflow | 0.46× | Task-intensive |
| Task spawn | 0.43× | Task-intensive |
| TCP Echo | 0.57× | I/O |
| Unix Echo | 0.72× | I/O |
| UDP Ping-Pong | 0.80× | I/O |
| Chat | 0.73× | Mixed (sleep-dominated) |
| **Subprocess** | **0.08×** | **100ms pidfd timer poll** |
| **Socket Ops** | **TIMEOUT** | **512× connect overhead > 30s** |

Pattern: Task scheduling overhead dominates (~0.42×), I/O shows moderate penalty (0.57–0.80×), subprocess is catastrophically slow due to 100ms polling interval, and high-connection-count benchmarks time out.

---

### Root Cause A: Mutex Held Across Allocation (`src/loop/scheduling/soon.zig:14–20`)

```
dispatch():
  mutex.lock()
    dispatch_nonthreadsafe()
      ready_queue.append()
        ensure_capacity(reserved_slots)  ← can malloc() under mutex
      wakeup_eventfd()                   ← syscall under mutex
  mutex.unlock()
```

And in the runner (`src/loop/runner.zig:220–266`), the mutex is held for **80% of each loop iteration** — covering queue swap, hook execution, and capacity checks. Any background thread calling `call_soon_threadsafe` is serialised behind this lock. The `reserved_slots` parameter passed as `min_capacity` to `ensure_capacity` forces capacity rechecks on every single `call_soon`, even when the queue already has space.

**Files:** `src/loop/scheduling/soon.zig`, `src/loop/runner.zig`

---

### Root Cause B: `reserved_slots` Inflates Queue Capacity Without Bound (`soon.zig:11`, `runner.zig:255–271`)

Three compounding effects:

1. **Every `call_soon` passes all reserved_slots as min_capacity** (`soon.zig:11`):
   ```zig
   _ = try ready_queue.append(callback, @max(1, self.reserved_slots));
   ```
   When 10,000 IO ops are in-flight, every call_soon requests 10,000 capacity slots.

2. **Every loop iteration grows BOTH double-buffer queues** (`runner.zig:255–258`):
   ```zig
   for (ready_tasks_queues) |*queue| {
       try queue.ensure_capacity(reserved_slots);
   }
   ```
   The inactive queue already has capacity from last swap — this is pure waste.

3. **Prune threshold inflated — queue never shrinks** (`runner.zig:269–271`):
   ```zig
   try call_once(ready_tasks_queue,
       @max(self.reserved_slots, ready_tasks_queue_max_capacity), loop_obj);
   ```
   When `reserved_slots` is high, the prune target is higher than actual usage, so the queue **never reclaims memory**. Memory grows monotonically under sustained load.

**Files:** `src/loop/scheduling/soon.zig:11`, `src/loop/runner.zig:255–271`, `src/callback_manager.zig:141–146`

---

### Root Cause C: pidfd Exit Timer Polls Every 100ms (`src/transports/subprocess/transport.zig:199,217,261`)

```zig
.duration = .{ .sec = 0, .nsec = 100_000_000 },  // 100ms timer!
```

**This is the actual subprocess bottleneck, not `Popen`.** The benchmark spawns `sys.exit(0)` processes that complete in microseconds. But `pidfd_exit_callback` uses `io_uring` timer-based polling at 100ms intervals to check `waitpid(WNOHANG)`. Each subprocess blocks for 100ms before the timer fires and detects the exit. 50 subprocesses × 100ms = 5s. This explains the 0.08× benchmark result exactly.

`subprocess.Popen` is NOT the bottleneck — asyncio calls it synchronously too and achieves 0.4s for the same workload. The `_TransportWrapper` Python overhead is also negligible compared to the 100ms timer.

**Correct fix:** Reduce the first poll to 1ms, then 10ms, then back off to 100ms. Or use `io_uring` IORING_OP_POLL_ADD on the pidfd for immediate exit notification (like `epoll` on pidfd).

**Files:** `src/transports/subprocess/transport.zig:199,217,261`

---

### Root Cause D: Per-Resource Capacity Reservation (`src/loop/main.zig:143–146`)

```zig
pub inline fn reserve_slots(self: *Loop, amount: usize) !void {
    const new_value = self.reserved_slots + amount;
    try self.ready_tasks_queues[self.ready_tasks_queue_index].ensure_capacity(new_value);
    self.reserved_slots = new_value;
}
```

Called on every blocking task submission (read, write, timer, connect, accept, DNS resolve). During a connection burst, hundreds of `reserve_slots(1)` calls trigger repeated capacity growth checks, each potentially doubling the allocation.

**File:** `src/loop/main.zig:143–146`, `src/loop/scheduling/io/main.zig:213`

---

### Additional Bottlenecks (Medium Priority)

| ID | File | Lines | Issue |
|----|------|-------|-------|
| E | `src/loop/runner.zig` | 199–203 | `ring.copy_cqes` syscall under mutex in non-waiting path |
| F | `src/loop/runner.zig` | 269 | No GIL-yield budget in `call_once` — one slow callback starves Python threads |
| G | `src/callback_manager.zig` | 297–352 | Sequential callback dispatch — head-of-line blocking |
| H | `src/callback_manager.zig` | 122–123 | `while` loop for capacity doubling could be single `@max` |
| I | `src/callback_manager.zig` | 259–271 | All pending callbacks executed synchronously during loop teardown |
| J | `src/callback_manager.zig` | 301–306, 346–349 | Debug-mode incref/decref per callback adds atomic refcount overhead |
| K | `src/loop/scheduling/soon.zig` | 6–8 | `wakeup_eventfd()` called BEFORE `queue.append()` — logically wrong order (wake before enqueue). Swapping lines 7–8 and 10–11 is cleaner. |

---

### Socket Ops TIMEOUT — Root Cause Chain

The `socket_ops` benchmark does 512 sequential `connect → write → read → close` cycles (×3 iterations). Each cycle triggers ~5 callbacks through the event loop. That's ~7680 callbacks total. With per-callback overhead amplified by:

1. **Mutex contention (Root Cause A)**: Each callback dispatch acquires/releases the mutex. 7680 lock operations serialised behind the main loop.
2. **Queue capacity inflation (Root Cause B)**: Every callback appends with `reserved_slots` as min_capacity. Even with only ~5 callbacks active, the queue maintains capacity for all reserved_slots (tens of thousands). The `increase_capacity()` calls under the mutex compound.
3. **No queue pruning (Root Cause B #3)**: Queue grows to fit reserved_slots but never shrinks. Each of the 7680 dispatches traverses the entire oversized queue.

The cumulative overhead pushes 7680 dispatch cycles past 30s. In contrast, `tcp_echo` at m=1024 only does 1 connection (large transfer), so the per-connection overhead is amortized.

---

### Lesson Alignment: Cross-Checking Each Fix Against Development History

Before implementing any fix, each must be validated against the 5 lessons learned and 4 architectural mandates.

#### Fix 8.1: Remove `reserved_slots` from capacity in `dispatch_nonthreadsafe`

- **Lesson 1 (Atomic Sleep)**: ✅ SAFE. We still hold the mutex during `queue.append()`. The ring_blocked/eventfd check is unchanged.
- **Lesson 2 (EINTR)**: ✅ Not affected.
- **Lesson 3 (GC traversal)**: ✅ Not affected — capacity changes don't create new PyObject references.
- **Lesson 4 (Safe traversal)**: ✅ Not affected — the executed flag + offset pattern is unchanged.
- **Lesson 5 (Loop resilience)**: ✅ Not affected.
- **Mandate 3 (Thread-safe dispatch)**: ✅ The mutex still protects the append.

#### Fix 8.2: Only `ensure_capacity` the active queue

- **Lesson 1**: ✅ SAFE. Still under mutex, still atomic.
- **Lesson 3**: ✅ IMPROVES GC — the inactive queue has smaller capacity, fewer slots to traverse. Less memory pressure.
- **All others**: ✅ Not affected.

#### Fix 8.3 (CORRECTED): Reduce pidfd timer interval

**ORIGINAL FIX (REJECTED):** "Run Popen in thread pool" — wrong because:
- `subprocess.Popen` is NOT the bottleneck (asyncio does it too and is 11× faster)
- Moving Popen to a thread pool would require complex GC tracking for the Popen object (Lesson 3)
- `fork()` in a multi-threaded process has known issues with `close_fds`, signal handlers, etc.

**CORRECTED FIX:**
- **Lesson 1**: ✅ SAFE. Timer-based callbacks go through the same dispatch path.
- **Lesson 2 (EINTR)**: ✅ Timer callbacks are not signals, no EINTR concerns.
- **Lesson 3**: ⚠️ The transport struct holds `popen: ?PyObject` which is already tracked via the loop's subprocess dict. No new GC issue, but verify `pidfd_exit_callback` still releases the popen ref even if timer fires multiple times.
- **Mandate 4 (Null discovery)**: ✅ Timer callback already handles `transport.closed` and `data.cancelled`.

**Implementation options (in order of preference):**
1. **Best**: Use `io_uring` IORING_OP_POLL_ADD on the pidfd — wakes immediately on process exit, zero polling overhead (like `epoll` on pidfd).
2. **Good**: Exponential backoff — 1ms → 10ms → 100ms → 1s. First poll catches 99% of exits instantly.
3. **Quick**: Simply reduce to 1ms for all polls. Slightly more CPU but eliminates the 5s penalty.
4. **Alternative**: Use `waitpid(WNOHANG)` in a synchronous busy-loop in `_wait()` on the Python side (not ideal).

#### Fix 8.4: Decouple prune from `reserved_slots`

- **Lesson 1**: ✅ SAFE. Pruning happens during `call_once` which runs without the mutex held.
- **Lesson 3 (GC)**: ✅ IMPROVES. Allowing the queue to shrink means fewer stale slots for GC to traverse. Reduces OOM risk under sustained load.
- **Lesson 4 (Safe traversal)**: ⚠️ Pruning must NOT remove slots that GC is still traversing. The `call_once` → `execute_callbacks` → `prune` sequence already updates offsets and executed flags atomically. Verify that `prune` only removes fully-executed slots (offset ≥ callbacks_num).

#### Fix 8.5: `@max` instead of `while` loop

- **All lessons**: ✅ SAFE. Pure computation change, same result. Slightly less time under mutex.

#### Fix 8.6 (REJECTED): Move `wakeup_eventfd` outside mutex

**REJECTED — violates Lesson 1 (Atomic Sleep).**

The current code (`soon.zig:6–8`) checks `ring_blocked` and writes eventfd INSIDE the mutex:
```zig
// Under mutex:
if (self.io.ring_blocked) {
    try self.io.wakeup_eventfd();
}
// Then append callback
```

This is correct per Lesson 1: the `ring_blocked` flag is set by the main loop BEFORE releasing the mutex (`runner.zig:184–185`):
```zig
self.io.ring_blocked = true;   // set BEFORE unlock
mutex.unlock();                 // then release for sleep
```

If we move the `ring_blocked` check outside the mutex, the decision is no longer atomic with the queue append. A background thread could:
1. Append callback (under mutex) → release mutex
2. Read `ring_blocked` → false (the loop hasn't set it yet)
3. Skip eventfd
4. Loop sets ring_blocked → sleeps

The callback sits in the queue until the next IO event — potentially forever in a pure task-based workload.

**The eventfd write is NOT the bottleneck.** It's a `write()` to a file descriptor — microseconds. The real issue is `ensure_capacity(reserved_slots)` inside `queue.append()` which can call `malloc()`. Fixes 8.1 and 8.2 address this.

**Minor improvement (safe):** Swap the order of eventfd check and queue append in `dispatch_nonthreadsafe` — wake AFTER enqueue, not before (lines 7–8 and 10–11). Logically cleaner, same behavior under mutex.

#### Fix 8.7 (QUALIFIED): Shrink mutex in runner

**ORIGINAL: "Only hold mutex for queue swap" — UNDERSPECIFIED.**

Per Lesson 1, the atomic sleep check (queue empty + ring_blocked set + sleep) must remain atomic. The mutex must cover:
1. Queue empty check
2. ring_blocked set to true
3. Mutex release (concurrent with sleep start)

The mutex does NOT need to cover:
- Hook execution (`execute_hooks`) — hooks don't touch the ready queue
- Queue ensure_capacity (Fix 8.2 removes this entirely)
- The actual io_uring sleep (already released by defer in poll_blocking_events)

**Corrected approach:**
```zig
mutex.lock()
  // queue empty check + ring_blocked = true (inside poll_blocking_events)
  poll_blocking_events(self, mutex, wait, ready_queue)  // releases mutex during sleep
  // mutex re-acquired, ring_blocked = false
  queue swap (atomic, under mutex)
mutex.unlock()
  // NEW: execute hooks WITHOUT mutex
  execute_hooks(check_hooks)
  // callback dispatch (already without mutex)
  call_once(...)
  execute_hooks(idle_hooks)
  execute_hooks(prepare_hooks)
mutex.lock()  // for next iteration
```

Move hook execution AFTER mutex.unlock() but keep the queue swap under lock. The `ring_blocked` check in dispatch continues to work because the queue state + ring_blocked flag remain atomically managed.

#### Fix 8.8 (QUALIFIED): Lock-free SPSC queue

**Lesson 3 (GC) & Lesson 4 (Safe traversal): CRITICAL CONSTRAINT.**

Any new queue data structure holding `Callback` objects (which contain `PyObject` references via `CallbackData`) MUST:
- Implement `tp_traverse` for GC visibility (Lesson 3)
- Use the same offset/executed flag pattern (Lesson 4)
- Be periodically drained to the main queue under mutex for GC traversal

**Lock-free queues cannot be safely traversed by GC** because the producer might be writing concurrently. The solution: drain the SPSC queue to a GC-traversable secondary buffer during `call_once`, then traverse that buffer. After draining, the SPSC queue can be GC-safe.

#### Fix 8.11 (Budget-based GIL yield)

- **Lesson 5 (Loop resilience)**: ✅ ALIGNS. Prevents one slow callback from starving all Python threads. After exceptions, the loop continues (existing behavior).
- **Lesson 1**: ✅ SAFE. Only affects callback execution, not the sleep decision.
- **Free-threading**: ⚠️ During GIL release, other Python threads may run and mutate shared state. Ensure all callback data is fully consumed before yielding.

#### Fix 8.12 (posix_spawn)

- **Lesson 2 (EINTR)**: `posix_spawn` internally handles EINTR, unlike raw `fork()`.
- **Lesson 3 (GC)**: ⚠️ The `subprocess.Popen` object is created inside `posix_spawn`. Must still be tracked in `_subprocess_popens` dict.
- **Practical concern**: `posix_spawn` with `close_fds=True` requires listing all open FDs (performance concern). Consider `os.posix_spawnp` or manual `vfork()` + `exec()` in a child.

---

### Corrected Improvement Plan

#### Phase 1: Quick Wins (Low Risk, High Impact) — Estimate 1–2 hours

| # | Fix | File(s) | Expected Gain | Lesson Check |
|---|-----|---------|---------------|--------------|
| 8.1 | 🔴 P1 | Remove `reserved_slots` from capacity param | Socket Ops: hang→complete | ✅ DONE (rev 418) |
| 8.2 | — | ~~Skip inactive queue ensure_capacity~~ | Retracted (no-op) | ❌ |
| 8.3 | 🔴 P1 | pidfd timer 100ms→1ms backoff | Subprocess: 3.1× faster | ✅ DONE (rev 421) |
| 8.4 | 🔴 P1 | Prune decoupled from `reserved_slots` | Prevents OOM under load | ✅ DONE (rev 422) |
| 8.5 | 🔴 P1 | `@max` instead of `while` loop | Code cleanup | ✅ DONE (rev 423) |
| 8.6 | 🟡 P2 | Check hooks outside mutex | Marginal (hooks lightweight) | ✅ DONE (rev 424) |
| 8.7 | 🟡 P2 | Skip redundant ensure_capacity in reserve_slots | Marginal (already short-circuits) | ✅ DONE (rev 425) |
| 8.8 | 🟡 P2 | ~~Lock-free SPSC queue~~ | SKIPPED — low ROI, GC complexity | ❌ |
| 8.9 | 🔵 P3 | GIL yield every 64 callbacks | Free-threading fairness | ✅ DONE (rev 426) |
| 8.10 | 🔵 P3 | ~~Separate io_uring lock~~ | SKIPPED — won't fix 0.42× gap | ❌ |
| 8.11 | 🔵 P3 | IORING_OP_POLL_ADD on pidfd | Sub-ms subprocess (needs IO layer support) | ⬜ Deferred |
| 8.12 | 🔵 P3 | posix_spawn for subprocess | Subprocess scaling (Python 3.8+) | ⬜ Deferred |

#### Phase 2: Structural Fixes (Medium Risk, Guarded by Lessons) — Estimate 1–2 days

| # | Fix | Expected Gain | Key Constraint |
|---|-----|---------------|----------------|
| 8.6 | Move hook execution outside mutex in runner (keep queue swap + sleep check atomic) | 20–30% loop throughput | **Must preserve atomic sleep check** (Lesson 1): `queue_empty_check + ring_blocked_set + sleep` must be atomic. |
| 8.7 | Batch capacity reservations — `reserve_slots` only grows when threshold exceeded | Prevents repeated growth checks | Keep reservation atomic with queue append under mutex. |
| 8.8 | Lock-free SPSC queue for `call_soon_threadsafe` → drain under mutex | Eliminates background thread contention | **Must add tp_traverse to drain buffer** (Lesson 3). **Must use offset+executed flags** (Lesson 4). |

#### Phase 3: Advanced (High Risk, Long Term) — Estimate 1 week+

| # | Fix | Expected Gain | Key Constraint |
|---|-----|---------------|----------------|
| 8.9 | Budget-based GIL yield in `call_once` — after N callbacks or T µs, release/reacquire GIL | Free-threading fairness | Must ensure all callback data consumed before yield (Lesson 4 + 5). |
| 8.10 | Separate lock for io_uring vs ready queue — concurrent IO submit + callback dispatch | io_uring-native throughput | Major refactor. Must maintain atomic sleep check across two locks. |
| 8.11 | io_uring IORING_OP_POLL_ADD on pidfd for subprocess — instant exit detection | Sub-millisecond subprocess exit | Replace timer-based polling entirely. Linux 5.3+ only. |
| 8.12 | posix_spawn instead of fork() for subprocess | Avoid COW page fault storm | Python 3.8+ API. Must handle close_fds enumeration. |

---

### Alignment Summary

| Fix | L1: Atomic Sleep | L2: EINTR | L3: GC Traversal | L4: Safe Traversal | L5: Loop Resilience |
|-----|:---:|:---:|:---:|:---:|:---:|
| 8.1 (capacity) | ✅ | ✅ | ✅ | ✅ | ✅ |
| 8.2 (retracted) | N/A | N/A | N/A | N/A | N/A |
| 8.3 (pidfd timer) | ✅ | ✅ | ⚠️ Verify | ✅ | ✅ |
| 8.4 (prune) | ✅ | ✅ | ✅ Improve | ⚠️ Verify | ✅ |
| 8.5 (@max) | ✅ | ✅ | ✅ | ✅ | ✅ |
| 8.6 (hooks outside mutex) | ⚠️ Must preserve | ✅ | ✅ | ✅ | ✅ |
| 8.7 (batch reserve) | ⚠️ Atomic check | ✅ | ✅ | ✅ | ✅ |
| 8.8 (SPSC queue) | ⚠️ Drain under mutex | ✅ | ⚠️ Need traverse | ⚠️ Need offset | ✅ |
| 8.9 (GIL yield) | ✅ | ✅ | ✅ | ⚠️ Consume first | ✅ |
| 8.10 (separate locks) | ⚠️ Two-lock atomic | ✅ | ⚠️ Changed paths | ⚠️ Changed paths | ✅ |
| 8.11 (pidfd poll) | ✅ | ✅ | ⚠️ Release popen | ✅ | ✅ |
| 8.12 (posix_spawn) | ✅ | ✅ | ⚠️ Track in dict | ✅ | ✅ |

---

## 🔴 PRIORITY 9: Callback Dispatch Rewrite — Flat Ring Buffer (2026-05-11)

### Root Cause of 0.42× Task Performance

After 7 performance optimizations (Priority 8), leviathan remains **2-2.5× slower** than `asyncio` on task-intensive workloads. All incremental fixes hit the same wall: the `CallbacksSetsQueue` linked-list dispatch layer.

```
uvloop/libuv:  array[index++] = callback_ptr     // O(1), 1 store
leviathan:     walk(node) → find_slot() → copy(80-byte Callback)
               // O(n) walk, memcpy per append
```

Per `call_soon` / `create_task`, the overhead is dominated by `try_append()` walking a linked list to find a free slot. This is fundamentally non-scalable and cannot be fixed with incremental changes.

### Design: Flat Ring Buffer Replacements

Replace the current `CallbacksSetsQueue` + `CallbacksSet` linked-list with two fixed-size ring buffers:

| Component | Current | New | Gain |
|-----------|---------|-----|------|
| Callback storage | Linked-list `CallbacksSet` nodes | `[N]Callback` fixed array | Eliminates node allocation + walking |
| Append | `try_append()` walk + copy | `buf[write_idx++] = *callback` | **O(1) pointer write** |
| Execute | `execute_callbacks()` offset tracking | `while read_idx < write_idx: buf[read_idx++]` | **O(1) read, no offset tracking** |
| Prune | `prune()` node deallocation | Reset `read_idx = write_idx = 0` | **O(1) ring reset** |
| Double-buffer | Two `CallbacksSetsQueue` | Two ring buffers, swap indices | Same pattern, simpler |

### Constraints from Lessons Learned

1. **Lesson 1 (Atomic Sleep):** Ring buffer swap must remain atomic under mutex.
2. **Lesson 3 (GC Traversal):** Ring buffer must implement `tp_traverse` — iterate `read_idx..write_idx`, visiting each callback's `PyObject` fields. Already have `executed` flag; add it to ring entries.
3. **Lesson 4 (Safe Traversal):** Before GIL yield (8.9), advance `read_idx` past consumed entries. GC won't see stale refs.
4. **Mandate 3 (Thread-Safe Dispatches):** Ring buffer write must be mutex-protected (same as current `dispatch`). Ring buffer read (in `call_once`) runs without mutex (same as current).

### Implementation Plan

#### Phase 1: Single Ring Buffer (Non-thread-safe)

| # | Task | Files | Risk |
|---|------|-------|------|
| 9.1 | Define `RingBuffer(N)` struct with `[N]Callback` array, `read_idx`, `write_idx`, `executed` bitset | New file or `callback_manager.zig` | Low |
| 9.2 | Replace `append()` with O(1) ring push | `callback_manager.zig` | Low |
| 9.3 | Replace `execute_callbacks()` loop with ring drain | `callback_manager.zig` | Low |
| 9.4 | Replace `prune()` with ring reset | `callback_manager.zig` | Low |
| 9.5 | Add `tp_traverse` for ring buffer | `callback_manager.zig` | Medium — needs visitation of active window |
| 9.6 | Wire up `call_once`, `dispatch_nonthreadsafe`, double-buffer swap | `runner.zig`, `soon.zig` | Medium |
| 9.7 | Update zig unit tests | `callback_manager.zig` | Low |
| 9.8 | Run full test suite + benchmarks | All | — |

**Expected impact:** Task-intensive benchmarks 0.42× → **0.8-1.5×** asyncio.

#### Phase 2: io_uring Batching (Requires Phase 1)

Once the dispatch layer is O(1), the next bottleneck is io_uring submission/reaping overhead:

| # | Task | Gain |
|---|------|------|
| 9.9 | Batch SQE submission — collect pending ops, submit all in one `io_uring_enter` | 2-5× I/O throughput |
| 9.10 | Batch CQE reaping — process all CQEs per `copy_cqes` without re-entering loop | Additional 1.5-2× I/O |
| 9.11 | Registered buffers / fixed files for hot paths | Marginal — zero-copy for known fds |

**Expected impact with both phases:** leviathan at **2-5×** asyncio, matching or beating uvloop.

### Risk Assessment

- **Backward compatibility:** Ring buffer replaces `CallbacksSetsQueue` entirely. ~10 test files, ~5 Zig modules affected.
- **GC safety:** Highest risk area. Must verify `tp_traverse` visits exactly `read_idx..write_idx` window, not full array.
- **Capacity overflow:** Ring buffer is fixed-size. Must handle "full" case gracefully (fall back to expanding array or reject). Current code already has `error.Overflow` path.
- **Free-threading:** Ring buffer indices must be atomically updated when GC may read them concurrently. Use `std.atomic` or ensure GC only runs during GIL-held sections.

---

## ✅ Completed Next Steps

1.  **`create_server` DNS** — ✅ Already implemented with async state machine (same callback pattern as `create_connection`). Added `host=None` support (binds to all interfaces: IPv4 + IPv6).

2.  **Universal Sockaddr Handling** — ✅ Already in place. Address resolution uses `std.net.Address` throughout; family is detected dynamically from `address.any.family`. Two minor `AF.INET` defaults exist as reasonable fallbacks (datagram endpoint, stream server) — consistent with Python stdlib behavior.

3.  **`getnameinfo`** — ✅ Already implemented at `src/loop/python/io/socket/getnameinfo.zig`. Registered as `loop.getnameinfo`. Uses PTR reverse DNS via `loop.dns.reverse_lookup`.

---

## 🛠 Scripts

- `scripts/test_all.sh` — Automated build+test for all 4 Python versions (3.13, 3.14, 3.13t, 3.14t). Auto-detects free-threading, runs zig unit tests, and verifies standard `test.test_asyncio` modules.

---

## Reference

- **uvloop source:** https://github.com/MagicStack/uvloop
- **Zig 0.15.2 docs:** `docs/zig-0.15.2/langref.md`
- **Test results:** 262 internal tests + standard asyncio suite modules PASS on all 4 versions (3.13, 3.14, 3.13t, 3.14t). 5/6 I/O benchmarks pass (tcp_echo, unix_echo, udp_pingpong, subprocess_bench, task_spawn); socket_ops TIMEOUT (see Priority 8).
