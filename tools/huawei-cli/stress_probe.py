"""Read-only search for stress data (not in Gadgetbridge for this watch).
1. file sync 0x2C: which file types exist besides sleep (0x0E/0x0F) and GPS (0x11)
2. FitnessData 0x07: unknown command ids, asked like a record count (time range); known setters are skipped.
Usage: py stress_probe.py relay:IP [--token T] [--part files|fitness|all]"""
import argparse
import asyncio
import time

from cli import session
from huawei import TLV, be32, log

KNOWN_SETTERS = {0x01, 0x02, 0x07, 0x0E, 0x16, 0x17, 0x23, 0x24, 0x28, 0x29, 0x2A}
KNOWN_GETTERS = {0x03, 0x0A, 0x0B, 0x0C, 0x0D}


async def files(w, start, end):
    for ftype in range(0x00, 0x31):
        if ftype in (0x0E, 0x0F, 0x11):
            continue
        tlv = TLV().add(0x01, b"stress_data.bin").add(0x02, bytes([ftype])).add(0x05, be32(start)).add(0x06, be32(end))
        try:
            r = (await w.request(0x2C, 0x01, tlv, timeout=4)).tlv
        except Exception as e:  # noqa: BLE001
            log(f"file type {ftype:#04x}: {e}")
            continue
        log(f"file type {ftype:#04x}: {r}")
        fid = r.get(0x03)
        if fid:
            await w.send(0x2C, 0x06, TLV().add(0x01, fid).add(0x02, b"\x01"))
        await asyncio.sleep(0.3)


async def fitness(w, start, end):
    for cmd in range(0x04, 0x41):
        if cmd in KNOWN_SETTERS or cmd in KNOWN_GETTERS:
            continue
        tlv = TLV().add(0x81, TLV().add(0x03, be32(start)).add(0x04, be32(end)).serialize())
        try:
            r = (await w.request(0x07, cmd, tlv, timeout=3)).tlv
            log(f"fitness {cmd:#04x}: {r}")
        except Exception as e:  # noqa: BLE001
            log(f"fitness {cmd:#04x}: {e}")


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("address")
    ap.add_argument("--token")
    ap.add_argument("--part", default="files", choices=["files", "fitness", "all"])
    a = ap.parse_args()
    w = await session(a.address, False, token=a.token)
    end = int(time.time()); start = end - 3 * 86400
    try:
        if a.part in ("files", "all"):
            await files(w, start, end)
        if a.part in ("fitness", "all"):
            await fitness(w, start, end)
    finally:
        await w.disconnect()

asyncio.run(main())
