# minimeters-bridge

Real-time audio metering for a Spotify ([Spicetify](https://spicetify.app)) visualizer.
It captures the default Windows output through WASAPI loopback — the same source as
MiniMeters' *Default Output Capture* — computes broadcast-grade measurements and streams
them over a local WebSocket (`ws://127.0.0.1:8985`) so a Spicetify custom app can draw them.

![MiniMeters visualizer](visualizer/demo.gif)

Because it reads the **actual audio** (not Spotify's precomputed analysis), the numbers are
real: a −20 dBFS tone reads −20.00 LUFS / −19.99 dBTP, matching MiniMeters.

## Install (Windows)

1. On this page, click the green **Code** button, then **Download ZIP**.
2. Right-click the ZIP and choose **Extract All**.
3. Open the extracted folder and double-click **`Install MiniMeters Bridge.bat`**.

That's it. No administrator rights are needed. If Python 3.12 is missing it is installed
automatically **for your user only** (via winget; your existing Python is left untouched).
Everything is placed under `%LOCALAPPDATA%\MiniMetersBridge`, and the bridge starts about
30 seconds after each logon, listening **only on `127.0.0.1`** (localhost). A console window
shows plain-English progress and stays open so you can read the result — it ends with
`MiniMeters bridge is running on ws://127.0.0.1:8985`.

To remove everything later, double-click **`Uninstall MiniMeters Bridge.bat`**.

> The install scripts are short, readable, and MIT-licensed; the bridge binds only to
> localhost (nothing internet-facing). Because they are unsigned, Windows SmartScreen may
> show an "unknown publisher" note the first time.

After it's running, finish the Spotify side by following [`visualizer/README.md`](visualizer/).

<details>
<summary>Prefer the command line?</summary>

One-liner (downloads and runs the same `install.ps1` you can read in this repo):

```powershell
irm https://raw.githubusercontent.com/Manuel-1312/minimeters-bridge/main/get.ps1 | iex
```

Manual / developer path:

```powershell
pip install -r requirements.txt
python bridge.py          # foreground, logs to bridge.log
python test_client.py 3   # read 3 s of frames
powershell -ExecutionPolicy Bypass -File install.ps1   # register the logon task
```

</details>

## What it computes (144 fps by default, ~9 KB/frame)
- **Spectrum** — FFT 8192 (Hann) on the Mid channel → 512-bin Mel spectrum (20 Hz–20 kHz),
  dominant peak with parabolic interpolation.
- **Loudness** — EBU R128 / ITU-R BS.1770: momentary (400 ms), short-term (3 s),
  integrated with gating (−70 abs / −10 rel), LRA.
- **True peak** L/R (4× oversampling), sample peak, total and per-band correlation
  (low < 250 Hz, mid 250–4000, high > 4 kHz).
- **Oscilloscope** — pitch-triggered (autocorrelation), f0 + confidence.
- **Vectorscope** — 192 (L, R) pairs per band.
- Undoes the endpoint master volume (the loopback arrives post-volume).

The frame rate is the `FPS` constant in `bridge.py` (144 by default; 50–60 is plenty if you
want less CPU) — it uses roughly 10–20 % of one core. The `reset` WebSocket message resets
integrated LUFS, and the bridge reopens itself automatically if the default output device
changes.

## Frame layout
See the docstring at the top of `bridge.py` — Float32 little-endian: a 32-value header,
then 512 Mel bins, 512 oscilloscope samples and a 3×192×2 vectorscope block.

## The visualizer (frontend)

This repo is just the audio **bridge** (the backend). The on-screen meters are **RealMeters**,
a separate Spicetify frontend:

- **One click:** install **RealMeters** from the Spicetify Marketplace (Extensions tab), then
  open it from the button in the now-playing bar.
- Source: [Manuel-1312/realmeters-spotify](https://github.com/Manuel-1312/realmeters-spotify)
  (also available there as a custom app with a dedicated sidebar page).

RealMeters needs this bridge running for data. The renderer began as one for
**[Konsl's spicetify-visualizer](https://github.com/Konsl/spicetify-visualizer)** (MIT); a
copy of that renderer is kept in [`visualizer/`](visualizer/) for reference.

## License
MIT — see [LICENSE](LICENSE).
