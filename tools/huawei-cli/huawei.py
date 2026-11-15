"""Huawei watch protocol over BLE, for a PC (Windows/macOS/Linux via bleak).

Port of HuaSideload's Swift code (itself ported from Gadgetbridge, AGPL-3.0):
framing (HuaweiPacket/TLV), AES-CBC/GCM, pairing with HiChain, requests and file download.
"""
import asyncio
import hashlib
import hmac as hmaclib
import json
import os
import struct
import time
from pathlib import Path

from bleak import BleakClient, BleakScanner
from cryptography.hazmat.primitives import hashes, padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

SERVICE = "0000fe86-0000-1000-8000-00805f9b34fb"
WRITE = "0000fe01-0000-1000-8000-00805f9b34fb"
NOTIFY = "0000fe02-0000-1000-8000-00805f9b34fb"
RESULT_SUCCESS = 0x186A0
NON_TLV = {(0x0A, 0x05), (0x28, 0x06), (0x2C, 0x05), (0x1C, 0x05)}
STATE = Path(os.environ.get("APPDATA", Path.home())) / "huawei-cli" / "state.json"


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ---------------------------------------------------------------- framing

def crc16(data: bytes) -> int:
    crc = 0
    for b in data:
        crc = ((crc >> 8) | (crc << 8)) & 0xFFFF
        crc ^= b
        crc ^= (crc & 0xFF) >> 4
        crc ^= (crc << 12) & 0xFFFF
        crc ^= ((crc & 0xFF) << 5) & 0xFFFF
    return crc & 0xFFFF


def varint(v: int) -> bytes:
    out = [v & 0x7F]
    v >>= 7
    while v:
        out.insert(0, (v & 0x7F) | 0x80)
        v >>= 7
    return bytes(out)


class TLV:
    def __init__(self, items=None):
        self.items = list(items or [])

    def add(self, tag, value=b""):
        if isinstance(value, int):
            raise TypeError("use bytes")
        self.items.append((tag, bytes(value)))
        return self

    def serialize(self) -> bytes:
        return b"".join(bytes([t]) + varint(len(v)) + v for t, v in self.items)

    @classmethod
    def parse(cls, data: bytes):
        t, i = cls(), 0
        while i < len(data):
            tag = data[i]; i += 1
            if i == len(data) and tag == 0:
                break
            size = 0
            while True:
                if i >= len(data):
                    raise ValueError("bad TLV")
                b = data[i]; i += 1
                size += b & 0x7F
                if not b & 0x80:
                    break
                size <<= 7
            if size > len(data) - i:
                raise ValueError("bad TLV")
            t.items.append((tag, data[i:i + size])); i += size
        return t

    def get(self, tag):
        return next((v for t, v in self.items if t == tag), None)

    def all(self, tag):
        return [v for t, v in self.items if t == tag]

    def int(self, tag):
        v = self.get(tag)
        return int.from_bytes(v, "big") if v and len(v) <= 8 else None

    def obj(self, tag):
        v = self.get(tag)
        try:
            return TLV.parse(v) if v is not None else None
        except ValueError:
            return None

    def __repr__(self):
        return " ".join(f"{t:02X}={v.hex() or '-'}" for t, v in self.items)


def be32(v): return struct.pack(">I", v & 0xFFFFFFFF)
def be16(v): return struct.pack(">H", v & 0xFFFF)


def serialize(service, command, body: bytes) -> bytes:
    frame = bytes([0x5A]) + be16(2 + len(body) + 1) + bytes([0, service, command]) + body
    return frame + be16(crc16(frame))


def serialize_sliced(service, command, body: bytes, slice_size: int):
    max_body = slice_size - 7
    count = (len(body) + 2 + max_body - 1) // max_body
    if count <= 1:
        return [serialize(service, command, body)]
    frames, offset, sl, flag = [], 0, 1, 0
    for i in range(count):
        packet = min(slice_size, len(body) - offset + 7)
        content = packet - 7
        if i == count - 1:
            sl = 3
        frame = bytes([0x5A]) + be16(packet - 5) + bytes([sl, flag & 0xFF])
        flag += 1
        if sl == 1:
            frame += bytes([service, command]); sl = 2; content -= 2
        frame += body[offset:offset + content]; offset += content
        frames.append(frame + be16(crc16(frame)))
    return frames


class Packet:
    def __init__(self, service, command, body):
        self.service, self.command, self.body = service, command, body
        self.tlv = None
        if (service, command) not in NON_TLV:
            try:
                self.tlv = TLV.parse(body)
            except ValueError:
                pass

    def __repr__(self):
        return f"{self.service:02X}/{self.command:02X} {self.tlv if self.tlv else self.body[:40].hex()}"


class Parser:
    def __init__(self):
        self.pending, self.slices = b"", b""

    def feed(self, data):
        self.pending += data
        out = []
        while self.pending:
            if self.pending[0] != 0x5A:
                log("bad magic, reset"); self.pending = self.slices = b""; break
            if len(self.pending) < 3:
                break
            exp = self.pending[1] << 8 | self.pending[2]
            n = 3 + exp + 2
            if len(self.pending) < n:
                break
            frame, self.pending = self.pending[:n], self.pending[n:]
            sliced = frame[3] in (1, 2, 3)
            if crc16(frame[:3 + exp]) != (frame[3 + exp] << 8 | frame[4 + exp]):
                log("bad CRC"); self.slices = b""; continue
            payload = frame[3 + (2 if sliced else 1):3 + exp]
            if sliced:
                self.slices += payload
                if frame[3] != 3:
                    continue
                payload, self.slices = self.slices, b""
            if len(payload) >= 2:
                out.append(Packet(payload[0], payload[1], payload[2:]))
        return out


# ---------------------------------------------------------------- crypto

def hmac(key, msg): return hmaclib.new(key, msg, hashlib.sha256).digest()
def sha256(d): return hashlib.sha256(d).digest()


def hkdf(ikm, salt, info, n):
    return HKDF(hashes.SHA256(), n, salt, info.encode()).derive(ikm)


def gcm_seal(plain, key, nonce, aad=b""): return AESGCM(key).encrypt(nonce, plain, aad or None)
def gcm_open(data, key, nonce, aad=b""): return AESGCM(key).decrypt(nonce, data, aad or None)


def cbc_encrypt(data, key, iv):
    p = padding.PKCS7(128).padder(); d = p.update(data) + p.finalize()
    e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return e.update(d) + e.finalize()


def cbc_decrypt(data, key, iv):
    d = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    out = d.update(data) + d.finalize()
    u = padding.PKCS7(128).unpadder()
    return u.update(out) + u.finalize()


DIGEST = {1: bytes.fromhex("70FB6C24035FDB552F38898AEEDE3F69"), 4: bytes.fromhex("70FB6C24035FDB552F38898AEEDE3F69"),
          2: bytes.fromhex("93ACDEF76ACB09857DBFE5261AABCD78")}
DIGEST_V3 = bytes.fromhex("9C2763A9CCE134766DE3FF6118200553")
GROUP_ID = "7B0BC0CBCE474F6C238D9661C63400B797B166EA7849B3A370FC73A9A236E989"


# ---------------------------------------------------------------- state

def load_state():
    try:
        return json.loads(STATE.read_text())
    except FileNotFoundError:
        return {}


def save_state(s):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(s, indent=2))


# ---------------------------------------------------------------- session

class Watch:
    def __init__(self, address, verbose=False):
        self.address, self.verbose = address, verbose
        self.client = None
        self.parser = Parser()
        self.waiters = []            # (service, command, future)
        self.on_unsolicited = None   # callback(packet)
        self.session_key = None
        self.link = {}
        self.state = load_state()
        if "deviceId" not in self.state:
            self.state["deviceId"] = os.urandom(16).hex().upper()
            save_state(self.state)
        self.device_id = self.state["deviceId"].encode()

    # --- BLE
    async def connect(self):
        log("connecting", self.address)
        self.client = BleakClient(self.address, timeout=30)
        await self.client.connect()
        log("connected, MTU", self.client.mtu_size)
        await self.client.start_notify(NOTIFY, self._notified)

    async def disconnect(self):
        if self.client and self.client.is_connected:
            await self.client.disconnect()

    def _notified(self, _char, data: bytearray):
        for p in self.parser.feed(bytes(data)):
            if self.verbose:
                log("<-", p)
            for i, (s, c, fut) in enumerate(self.waiters):
                if s == p.service and c == p.command and not fut.done():
                    self.waiters.pop(i)
                    fut.set_result(p)
                    break
            else:
                if self.on_unsolicited:
                    self.on_unsolicited(p)
                elif self.verbose:
                    log("unhandled", p)

    def _max_write(self):
        return max(20, (self.client.mtu_size or 23) - 3)

    async def _write(self, frames):
        size = min(self.link.get("slice", 0xF4), self._max_write())
        for f in frames:
            for i in range(0, len(f), size):
                await self.client.write_gatt_char(WRITE, f[i:i + size], response=False)

    # --- encryption
    def gcm(self):
        return self.link.get("encrypt") == 1 or self.link.get("support") == 4

    def encrypt_raw(self, data):
        iv = os.urandom(16)
        c = gcm_seal(data, self.session_key, iv) if self.gcm() else cbc_encrypt(data, self.session_key, iv)
        return TLV().add(0x7C, b"\x01").add(0x7D, iv).add(0x7E, c).serialize()

    def decrypt_raw(self, body):
        try:
            t = TLV.parse(body)
        except ValueError:
            return None
        if t.get(0x7C) != b"\x01" or t.get(0x7D) is None or self.session_key is None:
            return None
        iv, c = t.get(0x7D), t.get(0x7E)
        return gcm_open(c, self.session_key, iv) if self.gcm() else cbc_decrypt(c, self.session_key, iv)

    def decrypt_packet(self, p):
        if p.tlv and p.tlv.get(0x7C) == b"\x01" and self.session_key:
            plain = self.decrypt_raw(p.body)
            p.tlv = TLV.parse(plain)
        return p

    # --- requests
    def frames(self, service, command, tlv, encrypted=True, sliced=False):
        body = self.encrypt_raw(tlv.serialize()) if encrypted else tlv.serialize()
        if sliced:
            return serialize_sliced(service, command, body, min(self.link.get("slice", 0xF4), self._max_write()))
        return [serialize(service, command, body)]

    async def send(self, service, command, tlv, encrypted=True):
        if self.verbose:
            log("->", f"{service:02X}/{command:02X}", tlv)
        await self._write(self.frames(service, command, tlv, encrypted))

    async def request(self, service, command, tlv, encrypted=True, sliced=False, timeout=10):
        fut = asyncio.get_running_loop().create_future()
        self.waiters.append((service, command, fut))
        if self.verbose:
            log("->", f"{service:02X}/{command:02X}", tlv)
        await self._write(self.frames(service, command, tlv, encrypted, sliced))
        try:
            p = await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            self.waiters = [w for w in self.waiters if w[2] is not fut]
            raise TimeoutError(f"no answer to {service:02X}/{command:02X}")
        return self.decrypt_packet(p)

    # --- pairing
    async def pair(self):
        r = await self.request(0x01, 0x01, TLV().add(1).add(2).add(3).add(4), encrypted=False)
        t = r.tlv
        auth = t.get(0x05)
        self.link = {"slice": t.int(0x02) or 0xF4, "auth": auth[1] if auth and len(auth) > 1 else 0,
                     "support": t.int(0x07) or 0, "encrypt": t.int(0x0C) or 0}
        log("link", self.link)
        mode = 0x04 if self.link["support"] == 4 else 0x02
        n = TLV().add(0x01, bytes([mode])).add(0x02, b"\x01").add(0x05, self.device_id).add(0x03, b"\x01").add(0x04, b"\x00")
        if mode == 4:
            n.add(0x06).add(0x07, b"SM-S918B")
        if self.link["encrypt"] == 1:
            n.add(0x0D, b"\x01")
        neg = (await self.request(0x01, 0x33, n, encrypted=False)).tlv
        log("negotiation", neg)
        key_name = "authToken." + self.address
        token = bytes.fromhex(self.state[key_name]) if key_name in self.state else None
        if token is None:
            pin_t = (await self.request(0x01, 0x2C, TLV().add(0x01), encrypted=False)).tlv
            key = DIGEST.get(self.link["auth"], DIGEST_V3)
            msg, iv = pin_t.get(0x01), pin_t.get(0x02)
            pin = gcm_open(msg, key, iv) if self.link["encrypt"] == 1 else cbc_decrypt(msg, key, iv)
            log("PIN decrypted; confirm on the watch if it asks (60 s)")
            token = await self.hichain(1, sha256(pin.hex().upper().encode()))
            self.state[key_name] = token.hex()
            save_state(self.state)
            log("permanent key saved")
        self.session_key = await self.hichain(2, token)
        log("PAIRED, encrypted session ready")

    def _hichain_tlv(self, op, req_id, message, payload, device_level):
        version = {"minVersion": "1.0.0", "currentVersion": "2.0.16"}
        value = {"authForm": 0, "payload": {"version": version, **payload},
                 "groupAndModuleVersion": "2.0.1", "message": message | 0x10 if op == 2 else message}
        if op == 1:
            d = self.device_id.decode()
            value.update({"requestId": str(req_id), "groupId": GROUP_ID, "groupName": "health_group_name",
                          "groupOp": 2, "groupType": 256, "peerDeviceId": d, "connDeviceId": d,
                          "appId": "com.huawei.health", "ownerName": ""})
        if device_level:
            value["isDeviceLevel"] = False
        text = json.dumps(value, separators=(",", ":")).replace("/", "\\/")
        return TLV().add(0x01, text.encode()).add(0x02, bytes([op])).add(0x03, struct.pack(">Q", req_id))

    async def _hichain_step(self, tlv, timeout=10):
        r = (await self.request(0x01, 0x28, tlv, encrypted=False, sliced=True, timeout=timeout)).tlv
        code = r.int(0x7F)
        if code is not None and code != RESULT_SUCCESS:
            raise RuntimeError(f"HiChain result {code:#x}")
        if r.get(0x04) is None:
            raise RuntimeError(f"HiChain reply without type: {r}")
        if r.get(0x04)[0] != 0:
            return None
        payload = json.loads(r.get(0x01))["payload"]
        if payload.get("errorCode"):
            raise RuntimeError(f"HiChain errorCode {payload['errorCode']}")
        return payload

    async def hichain(self, op, key):
        req_id = int(time.time() * 1000)
        seed, rand_self = os.urandom(32), os.urandom(16)
        hx = lambda b: b.hex().upper()
        p1 = {"isoSalt": hx(rand_self), "peerAuthId": hx(self.device_id), "operationCode": op,
              "seed": hx(seed), "peerUserType": 0}
        if op == 2:
            p1.update({"pkgName": "com.huawei.devicegroupmanage", "serviceType": GROUP_ID, "keyLength": 0x20})
        r1 = await self._hichain_step(self._hichain_tlv(op, req_id, 1, p1, op == 2), timeout=60 if op == 1 else 10)
        rand_peer, auth_peer, peer_token = (bytes.fromhex(r1[k]) for k in ("isoSalt", "peerAuthId", "token"))
        psk = hmac(key, seed)
        if hmac(psk, rand_peer + rand_self + self.device_id + auth_peer) != peer_token:
            raise RuntimeError("watch token mismatch (wrong PIN or stale key: delete state.json entry and pair again)")
        self_token = hmac(psk, rand_self + rand_peer + auth_peer + self.device_id)
        r2 = await self._hichain_step(self._hichain_tlv(op, req_id, 2, {"peerAuthId": hx(self.device_id),
                                                                         "token": hx(self_token)}, op == 2))
        if bytes.fromhex(r2["returnCodeMac"]) != hmac(psk, b"\0\0\0\0"):
            raise RuntimeError("returnCodeMac mismatch")
        salt = rand_self + rand_peer
        iso = hkdf(psk, salt, "hichain_iso_session_key", 32)
        auth_token = None
        if op == 1:
            nonce, challenge = os.urandom(12), os.urandom(16)
            enc = gcm_seal(challenge, iso, nonce, b"hichain_iso_exchange")
            r3 = await self._hichain_step(self._hichain_tlv(op, req_id, 3, {"nonce": hx(nonce), "encData": hx(enc)}, False))
            auth_token = gcm_open(bytes.fromhex(r3["encAuthToken"]), iso, bytes.fromhex(r3["nonce"]), challenge)
        nonce = os.urandom(12)
        enc = gcm_seal(b"\0\0\0\0", iso, nonce, b"hichain_iso_result")
        r4 = await self._hichain_step(self._hichain_tlv(op, req_id, 4 if op == 1 else 3,
                                                        {"nonce": hx(nonce), "encResult": hx(enc), "operationCode": op}, False))
        if r4 is not None:
            raise RuntimeError(f"HiChain step 4 unexpected: {r4}")
        return auth_token or hkdf(iso, salt, "hichain_return_key", 32)

    # --- convenience
    async def product_info(self):
        tags = [0x01, 0x02, 0x07, 0x09, 0x0A, 0x11]
        t = (await self.request(0x01, 0x07, TLV([(x, b"") for x in tags]))).tlv
        return {k: (t.get(tag) or b"").decode(errors="replace").strip() for k, tag in
                (("model", 0x0A), ("name", 0x11), ("firmware", 0x07), ("serial", 0x09))}


async def find_watch(name_part="HUAWEI"):
    log("scanning 10 s…")
    devices = await BleakScanner.discover(timeout=10, return_adv=True)
    hits = [(d, a) for d, a in devices.values() if d.name and name_part.lower() in d.name.lower()]
    for d, a in hits:
        log("found", d.address, d.name, "RSSI", a.rssi)
    return hits
