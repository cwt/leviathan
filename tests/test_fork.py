import asyncio
import os
import pytest
import leviathan
import time

def test_fork_safety():
    loop = leviathan.Loop()
    asyncio.set_event_loop(loop)
    
    async def main():
        # Do some IO
        reader, writer = await asyncio.open_connection('google.com', 80)
        writer.close()
        await writer.wait_closed()
        
        pid = os.fork()
        if pid == 0:
            # Child
            try:
                try:
                    loop.is_closed()
                    os._exit(1) # Should have raised RuntimeError
                except RuntimeError as e:
                    if "fork" in str(e).lower():
                        os._exit(0) # Success
                    else:
                        print(f"Wrong RuntimeError: {e}")
                        os._exit(2)
                except Exception as e:
                    print(f"Wrong exception type: {type(e)}: {e}")
                    os._exit(3)
                os._exit(4)
            except BaseException:
                os._exit(5)
        else:
            # Parent
            _, status = os.waitpid(pid, 0)
            assert os.WIFEXITED(status)
            assert os.WEXITSTATUS(status) == 0
            
            # Parent should still be functional
            await asyncio.sleep(0.1)
            loop.stop()

    loop.run_until_complete(main())
    loop.close()
