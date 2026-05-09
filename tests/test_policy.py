import asyncio
import leviathan
import pytest

def test_install():
    # Save original policy
    old_policy = asyncio.get_event_loop_policy()
    try:
        leviathan.install()
        policy = asyncio.get_event_loop_policy()
        assert isinstance(policy, leviathan.EventLoopPolicy)
        
        loop = asyncio.new_event_loop()
        try:
            assert isinstance(loop, leviathan.Loop)
        finally:
            loop.close()
    finally:
        asyncio.set_event_loop_policy(old_policy)

def test_policy_new_event_loop():
    policy = leviathan.EventLoopPolicy()
    loop = policy.new_event_loop()
    try:
        assert isinstance(loop, leviathan.Loop)
    finally:
        loop.close()
