# Sleep phase research (GT 3 Pro, TruSleep)

Goal: estimate deep / light / REM / awake from the raw `sleep_data.bin` (accelerometer per minute + PPG beats),
calibrated against Huawei Health's hypnograms of the same nights.

- `sleep_an.py` – parses `sleep_data.bin` (format from Gadgetbridge's HuaweiTruSleepParser).
- `digit.py` – turns a Huawei Health sleep screenshot into minute labels by bar colour; finds the chart band itself.
  Checked against Huawei's totals: within a few minutes per phase.
- `feat.py` – merges every `sleep_data*.bin` under `SLEEP_DATA` (de-duplicated by timestamp; the watch returns its whole
  buffer per download), cuts the nights listed in `NIGHTS` and aligns per-minute features with the screenshot labels.
- `model.py` / `model2.py` – leave-one-night-out classifiers. v2 adds context features and balanced classes.

Status (10 nights, 10–21 Nov, leave-one-night-out): minute agreement ~60 % (51–68 % per night), phase totals off by
~23 min (deep), ~52 min (light, over-predicted), ~34 min (REM). Before the PPG fix: ~56 %, deep off by ~35 min.

**PPG beat times:** a PPG record (every ~32 s at night) holds ~24 beats. Compressed peaks are a u16 start plus
**unsigned** byte deltas (each delta = one beat interval in 10 ms). Gadgetbridge reads them as signed, which flips every
interval above 1.27 s (HR < 47 bpm, common in sleep). Decoded unsigned, records chain seamlessly into a beat-to-beat
series (gap between records ≈ one interval), so real HRV (RMSSD, SDNN, pNN50 over 1 and 5 minutes) is available.
Nights in two blocks: time features restart per block (a block ends after 30 min without accelerometer data).

Raw data and screenshots are personal health data: keep them in `SLEEP_DATA` (default `./sleep-export`,
screenshots in `SLEEP_DATA/Huawei Health/`), never in Git.
