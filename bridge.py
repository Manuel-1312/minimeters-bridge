"""
MiniMeters bridge — captura el loopback WASAPI de la salida por defecto (lo mismo que
"Default Output Capture" en MiniMeters), calcula medidas reales y las sirve por
WebSocket en 127.0.0.1:8985 al visualizer de Spotify (Spicetify).

Frame binario (Float32 little-endian), layout fijo:
  [0]  version (2)          [1]  sampleRate
  [2]  LUFS momentary       [3]  LUFS short-term     [4]  LUFS integrated   [5] LRA
  [6]  true peak L dBTP     [7]  true peak R dBTP
  [8]  correlación total    [9]  corr low   [10] corr mid   [11] corr high
  [12] pico Hz              [13] pico dB
  [14] f0 Hz (osciloscopio) [15] confianza f0 (0..1)
  [16] rms low dBFS         [17] rms mid dBFS   [18] rms high dBFS
  [19] wave min             [20] wave max        [21] wave rms (mid, frame)
  [22] sample peak L dBFS   [23] sample peak R dBFS
  [24..31] reservado
  [32 : 32+NMEL]                       espectro Mel (dB, 20 Hz..20 kHz)
  [.. : ..+NSCOPE]                     osciloscopio (mid, -1..1)
  [.. : ..+3*NVEC*2]                   vectorscopio: low, mid, high; pares (L,R)
"""
import asyncio
import logging
import os
import sys
import threading
import time

import numpy as np
import pyaudiowpatch as pa
import websockets
from scipy import signal

HOST = "127.0.0.1"
PORT = 8985
FPS = 144  # tasa de envío (antes 50): datos y scroll del espectrograma a 144 fps
SCOPE_DIV = max(1, round(FPS / 24))  # osciloscopio ~24 fps (autocorrelación 8192 es cara)
NFFT = 8192
NMEL = 512
NSCOPE = 512
NVEC = 192
HDR = 32
FRAME_FLOATS = HDR + NMEL + NSCOPE + 3 * NVEC * 2
F_LO, F_HI = 20.0, 20000.0

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bridge.log")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.FileHandler(LOG, encoding="utf-8"), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("bridge")


def hz_to_mel(f):
    return 2595.0 * np.log10(1.0 + f / 700.0)


def mel_to_hz(m):
    return 700.0 * (10.0 ** (m / 2595.0) - 1.0)


def k_weighting(fs):
    """Coeficientes ITU-R BS.1770 (shelf + high-pass). A 48 kHz, los de la norma; si no, diseño equivalente."""
    if int(fs) == 48000:
        return np.array([
            [1.53512485958697, -2.69169618940638, 1.19839281085285, 1.0, -1.69065929318241, 0.73248077421585],
            [1.0, -2.0, 1.0, 1.0, -1.99004745483398, 0.99007225036621],
        ])
    # high shelf
    f0, G, Q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    A = 10 ** (G / 40.0)
    w0 = 2 * np.pi * f0 / fs
    alpha = np.sin(w0) / (2 * Q)
    b = np.array([
        A * ((A + 1) + (A - 1) * np.cos(w0) + 2 * np.sqrt(A) * alpha),
        -2 * A * ((A - 1) + (A + 1) * np.cos(w0)),
        A * ((A + 1) + (A - 1) * np.cos(w0) - 2 * np.sqrt(A) * alpha),
    ])
    a = np.array([
        (A + 1) - (A - 1) * np.cos(w0) + 2 * np.sqrt(A) * alpha,
        2 * ((A - 1) - (A + 1) * np.cos(w0)),
        (A + 1) - (A - 1) * np.cos(w0) - 2 * np.sqrt(A) * alpha,
    ])
    shelf = np.concatenate([b / a[0], a / a[0]])
    # high pass
    f0, Q = 38.13547087602444, 0.5003270373238773
    w0 = 2 * np.pi * f0 / fs
    alpha = np.sin(w0) / (2 * Q)
    b = np.array([(1 + np.cos(w0)) / 2, -(1 + np.cos(w0)), (1 + np.cos(w0)) / 2])
    a = np.array([1 + alpha, -2 * np.cos(w0), 1 - alpha])
    hp = np.concatenate([b / a[0], a / a[0]])
    return np.vstack([shelf, hp])  # sos 2x6


class Dsp:
    def __init__(self, fs, ch):
        self.fs = fs
        self.ch = ch
        self.lock = threading.Lock()
        self.pending = []
        # anillos
        self.ring = np.zeros((NFFT, 2), dtype=np.float32)  # L,R
        self.kring = np.zeros((int(fs * 3.0), 2), dtype=np.float32)  # K-weighted 3 s
        self.win = np.hanning(NFFT).astype(np.float32)
        self.win_gain = 2.0 / self.win.sum()
        # Mel
        binw = fs / NFFT
        edges = mel_to_hz(np.linspace(hz_to_mel(F_LO), hz_to_mel(F_HI), NMEL + 1)) / binw
        self.mel_lo = np.floor(edges[:-1]).astype(int)
        self.mel_hi = np.ceil(edges[1:]).astype(int)
        self.mel_center = (edges[:-1] + edges[1:]) / 2
        self.mel_wide = (self.mel_hi - self.mel_lo) >= 2
        self.nbins = NFFT // 2 + 1
        self.mel_lo = np.clip(self.mel_lo, 0, self.nbins - 1)
        self.mel_hi = np.clip(self.mel_hi, 1, self.nbins)
        # filtros
        self.ksos = k_weighting(fs)
        self.kzi = [signal.sosfilt_zi(self.ksos) * 0 for _ in range(2)]
        self.band_sos = [
            signal.butter(2, 250, "low", fs=fs, output="sos"),
            signal.butter(2, [250, 4000], "band", fs=fs, output="sos"),
            signal.butter(2, 4000, "high", fs=fs, output="sos"),
        ]
        self.band_zi = [[signal.sosfilt_zi(s) * 0 for _ in range(2)] for s in self.band_sos]
        self.band_last = [np.zeros((1, 2), dtype=np.float32) for _ in range(3)]
        self.band_rms = np.full(3, -90.0)
        self.band_corr = np.zeros(3)
        # loudness
        self.block_hist = []  # (t, loudness 400ms) cada 100 ms
        self.st_hist = []  # short-term cada 100 ms
        self.last_block_t = 0.0
        self.integrated = -np.inf
        self.lra = 0.0
        self.silence_since = None
        self.frame_new = np.zeros((0, 2), dtype=np.float32)
        self.t0 = time.time()
        self.gain = 1.0  # compensación del volumen maestro (ver push)
        self.frame_idx = 0
        self.scope_cache = (np.zeros(NSCOPE, dtype=np.float32), 0.0, 0.0)

    # --- captura ---
    def push(self, data: bytes):
        x = np.frombuffer(data, dtype=np.float32)
        if self.ch >= 2:
            x = x.reshape(-1, self.ch)[:, :2]
        else:
            x = np.repeat(x.reshape(-1, 1), 2, axis=1)
        # El loopback WASAPI llega POST volumen maestro de Windows; se compensa (como hace
        # MiniMeters) para que las lecturas sean independientes del slider de volumen.
        x = x * self.gain
        with self.lock:
            self.pending.append(x.astype(np.float32, copy=False))

    def pull(self):
        with self.lock:
            if not self.pending:
                return np.zeros((0, 2), dtype=np.float32)
            x = np.concatenate(self.pending)
            self.pending.clear()
        return x

    def reset_integrated(self):
        self.block_hist.clear()
        self.st_hist.clear()
        self.integrated = -np.inf
        self.lra = 0.0

    # --- utilidades ---
    @staticmethod
    def db(x, floor=-120.0):
        return float(max(floor, 20 * np.log10(x + 1e-12)))

    def ingest(self, x):
        n = len(x)
        if n == 0:
            return
        if n >= NFFT:
            self.ring[:] = x[-NFFT:]
        else:
            self.ring = np.roll(self.ring, -n, axis=0)
            self.ring[-n:] = x
        # K-weighting por canal (estado continuo)
        k = np.empty_like(x)
        for c in range(2):
            k[:, c], self.kzi[c] = signal.sosfilt(self.ksos, x[:, c], zi=self.kzi[c])
        m = len(self.kring)
        if n >= m:
            self.kring[:] = k[-m:]
        else:
            self.kring = np.roll(self.kring, -n, axis=0)
            self.kring[-n:] = k
        # bandas (para vectorscopio, rms y correlación por banda)
        for b in range(3):
            out = np.empty_like(x)
            for c in range(2):
                out[:, c], self.band_zi[b][c] = signal.sosfilt(self.band_sos[b], x[:, c], zi=self.band_zi[b][c])
            self.band_last[b] = out
            mid = (out[:, 0] + out[:, 1]) * 0.5
            self.band_rms[b] = self.db(np.sqrt(np.mean(mid * mid) + 1e-20))
            self.band_corr[b] = self.corr(out)
        self.frame_new = x

    @staticmethod
    def corr(x):
        l, r = x[:, 0], x[:, 1]
        den = np.sqrt(np.sum(l * l) * np.sum(r * r))
        if den < 1e-9:
            return 0.0
        return float(np.clip(np.sum(l * r) / den, -1, 1))

    def loudness_window(self, seconds):
        n = int(self.fs * seconds)
        seg = self.kring[-n:]
        ms = np.mean(seg * seg, axis=0).sum()
        return float(-0.691 + 10 * np.log10(ms + 1e-12))

    def update_loudness(self, now):
        mom = self.loudness_window(0.4)
        st = self.loudness_window(3.0)
        if now - self.last_block_t >= 0.1:
            self.last_block_t = now
            self.block_hist.append(mom)
            self.st_hist.append(st)
            if len(self.block_hist) > 36000:  # 1 h
                del self.block_hist[:1000]
                del self.st_hist[:1000]
            if len(self.block_hist) % 5 == 0:
                self.compute_integrated()
        # reset automático tras silencio prolongado (cambio de pista / stop)
        if mom < -70:
            if self.silence_since is None:
                self.silence_since = now
            elif now - self.silence_since > 4.0 and self.block_hist:
                self.reset_integrated()
                self.silence_since = None
        else:
            self.silence_since = None
        return mom, st

    def compute_integrated(self):
        blocks = np.array(self.block_hist)
        blocks = blocks[blocks > -70]
        if len(blocks) == 0:
            self.integrated = -np.inf
        else:
            p = 10 ** ((blocks + 0.691) / 10)
            rel = -0.691 + 10 * np.log10(p.mean()) - 10
            gated = blocks[blocks > rel]
            if len(gated):
                pg = 10 ** ((gated + 0.691) / 10)
                self.integrated = float(-0.691 + 10 * np.log10(pg.mean()))
        st = np.array(self.st_hist)
        st = st[st > -70]
        if len(st) >= 10:
            p = 10 ** ((st + 0.691) / 10)
            rel = -0.691 + 10 * np.log10(p.mean()) - 20
            g = st[st > rel]
            if len(g) >= 10:
                self.lra = float(np.percentile(g, 95) - np.percentile(g, 10))

    def true_peak(self, x):
        if len(x) == 0:
            return -np.inf, -np.inf
        up = signal.resample_poly(x, 4, 1, axis=0)
        pk = np.max(np.abs(up), axis=0)
        return self.db(pk[0]), self.db(pk[1])

    def spectrum(self):
        mid = (self.ring[:, 0] + self.ring[:, 1]) * 0.5
        X = np.fft.rfft(mid * self.win)
        mag = np.abs(X) * self.win_gain
        dbs = 20 * np.log10(mag + 1e-10)
        # Mel: max en bins anchos, interpolación en bins estrechos
        mel = np.maximum.reduceat(dbs, self.mel_lo)
        narrow = ~self.mel_wide
        mel[narrow] = np.interp(self.mel_center[narrow], np.arange(self.nbins), dbs)
        # pico dominante (20 Hz..20 kHz) con interpolación parabólica
        lo = int(F_LO * NFFT / self.fs)
        hi = int(F_HI * NFFT / self.fs)
        seg = dbs[lo:hi]
        i = int(np.argmax(seg)) + lo
        if 1 <= i < self.nbins - 1:
            a, b, c = dbs[i - 1], dbs[i], dbs[i + 1]
            d = 0.5 * (a - c) / (a - 2 * b + c + 1e-12)
            d = float(np.clip(d, -1, 1))
            pk_f = (i + d) * self.fs / NFFT
            pk_db = float(b - 0.25 * (a - c) * d)
        else:
            pk_f, pk_db = i * self.fs / NFFT, float(dbs[i])
        return mel.astype(np.float32), pk_f, pk_db

    def scope(self):
        mid = (self.ring[:, 0] + self.ring[:, 1]) * 0.5
        x = mid[-4096:].astype(np.float64)
        x = x - x.mean()
        e = float(np.dot(x, x))
        if e < 1e-4:  # ~ -76 dBFS RMS: silencio, sin pitch
            out = np.interp(np.linspace(0, 2047, NSCOPE), np.arange(2048), x[-2048:])
            return out.astype(np.float32), 0.0, 0.0
        X = np.fft.rfft(x, 8192)
        ac = np.fft.irfft(X * np.conj(X))[:4096]
        ac /= ac[0] + 1e-12
        lmin, lmax = int(self.fs / 2000), int(self.fs / 40)
        # saltar el lóbulo inicial: buscar a partir del primer cruce negativo de la autocorrelación
        neg = np.where(ac[lmin:lmax] < 0)[0]
        start = lmin + int(neg[0]) if len(neg) else lmin
        seg = ac[start:lmax]
        if len(seg) < 3:
            return np.interp(np.linspace(0, 2047, NSCOPE), np.arange(2048), x[-2048:]).astype(np.float32), 0.0, 0.0
        li = int(np.argmax(seg)) + start
        conf = float(np.clip(ac[li], 0, 1))
        if 1 <= li < 4095:
            a, b, c = ac[li - 1], ac[li], ac[li + 1]
            d = 0.5 * (a - c) / (a - 2 * b + c + 1e-12)
            lag = li + float(np.clip(d, -1, 1))
        else:
            lag = float(li)
        f0 = self.fs / lag
        if conf >= 0.5:
            L = int(round(lag * 4))  # "Multi": 4 ciclos
            L = max(64, min(L, 4096))
            # trigger: cruce por cero ascendente más reciente que deje sitio a la ventana
            sl = x[: 4096 - L + 1]
            zc = np.where((sl[:-1] < 0) & (sl[1:] >= 0))[0]
            start = int(zc[-1]) + 1 if len(zc) else 4096 - L
            seg = x[start : start + L]
        else:
            seg = x[-2048:]
        out = np.interp(np.linspace(0, len(seg) - 1, NSCOPE), np.arange(len(seg)), seg)
        return out.astype(np.float32), f0, conf

    def vector(self):
        pts = np.empty((3, NVEC, 2), dtype=np.float32)
        for b in range(3):
            src = self.band_last[b]
            if len(src) < 2:
                pts[b] = 0
                continue
            idx = np.linspace(0, len(src) - 1, NVEC).astype(int)
            pts[b] = src[idx]
        return pts

    def frame(self, now):
        f = np.zeros(FRAME_FLOATS, dtype=np.float32)
        mom, st = self.update_loudness(now)
        tpl, tpr = self.true_peak(self.frame_new)
        mel, pk_f, pk_db = self.spectrum()
        # osciloscopio a ~24 fps (autocorrelación 8192): suficiente y ahorra CPU
        self.frame_idx += 1
        if self.frame_idx % SCOPE_DIV == 0:
            self.scope_cache = self.scope()
        sc, f0, conf = self.scope_cache
        x = self.frame_new
        if len(x):
            mid = (x[:, 0] + x[:, 1]) * 0.5
            wmin, wmax = float(mid.min()), float(mid.max())
            wrms = float(np.sqrt(np.mean(mid * mid)))
            spl, spr = self.db(float(np.max(np.abs(x[:, 0])))), self.db(float(np.max(np.abs(x[:, 1]))))
            corr = self.corr(x)
        else:
            wmin = wmax = wrms = 0.0
            spl = spr = -120.0
            corr = 0.0
        f[0] = 2
        f[1] = self.fs
        f[2] = max(-120, mom)
        f[3] = max(-120, st)
        f[4] = max(-120, self.integrated) if np.isfinite(self.integrated) else -120
        f[5] = self.lra
        f[6] = max(-120, tpl)
        f[7] = max(-120, tpr)
        f[8] = corr
        f[9:12] = self.band_corr
        f[12] = pk_f
        f[13] = pk_db
        f[14] = f0
        f[15] = conf
        f[16:19] = self.band_rms
        f[19] = wmin
        f[20] = wmax
        f[21] = wrms
        f[22] = spl
        f[23] = spr
        o = HDR
        f[o : o + NMEL] = mel
        o += NMEL
        f[o : o + NSCOPE] = sc
        o += NSCOPE
        f[o : o + 3 * NVEC * 2] = self.vector().reshape(-1)
        return f.tobytes()


class Capture:
    """Abre el loopback del dispositivo de salida por defecto; se reabre si cambia/falla."""

    def __init__(self):
        self.pa = pa.PyAudio()
        self.stream = None
        self.dsp = None
        self.dev_name = None
        self.endpoint = None

    def master_gain(self):
        """Ganancia que deshace el volumen maestro del endpoint por defecto (1.0 si no se puede leer)."""
        try:
            if self.endpoint is None:
                from pycaw.pycaw import AudioUtilities
                self.endpoint = AudioUtilities.GetSpeakers().EndpointVolume
            if self.endpoint.GetMute():
                return 1.0
            db = float(self.endpoint.GetMasterVolumeLevel())
            return float(10 ** (-db / 20.0)) if db < 0 else 1.0
        except Exception:
            self.endpoint = None
            return 1.0

    def open(self):
        self.close()
        w = self.pa.get_default_wasapi_loopback()
        fs = int(w["defaultSampleRate"])
        ch = int(w["maxInputChannels"])
        self.dsp = Dsp(fs, ch)
        self.dev_name = w["name"]

        def cb(data, n, t, st):
            try:
                self.dsp.push(data)
            except Exception:
                pass
            return (None, pa.paContinue)

        self.stream = self.pa.open(
            format=pa.paFloat32,
            channels=ch,
            rate=fs,
            input=True,
            input_device_index=w["index"],
            frames_per_buffer=int(fs * 0.01),
            stream_callback=cb,
        )
        log.info("captura abierta: %s @ %d Hz, %d ch", self.dev_name, fs, ch)

    def close(self):
        if self.stream is not None:
            try:
                self.stream.stop_stream()
                self.stream.close()
            except Exception:
                pass
            self.stream = None

    def alive(self):
        try:
            return self.stream is not None and self.stream.is_active()
        except Exception:
            return False

    def default_changed(self):
        try:
            return self.pa.get_default_wasapi_loopback()["name"] != self.dev_name
        except Exception:
            return False


async def main():
    clients = set()
    cap = Capture()

    async def handler(ws):
        clients.add(ws)
        log.info("cliente conectado (%d)", len(clients))
        try:
            async for msg in ws:
                if msg == "reset" and cap.dsp is not None:
                    cap.dsp.reset_integrated()
        except Exception:
            pass
        finally:
            clients.discard(ws)
            log.info("cliente desconectado (%d)", len(clients))

    server = await websockets.serve(handler, HOST, PORT, max_queue=4, compression=None)
    log.info("WebSocket en ws://%s:%d", HOST, PORT)

    period = 1.0 / FPS
    next_t = time.perf_counter()
    last_check = 0.0
    while True:
        now = time.perf_counter()
        if not cap.alive():
            try:
                cap.open()
            except Exception as e:
                log.warning("no se pudo abrir la captura: %s", e)
                await asyncio.sleep(2.0)
                continue
        if now - last_check > 1.0:
            last_check = now
            if cap.default_changed():
                log.info("dispositivo por defecto cambió; reabriendo")
                try:
                    cap.open()
                    cap.endpoint = None
                except Exception as e:
                    log.warning("reapertura falló: %s", e)
            if cap.dsp is not None:
                g = cap.master_gain()
                if abs(g - cap.dsp.gain) > 1e-3:
                    log.info("volumen maestro: compensación %.2f dB", 20 * np.log10(g))
                    cap.dsp.gain = g
        dsp = cap.dsp
        x = dsp.pull()
        dsp.ingest(x)
        if clients:
            try:
                data = dsp.frame(time.time())
                websockets.broadcast(clients, data)
            except Exception as e:
                log.exception("error generando frame: %s", e)
        next_t += period
        delay = next_t - time.perf_counter()
        if delay < -0.5:
            next_t = time.perf_counter()
            delay = 0
        await asyncio.sleep(max(0.0, delay))


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
