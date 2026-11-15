# Sleep phase research (GT 3 Pro, TruSleep)

Goal: estimate deep / light / REM / awake from the raw `sleep_data.bin` (accelerometer per minute + PPG beats),
calibrated against Huawei Health's hypnograms of the same nights.

- `sleep_an.py` – parses `sleep_data.bin` (format from Gadgetbridge's HuaweiTruSleepParser).
- `digit.py` – turns a Huawei Health sleep screenshot into minute labels by bar colour (checked: totals within ~5 %).
- `feat.py` – per-minute features (activity, heart rate, RMSSD) aligned to the labels; edit `NIGHTS` for new nights.
- `model.py` – leave-one-night-out classifier.

Raw data and screenshots are personal health data: keep them in `SLEEP_DATA` (default `./sleep-export`), never in Git.
