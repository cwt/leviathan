import asyncio
import leviathan
import pytest

import warnings

def test_install():
    # Save original policy
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        old_policy = asyncio.get_event_loop_policy()
    try:
        leviathan.install()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            policy = asyncio.get_event_loop_policy()
        assert isinstance(policy, leviathan.EventLoopPolicy)
        
        loop = asyncio.new_event_loop()
        try:
            assert isinstance(loop, leviathan.Loop)
        finally:
            loop.close()
    finally:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            asyncio.set_event_loop_policy(old_policy)

def test_policy_new_event_loop():
    policy = leviathan.EventLoopPolicy()
    loop = policy.new_event_loop()
    try:
        assert isinstance(loop, leviathan.Loop)
    finally:
        loop.close()
