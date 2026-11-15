# Sleep phase research (GT 3 Pro, TruSleep)

Goal: estimate deep / light / REM / awake from the raw `sleep_data.bin` (accelerometer per minute + PPG beats),
calibrated against Huawei Health's hypnograms of the same nights.

- `sleep_an.py` – parses `sleep_data.bin` (format from Gadgetbridge's HuaweiTruSleepParser).
- `digit.py` – turns a Huawei Health sleep screenshot into minute labels by bar colour; finds the chart band itself.
  Checked against Huawei's totals: within a few minutes per phase.
- `feat.py` – merges every `sleep_data*.bin` under `SLEEP_DATA` (de-duplicated by timestamp; the watch returns its whole
  buffer per download), cuts the nights listed in `NIGHTS` and aligns per-minute features with the screenshot labels.
- `model.py` / `model2.py` – leave-one-night-out classifiers. v2 adds context features and balanced classes.

Status (5 nights, 10–15 Nov): minute agreement ~55 %, phase totals off by ~25–30 min on average.
REM vs light is the weak spot. More reference nights (screenshot + raw data within two weeks) will improve it.

Raw data and screenshots are personal health data: keep them in `SLEEP_DATA` (default `./sleep-export`,
screenshots in `SLEEP_DATA/Huawei Health/`), never in Git.
