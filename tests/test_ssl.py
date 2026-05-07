import pytest
import ssl
import subprocess
import tempfile
import os

import leviathan
import asyncio

pytestmark = pytest.mark.filterwarnings("ignore::DeprecationWarning")


@pytest.fixture(scope="module")
def ssl_certs():
    keyf = tempfile.NamedTemporaryFile(suffix=".key", delete=False)
    certf = tempfile.NamedTemporaryFile(suffix=".crt", delete=False)
    keyf.close()
    certf.close()
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyf.name, "-out", certf.name,
            "-days", "1", "-nodes", "-subj", "/CN=localhost",
        ],
        capture_output=True,
        check=True,
    )
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=certf.name, keyfile=keyf.name)
    yield ctx, keyf.name, certf.name
    os.unlink(keyf.name)
    os.unlink(certf.name)


class EchoClient(asyncio.Protocol):
    def __init__(self):
        self.data_future = asyncio.get_running_loop().create_future()
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        if not self.data_future.done():
            self.data_future.set_result(data)

    def connection_lost(self, exc):
        pass


@pytest.mark.asyncio
async def test_ssl_create_connection_handshake(ssl_certs):
    server_ctx, key_path, cert_path = ssl_certs

    # Use threading raw SSL server (blocking)
    import socket
    import threading

    server_sock = socket.socket()
    server_sock.bind(("127.0.0.1", 0))
    server_sock.listen(1)
    addr = server_sock.getsockname()

    result_data = []

    def server_thread():
        try:
            conn, _ = server_sock.accept()
            sconn = server_ctx.wrap_socket(conn, server_side=True)
            data = sconn.recv(1024)
            sconn.sendall(data)
            sconn.close()
            server_sock.close()
            result_data.append(data)
        except Exception as e:
            result_data.append(e)

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()

    await asyncio.sleep(0.1)

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_connection(
        EchoClient, addr[0], addr[1], ssl=client_ctx,
    )

    transport.write(b"hello")
    data = await protocol.data_future
    assert data == b"hello"
    transport.close()

    t.join(timeout=5)


@pytest.mark.asyncio
async def test_ssl_create_connection_server_hostname(ssl_certs):
    server_ctx, key_path, cert_path = ssl_certs

    import socket
    import threading

    server_sock = socket.socket()
    server_sock.bind(("127.0.0.1", 0))
    server_sock.listen(1)
    addr = server_sock.getsockname()

    def server_thread():
        conn, _ = server_sock.accept()
        sconn = server_ctx.wrap_socket(conn, server_side=True)
        data = sconn.recv(1024)
        sconn.sendall(data)
        sconn.close()
        server_sock.close()

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()
    await asyncio.sleep(0.1)

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_connection(
        EchoClient, addr[0], addr[1],
        ssl=client_ctx, server_hostname="localhost",
    )

    transport.write(b"hello")
    data = await protocol.data_future
    assert data == b"hello"
    transport.close()

    t.join(timeout=5)


@pytest.mark.asyncio
async def test_ssl_create_connection_echo_large(ssl_certs):
    server_ctx, key_path, cert_path = ssl_certs

    import socket
    import threading

    server_sock = socket.socket()
    server_sock.bind(("127.0.0.1", 0))
    server_sock.listen(1)
    addr = server_sock.getsockname()

    def server_thread():
        conn, _ = server_sock.accept()
        sconn = server_ctx.wrap_socket(conn, server_side=True)
        total = b""
        while True:
            chunk = sconn.recv(4096)
            if not chunk:
                break
            sconn.sendall(chunk)
            total += chunk
            if len(total) >= 10000:
                break
        sconn.close()
        server_sock.close()

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()
    await asyncio.sleep(0.1)

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_connection(
        EchoClient, addr[0], addr[1], ssl=client_ctx,
    )

    data = b"x" * 10000
    transport.write(data)
    received = b""
    while len(received) < len(data):
        chunk = await protocol.data_future
        received += chunk
        if len(received) < len(data):
            protocol.data_future = loop.create_future()

    assert received == data
    transport.close()

    t.join(timeout=5)


@pytest.mark.asyncio
async def test_ssl_create_connection_wrong_context():
    """SSL connection to plain TCP server should fail cleanly"""
    import socket
    import threading

    server_sock = socket.socket()
    server_sock.bind(("127.0.0.1", 0))
    server_sock.listen(1)
    addr = server_sock.getsockname()

    def server_thread():
        conn, _ = server_sock.accept()
        conn.recv(1024)  # consume ClientHello
        conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n")  # not SSL
        conn.close()
        server_sock.close()

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()
    await asyncio.sleep(0.1)

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    loop = asyncio.get_running_loop()

    with pytest.raises((ConnectionError, ssl.SSLError)):
        transport, protocol = await loop.create_connection(
            EchoClient, addr[0], addr[1], ssl=client_ctx,
        )
        transport.close()

    t.join(timeout=5)
