import asyncio
import leviathan
import pytest
import socket

class DatagramProtocol(asyncio.DatagramProtocol):
    def __init__(self):
        self.on_con_made = asyncio.Future()
        self.on_con_lost = asyncio.Future()
        self.received = []

    def connection_made(self, transport):
        self.transport = transport
        self.on_con_made.set_result(True)

    def datagram_received(self, data, addr):
        self.received.append((data, addr))

    def connection_lost(self, exc):
        self.on_con_lost.set_result(exc)

@pytest.mark.asyncio
async def test_create_datagram_endpoint_ipv4():
    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_datagram_endpoint(
        DatagramProtocol,
        local_addr=('127.0.0.1', 0)
    )
    try:
        assert isinstance(transport, asyncio.DatagramTransport)
        assert protocol.on_con_made.done()
    finally:
        transport.close()

@pytest.mark.asyncio
async def test_create_datagram_endpoint_ipv6():
    loop = asyncio.get_running_loop()
    try:
        transport, protocol = await loop.create_datagram_endpoint(
            DatagramProtocol,
            local_addr=('::1', 0)
        )
    except OSError:
        pytest.skip("IPv6 not supported")
        
    try:
        assert isinstance(transport, asyncio.DatagramTransport)
        assert protocol.on_con_made.done()
    finally:
        transport.close()

@pytest.mark.asyncio
async def test_create_datagram_endpoint_dns():
    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_datagram_endpoint(
        DatagramProtocol,
        local_addr=('localhost', 0)
    )
    try:
        assert isinstance(transport, asyncio.DatagramTransport)
        assert protocol.on_con_made.done()
    finally:
        transport.close()

@pytest.mark.asyncio
async def test_create_datagram_endpoint_remote():
    loop = asyncio.get_running_loop()
    # First create a server to listen
    t1, p1 = await loop.create_datagram_endpoint(
        DatagramProtocol,
        local_addr=('127.0.0.1', 0)
    )
    addr = t1.get_extra_info('sockname')
    
    # Create client connected to server
    t2, p2 = await loop.create_datagram_endpoint(
        DatagramProtocol,
        remote_addr=addr
    )
    
    try:
        msg = b'hello'
        t2.sendto(msg)
        
        # Wait for data
        for _ in range(10):
            if p1.received:
                break
            await asyncio.sleep(0.1)
            
        assert len(p1.received) == 1
        data, src = p1.received[0]
        assert data == msg
        # src should be t2's sockname
        # Note: If it's localhost, it might be 127.0.0.1
        t2_addr = t2.get_extra_info('sockname')
        assert src[1] == t2_addr[1] # Compare port
        if src[0] == '127.0.0.1' or src[0] == '::1' or src[0] == 'localhost':
             pass # OK
    finally:
        t1.close()
        t2.close()
