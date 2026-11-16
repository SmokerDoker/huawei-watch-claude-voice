"""Workouts through the watch (or the phone relay): count, totals, per-sample data and pace (Gadgetbridge Workout.java).
Usage: py workouts.py relay:IP [--days 30] [--token T]  -> prints a summary, writes JSON to --out."""
import argparse
import asyncio
import json
import struct
import time
from pathlib import Path

from cli import fmt, session
from huawei import TLV, be16, be32, log

BITMAP = [1, 2, 1, 2, 2, 4, -1, 2, 2, 2]                  # hr, speed, stepRate, swolf, strokeRate, altitude, inner, calories, frequency, power
INNER = [2, 2, 2, 1, 2, 1, 1, 1, 1, 2, 2, 1, 2, 2, 2, 2, 1, 1, 1, 2]
NAMES = ["hr", "speed", "stepRate", "swolf", "strokeRate", "altitude", None, "calories", "frequency", "power"]
INNER_NAMES = ["cadence", "stepLength", "groundContact", "impact", "swingAngle", "foreFoot", "midFoot", "backFoot", "eversion"]


def parse_data(c: TLV):
    header, raw = c.get(0x04), c.get(0x05) or b""
    inner = c.int(0x09) if c.get(0x09) else 0x01FF
    _, _, ts, interval, count, length, bitmap = struct.unpack(">HHIBHBH", header)
    out = []
    i = 0
    for n in range(count):
        d = {"t": ts + interval * n}
        for j, size in enumerate(BITMAP):
            if not bitmap & (1 << j):
                continue
            if j == 6:
                for k, s in enumerate(INNER):
                    if inner & (1 << k):
                        v = int.from_bytes(raw[i:i + s], "big", signed=True)
                        if k < len(INNER_NAMES):
                            d[INNER_NAMES[k]] = v
                        i += s
                continue
            v = int.from_bytes(raw[i:i + size], "big", signed=True)
            d[NAMES[j]] = v
            i += size
        out.append(d)
    return {"interval": interval, "bitmap": bitmap, "inner": inner, "length": length, "samples": out}


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("address")
    ap.add_argument("--token")
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--out", default=str(Path.home() / "Desktop" / "Entwicklung" / "workouts-export"))
    a = ap.parse_args()
    w = await session(a.address, False, token=a.token)
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    try:
        now = int(time.time())
        r = (await w.request(0x17, 0x07, TLV().add(0x81, TLV().add(0x03, be32(now - a.days * 86400)).add(0x04, be32(now)).serialize()))).tlv
        c = TLV.parse(r.get(0x81))
        items = [TLV.parse(x) for x in c.all(0x85)]
        log(f"{len(items)} workouts in {a.days} days")
        for it in items:
            num, dcount, pcount = it.int(0x06), it.int(0x07) or 0, it.int(0x08) or 0
            t = TLV.parse((await w.request(0x17, 0x08, TLV().add(0x81, TLV().add(0x02, be16(num)).serialize()))).tlv.get(0x81))
            start, end, wtype = t.int(0x04), t.int(0x05), t.int(0x14)
            log(f"#{num} type {wtype} {fmt(start)}..{fmt(end)} data pages {dcount}, pace {pcount}; totals: {t}")
            pages = []
            for d in range(dcount):
                p = await w.request(0x17, 0x0A, TLV().add(0x81, TLV().add(0x02, be16(num)).add(0x03, be16(d)).serialize()), timeout=15)
                pages.append(parse_data(TLV.parse(p.tlv.get(0x81))))
            samples = [s for pg in pages for s in pg["samples"]]
            hrs = [s["hr"] & 0xFF for s in samples if s.get("hr", -1) not in (-1, 0, 255)]
            if pages:
                log(f"   samples {len(samples)}, every {pages[0]['interval']} s, fields bitmap {pages[0]['bitmap']:#06x}"
                    + (f", HR {min(hrs)}-{max(hrs)} avg {sum(hrs) // len(hrs)}" if hrs else ""))
            paces = []
            for pn in range(pcount):
                p = await w.request(0x17, 0x0C, TLV().add(0x81, TLV().add(0x02, be16(num)).add(0x08, be16(pn)).serialize()))
                pc = TLV.parse(p.tlv.get(0x81))
                for b in pc.all(0x83):
                    b = TLV.parse(b)
                    paces.append({"distance": b.int(0x04), "type": b.int(0x05), "pace": b.int(0x06)})
            if paces:
                log("   pace: " + ", ".join(f"{x['distance']}{'km' if x['type'] == 0 else ''}:{x['pace'] // 60}:{x['pace'] % 60:02d}" for x in paces[:12]))
            (out / f"workout_{start}.json").write_text(json.dumps({"number": num, "type": wtype, "start": start, "end": end,
                                                                     "totals": {f"{k:02x}": v.hex() for k, v in t.items},
                                                                     "pages": pages, "pace": paces}))
    finally:
        await w.disconnect()

asyncio.run(main())
