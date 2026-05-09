from .leviathan_zig import Loop as _Loop

from concurrent.futures import ThreadPoolExecutor
from typing import (
    Any,
    Callable,
    TypedDict,
    NotRequired,
    AsyncGenerator,
    Awaitable,
    TypeVar,
    TypeVarTuple,
    Unpack
)
from logging import getLogger

import asyncio, socket
import threading

logger = getLogger(__package__)

_T = TypeVar("_T")
_Ts = TypeVarTuple("_Ts")

# Keep Popen objects alive to prevent __del__ from reaping processes before our exit watcher
_subprocess_popens: dict[int, Any] = {}


class _SSLTransportWrapper:
    """Wraps a raw transport to encrypt writes through an SSL object."""

    def __init__(self, ssp, raw_transport, ssl_module):
        self._ssp = ssp
        self._raw_t = raw_transport
        self._sslmod = ssl_module

    def write(self, data):
        self._ssp._sslobj.write(data)
        self._ssp._f()

    def close(self):
        try:
            self._ssp._sslobj.unwrap()
        except (self._sslmod.SSLSyscallError, self._sslmod.SSLError):
            pass
        self._ssp._f()
        self._raw_t.close()

    def get_extra_info(self, name, default=None):
        return self._raw_t.get_extra_info(name, default)

    def is_closing(self):
        return self._raw_t.is_closing()

    def can_write_eof(self):
        return self._raw_t.can_write_eof()

    def write_eof(self):
        self._raw_t.write_eof()

    def abort(self):
        self._raw_t.abort()

    def get_write_buffer_size(self):
        return self._raw_t.get_write_buffer_size()


class ExceptionContext(TypedDict):
    message: NotRequired[str]
    exception: Exception
    callback: NotRequired[object]
    future: NotRequired[asyncio.Future[Any]]
    task: NotRequired[asyncio.Task[Any]]
    handle: NotRequired[asyncio.Handle]
    protocol: NotRequired[asyncio.BaseProtocol]
    transport: NotRequired[asyncio.BaseTransport]
    socket: NotRequired[socket.socket]
    asyncgen: NotRequired[AsyncGenerator[Any]]


class Loop(_Loop):
    def __init__(self, ready_tasks_queue_min_bytes_capacity: int = 10**6) -> None:
        _Loop.__init__(
            self, ready_tasks_queue_min_bytes_capacity, self._call_exception_handler
        )

        self._exception_handler: Callable[[ExceptionContext], None] = (
            self.default_exception_handler
        )

        self._default_executor: ThreadPoolExecutor|None = None
        self._shutdown_executor_called: bool = False

    def _call_exception_handler(
        self,
        exception: Exception,
        *,
        message: str | None = None,
        callback: object | None = None,
        future: asyncio.Future[Any] | None = None,
        task: asyncio.Task[Any] | None = None,
        handle: asyncio.Handle | None = None,
        protocol: asyncio.BaseProtocol | None = None,
        transport: asyncio.BaseTransport | None = None,
        socket: socket.socket | None = None,
        asyncgenerator: AsyncGenerator[Any] | None = None,
    ) -> None:
        context: ExceptionContext = {"exception": exception}
        if message is not None:
            context["message"] = message
        if callback is not None:
            context["callback"] = callback
        if future is not None:
            context["future"] = future
        if task is not None:
            context["task"] = task
        if handle is not None:
            context["handle"] = handle
        if protocol is not None:
            context["protocol"] = protocol
        if transport is not None:
            context["transport"] = transport
        if socket is not None:
            context["socket"] = socket
        if asyncgenerator is not None:
            context["asyncgen"] = asyncgenerator

        self._exception_handler(context)

    def default_exception_handler(self, context: ExceptionContext) -> None: # type: ignore
        message = context.get("message")
        if not message:
            message = "Unhandled exception in event loop"

        log_lines = [message]
        for key, value in context.items():
            if key in {"message", "exception"}:
                continue
            log_lines.append(f"{key}: {value!r}")

        exception = context.get("exception")
        logger.error("\n".join(log_lines), exc_info=exception)

    def call_exception_handler(self, context: ExceptionContext) -> None: # type: ignore
        self._exception_handler(context)

    # --------------------------------------------------------------------------------------------------------
    # If you're interested in using debug mode, use the CPython event loop implementation instead of Leviathan.
    def get_debug(self) -> bool:
        return False

    def set_debug(self, enabled: bool) -> None:
        _ = enabled
        return

    # --------------------------------------------------------------------------------------------------------

    async def shutdown_asyncgens(self) -> None:
        asyncgens = self._asyncgens
        closing_agens = list(asyncgens)
        asyncgens.clear()

        results = await asyncio.gather(
            *[agen.aclose() for agen in closing_agens], return_exceptions=True
        )

        for result, agen in zip(results, closing_agens, strict=True):
            if isinstance(result, Exception):
                self._exception_handler(
                    {
                        "message": f"an error occurred during closing of "
                        f"asynchronous generator {agen!r}",
                        "exception": result,
                        "asyncgen": agen,
                    }
                )

    def __run_until_complete_cb(self, future: asyncio.Future[Any]) -> None:
        loop = future.get_loop()
        loop.stop()

    def run_until_complete(self, future: Awaitable[_T]) -> _T:
        if self.is_closed() or self.is_running():
            raise RuntimeError("Event loop is closed or already running")

        new_task = not asyncio.isfuture(future)
        new_future = asyncio.ensure_future(future, loop=self)
        new_future.add_done_callback(self.__run_until_complete_cb)
        try:
            self.run_forever()
        except:
            if new_task and new_future.done() and not new_future.cancelled():
                new_future.exception()
            raise
        finally:
            new_future.remove_done_callback(self.__run_until_complete_cb)

        if not new_future.done():
            raise RuntimeError("Event loop stopped before Future completed.")

        return new_future.result()

    def run_in_executor(
        self, executor: Any, func: Callable[[Unpack[_Ts]], _T], *args: Unpack[_Ts]
    ) -> asyncio.Future[_T]:
        if executor is None and (executor := self._default_executor) is None:
            if self._shutdown_executor_called:
                raise RuntimeError("Default executor shutted down")

            executor = ThreadPoolExecutor(thread_name_prefix="leviathan")
            self._default_executor = executor

        concurrent_future = executor.submit(func, *args)
        return asyncio.wrap_future(concurrent_future, loop=self) # type: ignore

    def set_default_executor(self, executor: Any) -> None:
        if not isinstance(executor, ThreadPoolExecutor):
            raise TypeError("executor must be ThreadPoolExecutor")

        self._default_executor = executor

    def _do_shutdown(self, future: asyncio.Future[None]) -> None:
        is_closed: Callable[[], bool] = self.is_closed # type: ignore
        call_soon_threadsafe: Callable[..., asyncio.Handle] = self.call_soon_threadsafe # type: ignore

        if (executor := self._default_executor) is None:
            raise RuntimeError("Default executor is None")

        try:
            executor.shutdown(wait=True)
            if not is_closed():
                call_soon_threadsafe(
                    asyncio.futures._set_result_unless_cancelled, # type: ignore
                    future, None
                )
        except Exception as ex:
            if not is_closed() and not future.cancelled():
                call_soon_threadsafe(future.set_exception, ex)

    async def shutdown_default_executor(self, timeout: float|None = None) -> None:
        if timeout is not None and timeout < 0:
            raise ValueError("Invalid timeout")

        self._shutdown_executor_called = True
        executor = self._default_executor
        if executor is None:
            return

        future: asyncio.Future[None] = self.create_future() # type: ignore
        thread = threading.Thread(target=self._do_shutdown, args=(future,))
        thread.start()
        try:
            async with asyncio.timeouts.timeout(timeout):
                await future
        except asyncio.TimeoutError:
            executor.shutdown(wait=False)
        else:
            thread.join()

    async def create_connection(
        self, protocol_factory: Callable[[], asyncio.BaseProtocol],
        host: str|None = None, port: int|None = None, *,
        ssl: Any = None, family: int = 0, proto: int = 0,
        flags: int = 0, sock: Any = None,
        local_addr: tuple[str, int]|None = None,
        server_hostname: str|None = None,
        ssl_handshake_timeout: float|None = None,
        ssl_shutdown_timeout: float|None = None,
        happy_eyeballs_delay: float|None = None,
        interleave: int|None = None,
        all_errors: bool = False,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        if ssl is not None:
            return await self._create_ssl_connection(
                protocol_factory, host, port, ssl=ssl,
                family=family, proto=proto, flags=flags, sock=sock,
                local_addr=local_addr, server_hostname=server_hostname,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout,
                happy_eyeballs_delay=happy_eyeballs_delay,
                interleave=interleave, all_errors=all_errors,
            )
        # Only pass non-None/non-default kwargs
        kwargs = {}
        if ssl is not None:
            kwargs["ssl"] = ssl
        if family:
            kwargs["family"] = family
        if proto:
            kwargs["proto"] = proto
        if sock is not None:
            kwargs["sock"] = sock
        if local_addr is not None:
            kwargs["local_addr"] = local_addr
        if server_hostname is not None:
            kwargs["server_hostname"] = server_hostname
        if ssl_handshake_timeout is not None:
            kwargs["ssl_handshake_timeout"] = ssl_handshake_timeout
        if ssl_shutdown_timeout is not None:
            kwargs["ssl_shutdown_timeout"] = ssl_shutdown_timeout
        if happy_eyeballs_delay is not None:
            kwargs["happy_eyeballs_delay"] = happy_eyeballs_delay
        if interleave is not None:
            kwargs["interleave"] = interleave
        if all_errors:
            kwargs["all_errors"] = all_errors

        return await _Loop.create_connection(
            self, protocol_factory, host, port, **kwargs,
        )

    async def _create_ssl_connection(
        self, protocol_factory: Callable[[], asyncio.BaseProtocol],
        host: str|None, port: int|None, *,
        ssl: Any, family: int, proto: int, flags: int, sock: Any,
        local_addr: Any, server_hostname: str|None,
        ssl_handshake_timeout: float|None, ssl_shutdown_timeout: float|None,
        happy_eyeballs_delay: float|None, interleave: int|None,
        all_errors: bool,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        import ssl as ssl_module

        sslcontext = ssl
        sni = server_hostname or host

        incoming = ssl_module.MemoryBIO()
        outgoing = ssl_module.MemoryBIO()
        sslobj = sslcontext.wrap_bio(
            incoming, outgoing,
            server_side=False,
            server_hostname=sni,
        )

        waiter = self.create_future()
        app_protocol = protocol_factory()
        wrapper_holder: list[Any] = [None]

        class SP(asyncio.BufferedProtocol):
            def __init__(self):
                self._buf = bytearray(65536)
                self._view = memoryview(self._buf)
                self._hs = False
                self._sslobj = sslobj
                self._incoming = incoming
                self._outgoing = outgoing
            def get_buffer(self, n):
                return self._view[:n]
            def buffer_updated(self, n):
                self._incoming.write(self._buf[:n])
                if not self._hs: self._h()
                else: self._r()
            def connection_made(self, t):
                self._raw_t = t
                self._wrapper = _SSLTransportWrapper(self, t, ssl_module)
                wrapper_holder[0] = self._wrapper
                self._h()
            def connection_lost(self, e):
                pass
            def eof_received(self):
                return False
            def _h(self):
                try:
                    self._sslobj.do_handshake()
                except ssl_module.SSLWantReadError:
                    self._f()
                except ssl_module.SSLWantWriteError:
                    self._f()
                except Exception as exc:
                    if not waiter.done():
                        waiter.set_exception(exc)
                else:
                    self._hs = True
                    if not waiter.done():
                        waiter.set_result(None)
                    self._f()
                    app_protocol.connection_made(self._wrapper)
            def _r(self):
                while True:
                    try:
                        d = self._sslobj.read(65536)
                    except ssl_module.SSLWantReadError:
                        break
                    except (ssl_module.SSLSyscallError, ssl_module.SSLError):
                        break
                    if not d:
                        break
                    app_protocol.data_received(d)
            def _f(self):
                d = self._outgoing.read()
                if d:
                    self._raw_t.write(d)

        transport, _ = await _Loop.create_connection(
            self, SP, host, port,
        )

        try:
            await asyncio.wait_for(waiter, timeout=ssl_handshake_timeout or 60)
        except BaseException:
            transport.close()
            raise

        return wrapper_holder[0] or transport, app_protocol

    async def create_server(
        self, protocol_factory: Callable[[], asyncio.BaseProtocol],
        host: str|None = None, port: int|None = None, *,
        family: int = 0, flags: int = 0, sock: Any = None,
        backlog: int = 100, ssl: Any = None,
        reuse_address: bool|None = None, reuse_port: bool|None = None,
        ssl_handshake_timeout: float|None = None,
        ssl_shutdown_timeout: float|None = None,
        start_serving: bool = True,
    ) -> "Server":
        from .server import Server
        if ssl is not None:
            return await self._create_ssl_server(
                protocol_factory, host, port,
                family=family, flags=flags, sock=sock, backlog=backlog,
                ssl=ssl, reuse_address=reuse_address, reuse_port=reuse_port,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout,
                start_serving=start_serving,
            )
        kwargs = {}
        if family:
            kwargs["family"] = family
        if flags:
            kwargs["flags"] = flags
        if sock is not None:
            kwargs["sock"] = sock
        if reuse_address is not None:
            kwargs["reuse_address"] = reuse_address
        if reuse_port is not None:
            kwargs["reuse_port"] = reuse_port
        srvs = await _Loop.create_server(
            self, protocol_factory, host, port, backlog=backlog, **kwargs,
        )
        server = Server(self, srvs)
        for srv in srvs:
            if hasattr(srv, 'server_ref'):
                srv.server_ref = server
        return server

    async def _create_ssl_server(
        self, protocol_factory: Callable[[], asyncio.BaseProtocol],
        host: str|None, port: int|None, *,
        family: int, flags: int, sock: Any, backlog: int,
        ssl: Any, reuse_address: bool|None, reuse_port: bool|None,
        ssl_handshake_timeout: float|None, ssl_shutdown_timeout: float|None,
        start_serving: bool,
    ) -> "Server":
        from .server import Server
        import ssl as ssl_module

        sslcontext = ssl

        class SSP(asyncio.BufferedProtocol):
            def __init__(self):
                self._buf = bytearray(65536)
                self._view = memoryview(self._buf)
                self._hs = False
                incoming = ssl_module.MemoryBIO()
                outgoing = ssl_module.MemoryBIO()
                self._sslobj = sslcontext.wrap_bio(
                    incoming, outgoing,
                    server_side=True,
                )
                self._incoming = incoming
                self._outgoing = outgoing

            def get_buffer(self, n):
                return self._view[:n]
            def buffer_updated(self, n):
                self._incoming.write(self._buf[:n])
                if not self._hs: self._h()
                else: self._r()
            def connection_made(self, t):
                self._raw_t = t
                self._ap = protocol_factory()
                self._wrapper = _SSLTransportWrapper(self, self._raw_t, ssl_module)
                self._h()
            def connection_lost(self, e):
                self._ap.connection_lost(e)
            def eof_received(self):
                self._ap.eof_received()
                return False
            def _h(self):
                try:
                    self._sslobj.do_handshake()
                except ssl_module.SSLWantReadError:
                    self._f()
                except ssl_module.SSLWantWriteError:
                    self._f()
                except Exception:
                    self._raw_t.close()
                else:
                    self._hs = True
                    self._f()
                    self._ap.connection_made(self._wrapper)
            def _r(self):
                while True:
                    try:
                        d = self._sslobj.read(65536)
                    except ssl_module.SSLWantReadError:
                        break
                    except (ssl_module.SSLSyscallError, ssl_module.SSLError):
                        break
                    if not d:
                        break
                    self._ap.data_received(d)
            def _f(self):
                d = self._outgoing.read()
                if d:
                    self._raw_t.write(d)

        kwargs = {}
        if family:
            kwargs["family"] = family
        if flags:
            kwargs["flags"] = flags
        if sock is not None:
            kwargs["sock"] = sock
        if reuse_address is not None:
            kwargs["reuse_address"] = reuse_address
        if reuse_port is not None:
            kwargs["reuse_port"] = reuse_port
        srvs = await _Loop.create_server(
            self, SSP, host, port, backlog=backlog, **kwargs,
        )
        server = Server(self, srvs)
        for srv in srvs:
            if hasattr(srv, 'server_ref'):
                srv.server_ref = server
        return server

    async def create_unix_connection(
        self, protocol_factory: Callable[[], asyncio.BaseProtocol],
        path: str, *, ssl: Any = None,
        server_hostname: str|None = None,
        ssl_handshake_timeout: float|None = None,
        ssl_shutdown_timeout: float|None = None,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        if ssl is not None:
            return await self._create_ssl_unix_connection(
                protocol_factory, path, ssl=ssl,
                server_hostname=server_hostname,
            )
        return await _Loop.create_unix_connection(
            self, protocol_factory, path, ssl=ssl
        )

    async def _create_ssl_unix_connection(
        self, protocol_factory: Callable[[], asyncio.BaseProtocol],
        path: str, *, ssl: Any, server_hostname: str|None,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        import ssl as ssl_module

        sslcontext = ssl
        sni = server_hostname

        incoming = ssl_module.MemoryBIO()
        outgoing = ssl_module.MemoryBIO()
        sslobj = sslcontext.wrap_bio(
            incoming, outgoing,
            server_side=False,
            server_hostname=sni,
        )

        waiter = self.create_future()
        app_protocol = protocol_factory()
        wrapper_holder: list[Any] = [None]

        class SP(asyncio.BufferedProtocol):
            def __init__(self):
                self._buf = bytearray(65536)
                self._view = memoryview(self._buf)
                self._hs = False
                self._sslobj = sslobj
                self._incoming = incoming
                self._outgoing = outgoing
            def get_buffer(self, n):
                return self._view[:n]
            def buffer_updated(self, n):
                self._incoming.write(self._buf[:n])
                if not self._hs: self._h()
                else: self._r()
            def connection_made(self, t):
                self._raw_t = t
                self._wrapper = _SSLTransportWrapper(self, t, ssl_module)
                wrapper_holder[0] = self._wrapper
                self._h()
            def connection_lost(self, e):
                pass
            def eof_received(self):
                return False
            def _h(self):
                try:
                    self._sslobj.do_handshake()
                except ssl_module.SSLWantReadError:
                    self._f()
                except ssl_module.SSLWantWriteError:
                    self._f()
                except Exception as exc:
                    if not waiter.done():
                        waiter.set_exception(exc)
                else:
                    self._hs = True
                    if not waiter.done():
                        waiter.set_result(None)
                    self._f()
                    app_protocol.connection_made(self._wrapper)
            def _r(self):
                while True:
                    try:
                        d = self._sslobj.read(65536)
                    except ssl_module.SSLWantReadError:
                        break
                    except (ssl_module.SSLSyscallError, ssl_module.SSLError):
                        break
                    if not d:
                        break
                    app_protocol.data_received(d)
            def _f(self):
                d = self._outgoing.read()
                if d:
                    self._raw_t.write(d)

        transport, _ = await _Loop.create_unix_connection(
            self, SP, path,
        )

        try:
            await asyncio.wait_for(waiter, timeout=60)
        except BaseException:
            transport.close()
            raise

        return wrapper_holder[0] or transport, app_protocol

    async def create_unix_server(
        self, protocol_factory: Callable[[], asyncio.BaseProtocol],
        path: str, *, backlog: int = 100, ssl: Any = None,
        ssl_handshake_timeout: float|None = None,
        ssl_shutdown_timeout: float|None = None,
        start_serving: bool = True,
    ) -> "Server":
        from .server import Server
        if ssl is not None:
            return await self._create_ssl_unix_server(
                protocol_factory, path, backlog=backlog, ssl=ssl,
            )
        srv = await _Loop.create_unix_server(
            self, protocol_factory, path, backlog=backlog,
        )
        server = Server(self, [srv])
        if hasattr(srv, 'server_ref'):
            srv.server_ref = server
        return server

    async def _create_ssl_unix_server(
        self, protocol_factory: Callable[[], asyncio.BaseProtocol],
        path: str, *, backlog: int, ssl: Any,
    ) -> "Server":
        from .server import Server
        import ssl as ssl_module

        sslcontext = ssl

        class SSP(asyncio.BufferedProtocol):
            def __init__(self):
                self._buf = bytearray(65536)
                self._view = memoryview(self._buf)
                self._hs = False
                incoming = ssl_module.MemoryBIO()
                outgoing = ssl_module.MemoryBIO()
                self._sslobj = sslcontext.wrap_bio(
                    incoming, outgoing,
                    server_side=True,
                )
                self._incoming = incoming
                self._outgoing = outgoing

            def get_buffer(self, n):
                return self._view[:n]
            def buffer_updated(self, n):
                self._incoming.write(self._buf[:n])
                if not self._hs: self._h()
                else: self._r()
            def connection_made(self, t):
                self._raw_t = t
                self._ap = protocol_factory()
                self._wrapper = _SSLTransportWrapper(self, self._raw_t, ssl_module)
                self._h()
            def connection_lost(self, e):
                self._ap.connection_lost(e)
            def eof_received(self):
                self._ap.eof_received()
                return False
            def _h(self):
                try:
                    self._sslobj.do_handshake()
                except ssl_module.SSLWantReadError:
                    self._f()
                except ssl_module.SSLWantWriteError:
                    self._f()
                except Exception:
                    self._raw_t.close()
                else:
                    self._hs = True
                    self._f()
                    self._ap.connection_made(self._wrapper)
            def _r(self):
                while True:
                    try:
                        d = self._sslobj.read(65536)
                    except ssl_module.SSLWantReadError:
                        break
                    except (ssl_module.SSLSyscallError, ssl_module.SSLError):
                        break
                    if not d:
                        break
                    self._ap.data_received(d)
            def _f(self):
                d = self._outgoing.read()
                if d:
                    self._raw_t.write(d)

        srv = await _Loop.create_unix_server(
            self, SSP, path, backlog=backlog,
        )
        server = Server(self, [srv])
        if hasattr(srv, 'server_ref'):
            srv.server_ref = server
        return server

    async def subprocess_exec(
        self, protocol_factory: Callable[[], asyncio.BaseProtocol],
        args: Any, *, stdin: Any = None, stdout: Any = None,
        stderr: Any = None, cwd: str|None = None,
        env: dict[str, str]|None = None, pass_fds: Any = None,
        **kwargs: Any,
    ) -> tuple[Any, Any]:
        import subprocess
        popen = subprocess.Popen(
            args, stdin=subprocess.DEVNULL if stdin is None else stdin,
            stdout=subprocess.DEVNULL if stdout is None else stdout,
            stderr=subprocess.DEVNULL if stderr is None else stderr,
            cwd=cwd, env=env, pass_fds=pass_fds if pass_fds is not None else (),
        )
        _subprocess_popens[popen.pid] = popen
        try:
            return await _Loop.subprocess_exec(
                self, protocol_factory, pid=popen.pid,
            )
        except BaseException:
            if popen.poll() is None:
                popen.kill()
                popen.wait()
            _subprocess_popens.pop(popen.pid, None)
            raise
