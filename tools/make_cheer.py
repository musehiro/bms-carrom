#!/usr/bin/env python3
"""
make_cheer.py — Synthesized crowd-cheer sound for the Carrom game.

PROVENANCE: 100% synthesized from scratch with numpy / scipy / stdlib wave.
No recorded voices, no downloaded sounds, no samples, no third-party audio
of any kind. Every component below is generated mathematically:

  (a) crowd bed  — band-passed filtered white noise (300-3000 Hz),
                   slow attack ~0.3 s, sustained swell decaying over ~1.8 s;
  (b) voice-like "hoo-ray" blips — 16 short bursts of band-passed noise plus
                   sine clusters with formant peaks ~700/1100/2500 Hz,
                   random base pitch 180-350 Hz with jitter, staggered
                   onsets 0.05-0.6 s, each 0.15-0.4 s, in two syllable
                   groups (rising "hoo" -> falling "ray");
  (c) high "yay" chirps on top for sparkle.

Output: audio/cheer.wav — 22050 Hz, 16-bit, mono, 2.0 s (~88 KB),
matching the game's existing SFX format (scripts/sfx.gd, AudioStreamWAV,
16-bit mono 22050 Hz). Normalized to -3 dBFS peak, 0.3 s fade-out.

Deterministic: fixed random seed (42), so the file is reproducible.

Usage:
    python3 tools/make_cheer.py [--out audio/cheer.wav]

Free-only: numpy + scipy + stdlib only.
"""

import argparse
import os
import wave

import numpy as np
from scipy.signal import butter, sosfilt, sosfiltfilt

SEED = 42
SR = 22050
DURATION = 2.0
N = int(SR * DURATION)


def bandpass(x: np.ndarray, lo: float, hi: float, order: int = 4) -> np.ndarray:
    """Zero-phase Butterworth band-pass filter."""
    sos = butter(order, [lo, hi], btype="bandpass", fs=SR, output="sos")
    return sosfiltfilt(sos, x)


def smooth_envelope(length: int, attack: float, decay_tau: float) -> np.ndarray:
    """Smooth attack (raised-cosine ramp) followed by exponential decay."""
    t = np.arange(length) / SR
    env = np.ones(length)
    atk = int(attack * SR)
    if atk > 0:
        env[:atk] = 0.5 - 0.5 * np.cos(np.pi * np.arange(atk) / atk)
    env *= np.exp(-np.maximum(t - attack, 0.0) / decay_tau)
    return env


def crowd_bed(rng: np.random.Generator) -> np.ndarray:
    """(a) Room-full-of-people body: band-passed noise, slow swell."""
    noise = rng.standard_normal(N)
    bed = bandpass(noise, 300.0, 3000.0)
    # Slow attack ~0.3 s, sustained swell decaying over ~1.8 s.
    env = smooth_envelope(N, attack=0.30, decay_tau=0.75)
    # A second, slower swell layered in for a "wave" of applause feel.
    swell = 0.6 + 0.4 * np.sin(np.pi * np.clip(np.arange(N) / SR / 1.8, 0, 1))
    return bed * env * swell


def voice_blip(rng: np.random.Generator, onset: float, dur: float,
               base_pitch: float, pitch_end: float) -> np.ndarray:
    """One voice-like blip: formant-filtered noise + pitched sine cluster."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    # Pitch glides from base_pitch to pitch_end across the blip.
    phase = 2.0 * np.pi * np.cumsum(
        np.linspace(base_pitch, pitch_end, n)) / SR
    # Harmonic sine cluster (fundamental + 2nd/3rd harmonics, falling amps).
    voiced = (np.sin(phase)
              + 0.5 * np.sin(2.0 * phase)
              + 0.25 * np.sin(3.0 * phase))
    # Breath/noise component shaped by the three formants.
    noise = rng.standard_normal(n)
    formant = np.zeros(n)
    for fc, gain in ((700.0, 1.0), (1100.0, 0.7), (2500.0, 0.45)):
        sos = butter(2, [fc * 0.85, fc * 1.18], btype="bandpass",
                     fs=SR, output="sos")
        formant += gain * sosfilt(sos, noise)
    formant /= np.max(np.abs(formant)) + 1e-12
    sig = 0.55 * voiced + 0.45 * formant
    # Per-blip envelope: quick attack, gentle release.
    env = np.ones(n)
    atk = max(1, int(0.03 * SR))
    env[:atk] = 0.5 - 0.5 * np.cos(np.pi * np.arange(atk) / atk)
    rel = max(1, int(0.06 * SR))
    env[-rel:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(rel) / rel)
    return sig * env


def hoo_ray_blips(rng: np.random.Generator) -> np.ndarray:
    """(b) 16 staggered blips in two syllable groups: rising hoo, falling ray."""
    out = np.zeros(N)
    count = 16
    # Group 1 ("hoo", rising): 8 blips, onsets 0.05-0.35 s, pitch rising.
    # Group 2 ("ray", falling): 8 blips, onsets 0.30-0.60 s, pitch falling.
    for i in range(count):
        if i < 8:
            onset = rng.uniform(0.05, 0.35)
            dur = rng.uniform(0.20, 0.40)
            f0 = rng.uniform(180.0, 260.0)
            f1 = f0 * rng.uniform(1.15, 1.35)  # rising
            amp = rng.uniform(0.10, 0.16)
        else:
            onset = rng.uniform(0.30, 0.60)
            dur = rng.uniform(0.15, 0.35)
            f0 = rng.uniform(260.0, 350.0)
            f1 = f0 * rng.uniform(0.70, 0.88)  # falling
            amp = rng.uniform(0.12, 0.18)
        # Jitter on the base pitch.
        f0 *= rng.uniform(0.95, 1.05)
        blip = voice_blip(rng, onset, dur, f0, f1)
        start = int(onset * SR)
        end = min(N, start + len(blip))
        out[start:end] += amp * blip[:end - start]
    return out


def yay_chirps(rng: np.random.Generator) -> np.ndarray:
    """(c) A few high 'yay' chirps on top for sparkle."""
    out = np.zeros(N)
    for _ in range(4):
        onset = rng.uniform(0.15, 0.90)
        dur = rng.uniform(0.10, 0.20)
        n = int(dur * SR)
        t = np.arange(n) / SR
        f0 = rng.uniform(750.0, 950.0)
        f1 = rng.uniform(1400.0, 1800.0)
        phase = 2.0 * np.pi * np.cumsum(np.linspace(f0, f1, n)) / SR
        chirp = np.sin(phase) + 0.3 * np.sin(2.0 * phase)
        env = np.sin(np.pi * np.arange(n) / n)  # smooth in/out
        start = int(onset * SR)
        end = min(N, start + n)
        out[start:end] += 0.10 * chirp[:end - start] * env[:end - start]
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Synthesize cheer.wav from scratch.")
    ap.add_argument("--out", default=None,
                    help="Output path (default: audio/cheer.wav next to tools/)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    out_path = args.out or os.path.join(here, "..", "audio", "cheer.wav")
    out_path = os.path.normpath(out_path)

    rng = np.random.default_rng(SEED)

    mix = (0.55 * crowd_bed(rng)
           + hoo_ray_blips(rng)
           + yay_chirps(rng))

    # Fade out the last 0.3 s.
    fade = int(0.30 * SR)
    mix[-fade:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(fade) / fade)

    # Normalize to -3 dBFS peak (0.7079).
    peak = np.max(np.abs(mix))
    mix = mix / peak * 10 ** (-3.0 / 20.0)

    pcm = np.clip(mix, -1.0, 1.0)
    pcm16 = (pcm * 32767).astype(np.int16)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with wave.open(out_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)  # 16-bit
        w.setframerate(SR)
        w.writeframes(pcm16.tobytes())

    print(f"Wrote {out_path}")
    print(f"  samples={len(pcm16)} duration={len(pcm16) / SR:.2f}s "
          f"sr={SR} mono 16-bit")
    print(f"  peak={np.max(np.abs(pcm)):.4f} "
          f"({20 * np.log10(np.max(np.abs(pcm))):.1f} dBFS) "
          f"rms={np.sqrt(np.mean(pcm ** 2)):.4f}")
    print(f"  size={os.path.getsize(out_path)} bytes")


if __name__ == "__main__":
    main()
