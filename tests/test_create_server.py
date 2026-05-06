from leviathan import Loop
import leviathan

import asyncio, socket, pytest
from typing import Any


class EchoProtocol(asyncio.Protocol):
    def connection_made(self, transport: asyncio.Transport) -> None:
        self.transport = transport

    def data_received(self, data: bytes) -> None:
        self.transport.write(data)

    def connection_lost(self, exc: BaseException | None) -> None:
        pass


def test_create_server_basic() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
        assert server.is_serving()
        sock = server.sockets[0]
        port = sock.getsockname()[1]
        assert port > 0
        server.close()
        await server.wait_closed()

    leviathan.run(main())


def test_create_server_bind_any() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "0.0.0.0", 0)
        assert server.is_serving()
        server.close()

    leviathan.run(main())


def test_create_server_close() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
        server.close()
        assert not server.is_serving()

    leviathan.run(main())


def test_create_server_sockets_property() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
        sockets = server.sockets
        assert len(sockets) == 1
        assert isinstance(sockets[0], socket.socket)
        server.close()

    leviathan.run(main())


def test_create_server_invalid_protocol_factory() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises((TypeError, ValueError)):
            await loop.create_server(None, "127.0.0.1", 0)

    leviathan.run(main())


def test_create_server_get_loop() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
        assert server.get_loop() is loop
        server.close()

    leviathan.run(main())
