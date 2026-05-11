from leviathan import Task, Loop

from unittest.mock import AsyncMock

import pytest, asyncio


def test_task_eager_start_raises() -> None:
    loop = Loop()
    coro = AsyncMock()()
    try:
        with pytest.raises(RuntimeError, match="eager_start"):
            Task(coro, loop=loop, eager_start=True)
    finally:
        coro.close()
        loop.close()


def test_task_without_loop_inside_running_loop() -> None:
    loop = Loop()
    try:
        async def test():
            coro2 = AsyncMock()()
            task = Task(coro2)
            assert isinstance(task.get_loop(), Loop)
            coro2.close()
            return True

        assert loop.run_until_complete(test())
    finally:
        loop.close()
