# huawei-cli (PC tool for the watch)

## Recommended: through the iPhone (no pairing with the PC)

The watch stays paired with HuaSideload on the iPhone; the PC talks to it over Wi-Fi through the app:

1. HuaSideload → Features → "PC relay" on (keep the app open; same Wi-Fi as the PC). It shows address and token.
2. `py -3.10 cli.py info relay:192.168.x.y --token TOKEN` (or set `HUAWEI_RELAY_TOKEN`).
   All commands work the same way: `sleep relay:… --from … --to …`, `probe relay:…`, `check.py relay:… TOKEN`.

The phone encrypts and decrypts; every unsolicited packet from the watch (e.g. file blocks) is forwarded to the PC.
Don't sync in the app at the same time as the PC tool runs.

## Direct Bluetooth (only if needed)

Python port of the Huawei Link protocol (from Gadgetbridge) to debug transfers from a Windows PC without new iOS builds.

Setup: `py -3.10 -m pip install -r requirements.txt`

Connecting (GT 3 Pro, Windows):
- The watch only shows up to a new device after **Settings → System → Disconnect** on the watch (pairing mode).
- Pair it once in **Windows Settings → Bluetooth & devices → Add device**. After that it no longer advertises over BLE.
- The tool talks over classic Bluetooth (RFCOMM, Huawei SDP service `82FF3820-…`, channel 16 on the GT 3 Pro).
  BLE (`--ble`) did not work on Windows: GATT discovery times out without an OS bond, and Windows bonding over BLE fails.
- First connect does the HiChain pairing; the auth token is stored in `%APPDATA%\huawei-cli\state.json` (keep it private).

Commands: `cli.py info|probe|sleep <address>`, `check.py <address>` (record counts, sleep sessions).

Findings about `sleep_data.bin` (raw TruSleep sensor data):
- The watch ignores the requested time range. A 24 h window returns 0 bytes (error 144001 in tag 7F),
  the exact window of a stored sleep session returns the **whole buffer** (about two weeks of nights, ~0.5 MB, ~20 s).
- So: download once, then split by timestamp into nights (`sleep_state.bin` gives the session boundaries).

Pairing the watch with the PC disconnects it from the phone: re-pair Huawei Health / HuaSideload afterwards.
