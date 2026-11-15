"""Quick state check: fitness record counts, sleep_state file, totals today."""
import asyncio
import sys
import time

from cli import FileDownload, fmt, session
from huawei import TLV, be16, be32, log


async def main(address):
    w = await session(address, False, True)
    try:
        now = int(time.time())
        totals = (await w.request(0x07, 0x03, TLV().add(0x01))).tlv
        log("totals today:", totals)
        for name, cmd, hours in (("steps", 0x0A, 24 * 7), ("sleep", 0x0C, 24 * 7)):
            r = (await w.request(0x07, cmd, TLV().add(0x81).add(0x03, be32(now - hours * 3600)).add(0x04, be32(now)))).tlv
            log(f"{name} records (7 days):", r)
        for days in (3, 14):
            raw = await FileDownload(w).get("sleep_state.bin", 0x0E, now - days * 86400, now)
            import struct
            recs = [struct.unpack("<II", raw[i:i + 8]) for i in range(0, len(raw) - 15, 16)]
            log(f"sleep_state {days} days:", ", ".join(f"{fmt(s)}-{fmt(e)}" for s, e in recs) or "-")
    finally:
        await w.disconnect()

asyncio.run(main(sys.argv[1]))
