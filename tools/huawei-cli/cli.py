"""Command line for the Huawei watch from a PC.

  python cli.py scan
  python cli.py pair  <address>                 # first time: confirm on the watch
  python cli.py info  <address>
  python cli.py sleep <address> --from 2026-11-15T02:00 --to 2026-11-15T12:00 [--out DIR] [--file data|state]
  python cli.py probe <address>                 # asks sleep_data for several ranges, logs what comes back

Times are local time of this PC unless they end with Z. Only one phone/PC can be connected to the watch:
switch off Bluetooth on the iPhone (or close HuaSideload) first.
"""
import argparse
import asyncio
import datetime as dt
import struct
import sys
from pathlib import Path

from huawei import TLV, Watch, be32, find_watch, log

FILES = {"state": ("sleep_state.bin", 0x0E), "data": ("sleep_data.bin", 0x0F)}


def ts(text):
    d = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if d.tzinfo is None:
        d = d.astimezone()
    return int(d.timestamp())


def acc_range(raw):
    """First/last accelerometer timestamp in sleep_data.bin (tag 1, 1-byte length, LE time)."""
    i, first, last = 0, None, None
    while i < len(raw):
        tag = raw[i]; i += 1
        if tag == 1 and i < len(raw):
            n = raw[i]; i += 1
            if n >= 4 and i + n <= len(raw):
                t = struct.unpack("<I", raw[i:i + 4])[0]
                first = first or t; last = t
            i += n
        elif tag == 2 and i + 1 < len(raw):
            n = raw[i] | raw[i + 1] << 8; i += 2 + n
    return first, last


def fmt(t):
    return dt.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M") if t else "-"


class FileDownload:
    """New-sync (service 0x2C) file download with detailed logging."""

    def __init__(self, watch: Watch):
        self.w = watch
        self.buf = bytearray()
        self.event = asyncio.Event()
        self.packets = 0

    def on_packet(self, p):
        if p.service != 0x2C or p.command != 0x05:
            log("unsolicited", p)
            return
        raw = self.w.decrypt_raw(p.body) or p.body
        if len(raw) < 6:
            return
        offset = struct.unpack(">I", raw[1:5])[0]
        data = raw[6:]
        self.packets += 1
        if offset == len(self.buf):
            self.buf += data
        elif offset < len(self.buf):
            self.buf[offset:offset + len(data)] = data
        else:
            log(f"gap: have {len(self.buf)}, packet at {offset}")
        self.event.set()

    async def get(self, name, ftype, start, end):
        w = self.w
        w.on_unsolicited = self.on_packet
        init = TLV().add(0x01, name.encode()).add(0x02, bytes([ftype])).add(0x05, be32(start)).add(0x06, be32(end))
        r = (await w.request(0x2C, 0x01, init)).tlv
        file_id, size = r.get(0x03)[0], r.int(0x04) or 0
        log(f"init {name} {fmt(start)}..{fmt(end)} -> id {file_id}, {size} bytes  (raw: {r})")
        if size == 0:
            await w.send(0x2C, 0x06, TLV().add(0x01, bytes([file_id])).add(0x02, b"\x01"))
            return b""
        info = (await w.request(0x2C, 0x03, TLV().add(0x01, bytes([file_id])).add(2).add(3).add(4).add(5))).tlv
        max_block = max(info.int(0x04) or 0, 1024)
        idle = max(info.int(0x02) or 0, 10)
        no_encrypt = (info.get(0x05) or b"\0")[0] != 0
        log(f"info: {info}  -> block {max_block}, idle {idle}s, encrypted {not no_encrypt}")
        self.buf = bytearray()
        retries = 0
        try:
            while len(self.buf) < size:
                offset = len(self.buf)
                block = min(max_block, size - offset)
                target = offset + block
                await w.send(0x2C, 0x04, TLV().add(0x01, bytes([file_id])).add(0x02, be32(offset)).add(0x03, be32(block)),
                             encrypted=not no_encrypt)
                last = len(self.buf)
                while len(self.buf) < target:
                    self.event.clear()
                    try:
                        await asyncio.wait_for(self.event.wait(), idle)
                    except asyncio.TimeoutError:
                        break
                if len(self.buf) >= target:
                    retries = 0
                else:
                    retries += 1
                    log(f"quiet at {len(self.buf)}/{size} (block from {offset}, got {len(self.buf) - last}), retry {retries}")
                    if retries > 5:
                        raise TimeoutError("file transfer stalled")
            log(f"done: {len(self.buf)} bytes in {self.packets} packets")
        finally:
            await w.send(0x2C, 0x06, TLV().add(0x01, bytes([file_id])).add(0x02, b"\x01"))
            w.on_unsolicited = None
        return bytes(self.buf[:size])


async def session(address, verbose, br):
    w = Watch(address, verbose)
    if br:
        await w.connect_br(w.state.get("brChannel"))
    else:
        await w.connect()
    await w.pair()
    return w


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["scan", "pair", "info", "sleep", "probe"])
    ap.add_argument("address", nargs="?")
    ap.add_argument("--from", dest="start")
    ap.add_argument("--to", dest="end")
    ap.add_argument("--file", default="data", choices=list(FILES))
    ap.add_argument("--out", default=str(Path.home() / "Desktop" / "Entwicklung" / "sleep-export" / "pc"))
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--ble", action="store_true", help="use Bluetooth LE instead of classic Bluetooth (RFCOMM)")
    a = ap.parse_args()

    if a.cmd == "scan":
        await find_watch()
        return
    if not a.address:
        sys.exit("address missing (python cli.py scan)")
    w = await session(a.address, a.verbose, br=not a.ble)
    try:
        if a.cmd == "info":
            log(await w.product_info())
        elif a.cmd == "sleep":
            name, ftype = FILES[a.file]
            start, end = ts(a.start), ts(a.end)
            raw = await FileDownload(w).get(name, ftype, start, end)
            out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
            path = out / f"{name.split('.')[0]}_{dt.datetime.fromtimestamp(start):%Y-%m-%dT%H%M}.bin"
            path.write_bytes(raw)
            if a.file == "data":
                f, l = acc_range(raw)
                log(f"saved {path} ({len(raw)} bytes), data covers {fmt(f)} .. {fmt(l)}")
            else:
                recs = [struct.unpack("<II", raw[i:i + 8]) for i in range(0, len(raw) - 15, 16)]
                log(f"saved {path}: " + ", ".join(f"{fmt(s)}–{fmt(e)}" for s, e in recs))
        elif a.cmd == "probe":
            now = int(dt.datetime.now().timestamp())
            for days_back in range(0, 8):
                end = now - days_back * 86400
                start = end - 86400
                raw = await FileDownload(w).get("sleep_data.bin", 0x0F, start, end)
                f, l = acc_range(raw)
                log(f"PROBE asked {fmt(start)}..{fmt(end)} -> {len(raw)} bytes, covers {fmt(f)}..{fmt(l)}")
                await asyncio.sleep(1)
    finally:
        await w.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
