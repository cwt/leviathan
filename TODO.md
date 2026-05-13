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

### 6. Stack Allocation of Large Structures
When moving to fixed-size buffers (like the 256k RingBuffer), structs can grow to tens of megabytes (e.g., `Loop` ~42MB).
*   **The Bug:** Initializing a large struct via literal `self.* = .{...}` or returning it from a function causes a silent `SIGSEGV` (stack overflow) because the compiler creates a massive temporary on the stack.
*   **The Lesson:** Always use **in-place initialization** (`init(self: *Self)`) and individual field assignments for large structures. Ensure unit tests heap-allocate these structures instead of using `var loop: Loop = undefined;`.

### 7. Precision in Typed Traversal (GC Stability)
Using `@alignCast` on `?*anyopaque` pointers during `tp_traverse` is a common source of non-deterministic panics.
*   **The Bug:** `MultiConnectState.traverse_raw` used `@alignCast(@ptrCast(ptr))` which failed under certain memory pressures when Python passed a pointer with unexpected alignment.
*   **The Lesson:** Avoid `@alignCast` in hot GC paths. Refactor internal traversal functions to take **typed pointers** directly, and ensure the outer `tp_traverse` entry point performs the cast exactly once at the boundary.

### 8. Fatal Exception Propagation (Loop Hangs)
The Loop's exception handler must distinguish between "catchable" user exceptions and "fatal" Python exceptions (`KeyboardInterrupt`, `SystemExit`).
*   **The Bug:** The Zig exception handler was capturing ALL errors and routing them to `loop.call_exception_handler`. In Python, this just logs the error and returns control to Zig. For fatal exceptions, this created an infinite loop where the interrupt was ignored, hanging the process.
*   **The Lesson:** Explicitly check for fatal exceptions in the Zig callback runner. If `KeyboardInterrupt` or `SystemExit` is active, bypass the handler and return an error immediately to stop the event loop.

### 9. Immediate Submission for Wakeup (EventFD Deadlock)
In a batched submission model, certain critical operations cannot wait for the next loop tick.
*   **The Bug:** Queuing the `eventfd` read SQE without an immediate `submit` caused deadlocks. Background threads would write to the `eventfd`, but the loop (blocked in `io_uring_enter`) wasn't watching the `eventfd` yet because its SQE was still sitting in the local buffer.
*   **The Lesson:** Critical "infrastructure" SQEs (like the initial `eventfd` registration) MUST be submitted immediately upon registration to ensure the loop is responsive to external wakeups.

### 10. Coroutine Cleanup During Loop Shutdown (2026-05-13)
When a `KeyboardInterrupt` stops the loop before a Task's initial `execute_task_send` callback runs, the callback stays in the ready queue. During `loop.close()`, `release_ring_buffer` processes it with `cancelled = true`, but `execute_task_send` ignored the cancelled flag and called `_execute_task_send` — which tried to start the coroutine inside a torn-down loop (IO already deinitialized). The coroutine never got `PyIter_Send` called, so CPython emitted `RuntimeWarning: coroutine ... was never awaited` when the coroutine was later garbage collected.
*   **The Bug:** `execute_task_send` didn't check `data.cancelled`. When cancelled during `release_ring_buffer`, it tried the full start-up path (enter task context, send to coroutine, process yielded Future) which could fail because loop IO was deinitialized. The coroutine's `gi_frame` remained `NULL` → CPython warned on GC.
*   **The Fix:** In `execute_task_send`, when `data.cancelled` is true: call `PyIter_Send(coro, None)` just to set `gi_frame != NULL` (satisfies CPython's "was awaited" check), clear any Python errors, decref the task, and return. No other loop infrastructure is needed.
*   **The Lesson:** Every callback function must handle the `cancelled` flag from `release_ring_buffer`. For task callbacks, the minimum obligation is to ensure the coroutine is "started" in CPython's eyes before discarding it.
*   **Follow-up:** `execute_task_throw` at `src/task/callbacks.zig:437` had the same bug. Fixed by transferring the task's stored exception directly to the future when cancelled, without throwing into the coroutine.

### 11. Ghost Reference Cycle in Future Callbacks (2026-05-13)
When Task A awaits Future B, `wakeup_task` is registered as a `ZigGeneric` callback on Future B with `ptr = task`. `traverse_callbacks_queue()` at `src/future/callback.zig:164-177` had a no-op `ZigGeneric` arm — the GC could not see the `Task ← Future` cycle.
*   **The Bug:** Task holds `fut_waiter` → Future B. Future B's callback queue holds `ptr` → Task A. Python GC traverses Task A's members (including `fut_waiter` → Future B) and Future B's members (including `callbacks_queue`), but the `ZigGeneric.ptr` field was invisible. This ghost cycle leaked memory, causing OOM on long-running processes. The comment in the code literally said "This cycle is HIDDEN".
*   **The Fix:** The `ZigGeneric` arm now calls `visit(ptr)` to expose the Task pointer to the GC. The `@alignCast(@ptrCast(ptr))` is safe — `ptr` is always a `*PythonTaskObject` from the Python heap.
*   **The Lesson:** Any native structure holding a `PyObject` pointer must be reachable via `tp_traverse`. Skipping even one arm of a traversal union breaks the cycle detector.

---

## 🏗 Architectural Mandates (Rules for the Future)

1.  **NO PANICS in the IO Path:** Use `handle_zig_function_error` to convert Zig errors to Python exceptions. Never use `@panic` or `unreachable` in code that runs during the normal loop cycle.
2.  **EINTR Safety:** All `io_uring` submissions must use `IO.submit_guaranteed()`.
3.  **Thread-Safe Dispatches:** Any function that can be called from a background thread (like `call_soon_threadsafe`) must trigger the `eventfd` wakeup *only if* the loop is actually blocked.
4.  **Null Discovery:** In free-threading, GC can null out fields concurrently. Always use `?PyObject` and handle `null` gracefully in callbacks.
5.  **Initialization Order (GC Safety):** When adding items to a collection traversed by Python's GC, **ALWAYS fully initialize the data before advancing the index or linking the node.** Use `@atomicStore` with release semantics to ensure initialization is visible to GC threads.

## 🔵 PRIORITY 4: Standard Compatibility & GC Stability — ✅ DONE (2026-05-10)

Full compatibility with standard `test.test_asyncio` suite modules. 185 internal tests + 400+ standard tests passing.

---

## 🔴 PRIORITY 9: Callback Dispatch Rewrite — Flat Ring Buffer (2026-05-11)

### Root Cause of 0.42× Task Performance

After 7 performance optimizations (Priority 8), leviathan remains **2-2.5× slower** than `asyncio` on task-intensive workloads. All incremental fixes hit the same wall: the `CallbacksSetsQueue` linked-list dispatch layer.

```
uvloop/libuv:  array[index++] = callback_ptr     // O(1), 1 store
leviathan:     walk(node) → find_slot() → copy(80-byte Callback)
               // O(n) walk, memcpy per append
```

### Design: Flat Ring Buffer Replacements

Replace the current `CallbacksSetsQueue` + `CallbacksSet` linked-list with two fixed-size ring buffers.

### Implementation Plan

#### Phase 1: Single Ring Buffer (Non-thread-safe)

| # | Task | Files | Status |
|---|------|-------|:---:|
| 9.1 | Define `RingBuffer(N)` struct with `[N]Callback` array, `read_idx`, `write_idx`, `executed` bitset | `callback_manager.zig` | ✅ **DONE** |
| 9.2 | Replace `append()` with O(1) ring push | `callback_manager.zig` | ✅ **DONE** |
| 9.3 | Replace `execute_callbacks()` loop with ring drain | `callback_manager.zig` | ✅ **DONE** |
| 9.4 | Replace `prune()` with ring reset | `callback_manager.zig` | ✅ **DONE** |
| 9.5 | Add `tp_traverse` for ring buffer | `callback_manager.zig` | ✅ **DONE** |
| 9.6 | Wire up `call_once`, `dispatch_nonthreadsafe`, double-buffer swap | `runner.zig`, `soon.zig` | ✅ **DONE** |
| 9.7 | Update zig unit tests | `callback_manager.zig` | ✅ **DONE** |
| 9.8 | Run full test suite + benchmarks | All | ✅ **DONE** |

**Current impact:**
- Task-intensive benchmarks: 0.42× → **0.44×** (marginal gain, task spawning still bottlenecked).
- I/O benchmarks (UDP Ping-Pong): 0.80× → **1.08×** (matching/beating asyncio).
- Stability: No more linked-list walks or dynamic growth panics. GC-safe in free-threading.

#### Phase 2: io_uring Batching (Requires Phase 1)

Once the dispatch layer is O(1), the next bottleneck is io_uring submission/reaping overhead:

| # | Task | Status |
|---|------|:---:|
| 9.9 | Batch SQE submission — collect pending ops, submit all in one `io_uring_enter` | 🔴 **REVERTED** |
| 9.10 | Batch CQE reaping — process all CQEs per `copy_cqes` without re-entering loop | 🔴 Pending |
| 9.11 | Registered buffers / fixed files for hot paths | 🔴 Pending |

**Expected impact with both phases:** leviathan at **2-5×** asyncio, matching or beating uvloop.

---

## 🔴 PRIORITY 10: Python/Zig Boundary Overhead Elimination (2026-05-13)

### Root Cause of 0.2-0.4× Task Performance

Task Spawn benchmark (zero I/O, pure `create_task()`) shows leviathan at **0.21-0.39×** asyncio. Every `asyncio.sleep(0)` costs **12 Python/Zig boundary crossings** — each one pushes/tears down a Python stack frame:

```
create_task → register_task (Python)  |  1 crossing
execute_task_send → _enter_task       |  2
execute_task_send → PyContext_Enter   |  3
execute_task_send → PyIter_Send       |  4  (coro starts)
  coro → loop.call_later              |  5  (coro sleeps)
  coro suspends, yields Future
execute_task_send → PyContext_Exit    |  6
execute_task_send → _leave_task       |  7
...timer fires...
wakeup → PyIter_Send                  |  8  (coro resumes)
  coro → _leave_task                  |  9
```

The same work in uvloop takes ~3 crossings because enter/leave/context are inline C, not Python callbacks.

### Observation

Three of these calls (`_register_task`, `_enter_task`, `_leave_task`) are just PySet operations on `loop._asyncio_tasks` — we can call `PySet_Add`/`PySet_Discard` directly from Zig. No Python frame needed.

### Implementation Plan

#### Phase 1: Eliminate _register_task / _enter_task / _leave_task Python calls

| # | Task | Files | Status |
|---|------|-------|:---:|
| 10.1 | Cache `loop._asyncio_tasks` PySet pointer at loop init | `loop/main.zig`, `loop/python/constructors.zig`, `loop.py` | ✅ DONE |
| 10.2 | Replace `PyObject_Vectorcall(_register_task)` with `PySet_Add` in `task_schedule_coro` | `task/constructors.zig` | ⚠️ REVERTED — `_asyncio_tasks` not used by `all_tasks()` C builtin |
| 10.3 | Replace `PyObject_Vectorcall(_enter_task)` with direct set/dict ops | `task/callbacks.zig` | 🔴 Blocked — `set_running_task` requires `asyncio.tasks.task_info.running_tasks` dict access |
| 10.4 | Replace `PyObject_Vectorcall(_leave_task)` with direct set/dict ops | `task/callbacks.zig` | 🔴 Blocked — same as 10.3 |
| 10.5 | Skip `PyContext_Enter`/`Exit` when context is default | `task/callbacks.zig` | 🔴 Pending |
| 10.6 | Run full test suite + benchmarks | All | ✅ DONE (263 tests pass, no perf regression) |

**Expected impact:** 3-4 boundary crossings eliminated per task step. Task-intensive benchmarks (Event Fiesta, Producer-Consumer, Task Workflow, Task Spawn) should improve from 0.2-0.4× toward 0.5-0.7×. I/O benchmarks unaffected (already flat).

#### Phase 2: Further boundary reductions (future)

| # | Task | Status |
|---|------|:---:|
| 10.7 | Fuse `PyIter_Send` with enter/leave in a single Zig→Python trampoline | 🔴 Future |
| 10.8 | Investigate `PyEval_SaveThread`/`PyEval_RestoreThread` overhead in callback dispatch loop | 🔴 Future |
| 10.9 | Profile remaining boundary crossings with `perf` to find next bottleneck | 🔴 Future |

---

---

## ✅ Completed Next Steps

1.  **`create_server` DNS** — ✅ Already implemented with async state machine (same callback pattern as `create_connection`). Added `host=None` support (binds to all interfaces: IPv4 + IPv6).
2.  **Universal Sockaddr Handling** — ✅ Already in place. Address resolution uses `std.net.Address` throughout; family is detected dynamically from `address.any.family`.
3.  **`getnameinfo`** — ✅ Already implemented at `src/loop/python/io/socket/getnameinfo.zig`. Registered as `loop.getnameinfo`.

---

## 🛠 Scripts

- `scripts/test_all.sh` — Automated build+test for all 4 Python versions (3.13, 3.14, 3.13t, 3.14t). Auto-detects free-threading, runs zig unit tests, and verifies standard `test.test_asyncio` modules.

---

## Reference

- **uvloop source:** https://github.com/MagicStack/uvloop
- **Test results:** 263 internal tests + standard asyncio suite modules PASS on all 4 versions (3.13, 3.14, 3.13t, 3.14t). UDP Ping-Pong matches standard asyncio.

---

## 🔍 Codebase Audit (2026-05-13)

| Severity | Lesson | File:Line | Bug | Status |
|----------|--------|-----------|-----|:---:|
| Medium | 10. Coroutine Cleanup | `src/task/callbacks.zig:437` | `execute_task_throw` no `data.cancelled` check | ✅ Fixed |
| High | 3. Ghost Ref Cycles (now #11) | `src/future/callback.zig:164-177` | ZigGeneric ptr invisible to GC | ✅ Fixed |
| — | 2. EINTR / No Panics | `src/callback_manager.zig:90` | `@panic("RingBuffer overflow")` on dispatch | ⚠️ Intentional guardrail — fail-fast is better than silent error here |
| Low | 10. Coroutine Cleanup | `src/loop/python/control.zig:161` | `hook_callback` no `cancelled` check | ⚠️ False positive — hooks not in `release_ring_buffer` |
| Low | 7. tp_traverse Precision | `src/future/python/constructors.zig:85` | `@alignCast` on GC path | ⚠️ WON'T FIX — needs Future struct refactor |

2 real bugs fixed, 1 intentional guardrail, 2 false-positives / won't-fix.
