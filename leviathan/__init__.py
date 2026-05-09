from .future import Future
from .task import Task
from .loop import Loop, EventLoopPolicy
from .runner import run

from .leviathan_zig import StreamTransport

def install():
    import asyncio
    asyncio.set_event_loop_policy(EventLoopPolicy())
