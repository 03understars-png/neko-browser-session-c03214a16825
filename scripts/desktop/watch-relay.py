
from __future__ import annotations

import asyncio
import sys

LISTEN = int(sys.argv[1]) if len(sys.argv) > 1 else 8091
VIEWER = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
PASS_CHANNELS = {1, 26}
IDR_REQUEST = bytes([2, 0])


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def browser_frames(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    dropping = False
    try:
        while True:
            head = await reader.readexactly(2)
            opcode, length = head[0] & 0x0F, head[1] & 0x7F
            extended = b""
            if length == 126:
                extended = await reader.readexactly(2)
                length = int.from_bytes(extended, "big")
            elif length == 127:
                extended = await reader.readexactly(8)
                length = int.from_bytes(extended, "big")
            mask = await reader.readexactly(4) if head[1] & 0x80 else b""
            payload = await reader.readexactly(length)
            frame = head + extended + mask + payload
            if opcode >= 0x8:
                writer.write(frame)
                await writer.drain()
                continue
            if opcode in (0x1, 0x2):
                clear = bytes(b ^ mask[i % 4] for i, b in enumerate(payload[:512])) if mask else payload[:512]
                if opcode == 0x2:
                    dropping = not (clear and (clear[0] in PASS_CHANNELS or clear == IDR_REQUEST))
                else:
                    dropping = b"webrtc" in clear.lower()
            if not dropping:
                writer.write(frame)
                await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
    try:
        viewer_reader, viewer_writer = await asyncio.open_connection("127.0.0.1", VIEWER)
    except OSError:
        client_writer.close()
        return
    head = await client_reader.readuntil(b"\r\n\r\n")
    viewer_writer.write(head)
    await viewer_writer.drain()
    upgrade = b"upgrade: websocket" in head.lower()
    upstream = browser_frames(client_reader, viewer_writer) if upgrade else pipe(client_reader, viewer_writer)
    await asyncio.gather(upstream, pipe(viewer_reader, client_writer))


async def main() -> None:
    server = await asyncio.start_server(handle, "127.0.0.1", LISTEN)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
