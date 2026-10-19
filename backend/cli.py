#!/usr/bin/env python3
"""
CLI-проверка распознавания без приложения.

  .venv/bin/python backend/cli.py sample.wav
  .venv/bin/python backend/cli.py sample.wav --model v3_e2e_ctc --device cpu
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from worker import Engine, decode_pcm, trim_silence  # noqa: E402


def load_audio(path: str) -> tuple[bytes, int]:
    """Читает wav через ffmpeg в s16le mono 16 kHz."""
    import subprocess

    out = subprocess.run(
        [
            "ffmpeg", "-nostdin", "-threads", "0", "-i", path,
            "-f", "s16le", "-acodec", "pcm_s16le", "-ac", "1", "-ar", "16000", "-",
        ],
        capture_output=True,
        check=True,
    ).stdout
    return out, 16000


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", nargs="+", help="пути к аудиофайлам")
    parser.add_argument("--model", default="v3_e2e_rnnt")
    parser.add_argument("--device", default="auto")
    args = parser.parse_args()

    engine = Engine(args.model, args.device)

    for path in args.audio:
        raw, sr = load_audio(path)
        import base64

        started = time.perf_counter()
        audio = decode_pcm(base64.b64encode(raw).decode(), sr)
        audio = trim_silence(audio)
        text = engine.transcribe(audio)
        elapsed = (time.perf_counter() - started) * 1000
        print(f"\n{path}  ({audio.size / 16000:.1f}s, {elapsed:.0f} ms)")
        print(f"  {text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
