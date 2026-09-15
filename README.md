# minimeters-bridge

Real-time audio metering for a Spotify ([Spicetify](https://spicetify.app)) visualizer.
It captures the default Windows output through WASAPI loopback — the same source as
MiniMeters' *Default Output Capture* — computes broadcast-grade measurements and streams
them over a local WebSocket (`ws://127.0.0.1:8985`) so a Spicetify custom app can draw them.

Because it reads the **actual audio** (not Spotify's precomputed analysis), the numbers are
real: a −20 dBFS tone reads −20.00 LUFS / −19.99 dBTP, matching MiniMeters.

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

## Requirements
Windows + Python 3.12.

    pip install -r requirements.txt

(pyaudiowpatch, numpy, scipy, websockets, pycaw, comtypes)

## Run

    python bridge.py            # logs to bridge.log
    python test_client.py 3     # reads 3 s of frames and prints a summary

The frame rate is the `FPS` constant in `bridge.py` (144 by default; 50–60 is plenty if you
want less CPU). It uses roughly 10–20 % of one core.

## Auto-start (Windows)

One command installs the dependencies and registers a Scheduled Task that runs
`pythonw bridge.py` in the background at logon:

    powershell -ExecutionPolicy Bypass -File install.ps1

The task has no run-time limit, restarts on failure and starts 30 s after logon so the
audio device is ready. Remove it with `uninstall.ps1`.

The `reset` WebSocket message resets integrated LUFS; the bridge reopens itself
automatically if the default output device changes.

## Frame layout
See the docstring at the top of `bridge.py` — Float32 little-endian: a 32-value header,
then 512 Mel bins, 512 oscilloscope samples and a 3×192×2 vectorscope block.

## The visualizer (frontend)
The drawing side is a renderer for **[Konsl's spicetify-visualizer](https://github.com/Konsl/spicetify-visualizer)**
(MIT). This repo ships that renderer and its setup steps in [`visualizer/`](visualizer/).
All credit for the visualizer framework goes to Konsl; only the `MiniMeters` renderer and
this bridge are mine.

## License
MIT — see [LICENSE](LICENSE).
