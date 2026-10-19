#!/usr/bin/env python3
"""
ASR sidecar for Transcribator.

Протокол: построчный JSON через stdin/stdout (UTF-8, один объект на строку).

  -> {"id": 1, "cmd": "ping"}
  -> {"id": 2, "cmd": "transcribe", "pcm_b64": "<int16 LE mono>", "sample_rate": 16000}
  -> {"id": 3, "cmd": "shutdown"}

  <- {"event": "ready", "model": "v3_e2e_rnnt", "device": "mps", "load_ms": 4200}
  <- {"id": 2, "ok": true, "text": "Привет, мир.", "audio_ms": 3200, "decode_ms": 640}
  <- {"id": 2, "ok": false, "error": "..."}

stdout используется только под протокол, все логи идут в stderr.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import traceback

import numpy as np

PROTOCOL_VERSION = 1
# transcribe() в GigaAM рассчитан на аудио до 25 секунд, режем безопасные куски
MAX_CHUNK_SEC = 20.0
TARGET_SAMPLE_RATE = 16000


def log(msg: str) -> None:
    print(f"[worker] {msg}", file=sys.stderr, flush=True)


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# ---------------------------------------------------------------- audio utils


def trim_silence(
    audio: np.ndarray,
    sample_rate: int = TARGET_SAMPLE_RATE,
    frame_ms: int = 20,
    pad_ms: int = 150,
) -> np.ndarray:
    """Обрезает тишину по краям по энергии кадров (простая, но быстрая VAD)."""
    hop = max(1, int(sample_rate * frame_ms / 1000))
    if audio.size <= hop * 2:
        return audio

    n_frames = audio.size // hop
    frames = audio[: n_frames * hop].reshape(n_frames, hop)
    rms = np.sqrt(np.mean(frames.astype(np.float32) ** 2, axis=1) + 1e-12)

    peak = float(rms.max())
    if peak < 3e-4:  # в записи только шум/тишина
        return audio[:0]

    noise = float(np.percentile(rms, 20))
    threshold = max(noise * 3.0, peak * 0.02, 5e-4)
    active = np.nonzero(rms >= threshold)[0]
    if active.size == 0:
        return audio[:0]

    pad = int(sample_rate * pad_ms / 1000)
    start = max(0, int(active[0]) * hop - pad)
    end = min(audio.size, (int(active[-1]) + 1) * hop + pad)
    return audio[start:end]


def split_long_audio(
    audio: np.ndarray,
    sample_rate: int = TARGET_SAMPLE_RATE,
    max_sec: float = MAX_CHUNK_SEC,
) -> list[np.ndarray]:
    """Режет длинную запись на куски <= max_sec, стараясь резать по тишине."""
    max_len = int(max_sec * sample_rate)
    if audio.size <= max_len:
        return [audio]

    chunks: list[np.ndarray] = []
    pos = 0
    while audio.size - pos > max_len:
        window_start = pos + int(max_len * 0.7)
        window_end = pos + max_len
        hop = int(sample_rate * 0.02)
        window = audio[window_start:window_end]
        n_frames = window.size // hop
        cut = window_end
        if n_frames > 1:
            frames = window[: n_frames * hop].reshape(n_frames, hop).astype(np.float32)
            rms = np.sqrt(np.mean(frames**2, axis=1) + 1e-12)
            cut = window_start + int(np.argmin(rms)) * hop
        chunks.append(audio[pos:cut])
        pos = cut
    chunks.append(audio[pos:])
    return [c for c in chunks if c.size > 0]


def decode_pcm(b64: str, sample_rate: int) -> np.ndarray:
    """base64 (int16 LE моно) -> float32 [-1, 1], при необходимости ресемплим в 16k."""
    raw = base64.b64decode(b64)
    pcm = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if sample_rate != TARGET_SAMPLE_RATE and pcm.size:
        pcm = resample_linear(pcm, sample_rate, TARGET_SAMPLE_RATE)
    return pcm


def resample_linear(audio: np.ndarray, src_rate: int, dst_rate: int) -> np.ndarray:
    if src_rate == dst_rate or audio.size == 0:
        return audio
    duration = audio.size / float(src_rate)
    new_size = int(round(duration * dst_rate))
    if new_size <= 0:
        return audio[:0]
    src_idx = np.linspace(0.0, audio.size - 1, new_size, dtype=np.float64)
    return np.interp(src_idx, np.arange(audio.size), audio).astype(np.float32)


# --------------------------------------------------------------------- engine


class Engine:
    """Обёртка над gigaam-моделью: держит веса в памяти и транскрибирует пачки."""

    def __init__(self, model_name: str, device: str) -> None:
        import torch

        import gigaam

        self.torch = torch
        self.model_name = model_name
        if device == "auto":
            device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.device = torch.device(device)

        if self.device.type == "cpu":
            torch.set_num_threads(max(1, (os.cpu_count() or 4) // 2))

        started = time.perf_counter()
        log(f"loading {model_name} on {self.device}")
        self.model = self._load(model_name)
        self.load_ms = int((time.perf_counter() - started) * 1000)
        self.warmup_ms = 0
        log(f"loaded in {self.load_ms} ms")

        # Прогрев: первый инференс на MPS/Metal компилирует графы и в разы медленнее.
        warmup_started = time.perf_counter()
        try:
            rng = np.random.default_rng(0)
            self._transcribe_chunk((rng.standard_normal(TARGET_SAMPLE_RATE * 2) * 1e-3).astype(np.float32))
        except Exception:  # noqa: BLE001
            traceback.print_exc()
        self.warmup_ms = int((time.perf_counter() - warmup_started) * 1000)
        log(f"warmup in {self.warmup_ms} ms")

    @staticmethod
    def _purge_cache(model_name: str) -> None:
        """Удаляет битые файлы модели из кэша (~/.cache/gigaam)."""
        import gigaam

        name = model_name if model_name in gigaam._MODEL_HASHES else f"v3_{model_name}"
        cache = os.path.expanduser("~/.cache/gigaam")
        for suffix in (".ckpt", "_tokenizer.model"):
            path = os.path.join(cache, name + suffix)
            if os.path.exists(path):
                os.remove(path)
                log(f"removed broken cache file {path}")

    def _load(self, model_name: str):
        """Загружает модель; при битом кэше (недокачанный ckpt) качает заново один раз."""
        import gigaam

        kwargs = dict(fp16_encoder=self.device.type != "cpu", device=self.device)
        try:
            return gigaam.load_model(model_name, **kwargs)
        except AssertionError as err:
            if "checksum" not in str(err):
                raise
            log(f"checksum mismatch: {err}")
            self._purge_cache(model_name)
            return gigaam.load_model(model_name, **kwargs)

    @property
    def head_dtype(self):
        try:
            return next(self.model.head.parameters()).dtype
        except (AttributeError, StopIteration):
            return self.torch.float32

    def _transcribe_chunk(self, audio: np.ndarray) -> str:
        torch = self.torch
        wav = torch.from_numpy(np.ascontiguousarray(audio)).unsqueeze(0)
        wav = wav.to(self.device).to(torch.float32)
        length = torch.full([1], wav.shape[-1], device=self.device, dtype=torch.long)
        encoded, encoded_len = self.model.forward(wav, length)
        if encoded.dtype != self.head_dtype:
            encoded = encoded.to(self.head_dtype)
        text, _ = self.model._decode(encoded, encoded_len, length)[0]
        return text

    def transcribe(self, audio: np.ndarray) -> str:
        torch = self.torch
        with torch.inference_mode():
            return " ".join(
                t.strip() for t in (self._transcribe_chunk(c) for c in split_long_audio(audio)) if t.strip()
            )


# ----------------------------------------------------------------------- main


def handle(engine: Engine, req: dict) -> dict:
    cmd = req.get("cmd")
    req_id = req.get("id")

    if cmd == "ping":
        return {"id": req_id, "ok": True, "ready": True, "protocol": PROTOCOL_VERSION}

    if cmd == "shutdown":
        raise SystemExit(0)

    if cmd != "transcribe":
        return {"id": req_id, "ok": False, "error": f"unknown cmd: {cmd!r}"}

    started = time.perf_counter()
    audio = decode_pcm(req.get("pcm_b64", ""), int(req.get("sample_rate", TARGET_SAMPLE_RATE)))
    audio_ms = int(audio.size / TARGET_SAMPLE_RATE * 1000)

    if audio.size < TARGET_SAMPLE_RATE * 0.15:
        return {
            "id": req_id,
            "ok": True,
            "text": "",
            "audio_ms": audio_ms,
            "decode_ms": 0,
            "skipped": "too_short",
        }

    audio = trim_silence(audio)
    if audio.size < TARGET_SAMPLE_RATE * 0.15:
        return {
            "id": req_id,
            "ok": True,
            "text": "",
            "audio_ms": audio_ms,
            "decode_ms": int((time.perf_counter() - started) * 1000),
            "skipped": "silence",
        }

    text = engine.transcribe(audio)
    decode_ms = int((time.perf_counter() - started) * 1000)
    log(f"transcribed {audio_ms} ms audio in {decode_ms} ms: {text!r}")
    return {
        "id": req_id,
        "ok": True,
        "text": text.strip(),
        "audio_ms": audio_ms,
        "decode_ms": decode_ms,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribator ASR worker")
    parser.add_argument("--model", default=os.environ.get("TRANSCRIBATOR_MODEL", "v3_e2e_rnnt"))
    parser.add_argument("--device", default=os.environ.get("TRANSCRIBATOR_DEVICE", "auto"))
    args = parser.parse_args()

    try:
        engine = Engine(args.model, args.device)
    except Exception as err:  # noqa: BLE001
        traceback.print_exc()
        emit({"event": "error", "error": f"{type(err).__name__}: {err}"})
        return 1

    emit(
        {
            "event": "ready",
            "protocol": PROTOCOL_VERSION,
            "model": engine.model_name,
            "device": str(engine.device),
            "load_ms": engine.load_ms,
            "warmup_ms": engine.warmup_ms,
        }
    )

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as err:
            emit({"event": "error", "error": f"bad json: {err}"})
            continue

        try:
            emit(handle(engine, req))
        except SystemExit:
            return 0
        except Exception as err:  # noqa: BLE001
            traceback.print_exc()
            emit({"id": req.get("id"), "ok": False, "error": f"{type(err).__name__}: {err}"})

    return 0


if __name__ == "__main__":
    sys.exit(main())
