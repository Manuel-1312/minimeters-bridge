"""Cliente de prueba: lee frames del bridge y resume sus valores."""
import asyncio
import sys
import time

import numpy as np
import websockets

HDR, NMEL, NSCOPE, NVEC = 32, 512, 512, 192


async def main(seconds=3.0):
    url = "ws://127.0.0.1:8985"
    for attempt in range(20):
        try:
            ws = await websockets.connect(url, open_timeout=2)
            break
        except Exception:
            await asyncio.sleep(0.5)
    else:
        print("no se pudo conectar")
        return 1
    t0 = time.time()
    n = 0
    last = None
    async with ws:
        while time.time() - t0 < seconds:
            data = await asyncio.wait_for(ws.recv(), timeout=2)
            f = np.frombuffer(data, dtype=np.float32)
            n += 1
            last = f
    print(f"frames en {seconds}s: {n} (~{n/seconds:.0f} fps), floats/frame: {last.size}, bytes: {last.size*4}")
    h = last[:HDR]
    print(f"fs={h[1]:.0f}  LUFS M={h[2]:.1f} S={h[3]:.1f} I={h[4]:.1f} LRA={h[5]:.1f}")
    print(f"TP L={h[6]:.1f} R={h[7]:.1f} dBTP | samplePeak L={h[22]:.1f} R={h[23]:.1f}")
    print(f"corr total={h[8]:+.2f} low={h[9]:+.2f} mid={h[10]:+.2f} high={h[11]:+.2f}")
    print(f"pico {h[12]:.1f} Hz @ {h[13]:.1f} dB | f0={h[14]:.1f} Hz conf={h[15]:.2f}")
    print(f"rms bandas low={h[16]:.1f} mid={h[17]:.1f} high={h[18]:.1f} dBFS | wave min={h[19]:+.3f} max={h[20]:+.3f} rms={h[21]:.3f}")
    mel = last[HDR:HDR + NMEL]
    print(f"mel: min={mel.min():.1f} max={mel.max():.1f} median={np.median(mel):.1f} dB (bins 0,128,256,384,511 -> {mel[[0,128,256,384,511]].round(1)})")
    sc = last[HDR + NMEL:HDR + NMEL + NSCOPE]
    print(f"scope: min={sc.min():+.3f} max={sc.max():+.3f}")
    vec = last[HDR + NMEL + NSCOPE:].reshape(3, NVEC, 2)
    print(f"vector: absmax por banda = {np.abs(vec).max(axis=(1,2)).round(3)}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(float(sys.argv[1]) if len(sys.argv) > 1 else 3.0)))
