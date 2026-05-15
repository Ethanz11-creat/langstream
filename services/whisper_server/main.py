#!/usr/bin/env python3
"""Local MLX Whisper ASR server for Flowtype.

Runs an HTTP server that accepts WAV audio and returns transcription text.
Model is loaded eagerly on startup so first-request latency is minimal.
"""

import argparse
import asyncio
import io
import json
import os
import sys
import tempfile
import time
import wave
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

import numpy as np
import torch
from fastapi import FastAPI, File, UploadFile
from fastapi.responses import JSONResponse
import uvicorn

# Global state
_model_loaded = False
_model_loading = False
_model_error: Optional[str] = None
_server_port: int = 0
_args: argparse.Namespace
_vad_model = None
_vad_ready = False
_previous_speech_ratio: float = 0.0

app = FastAPI(title="Flowtype Whisper Server")
executor = ThreadPoolExecutor(max_workers=1)


def _load_model_sync():
    """Load model by running a dummy inference so weights are cached in memory."""
    global _model_loaded, _model_loading, _model_error
    try:
        import mlx_whisper

        print(f"[whisper] Loading model: {_args.model}", flush=True)
        # Run a 1-second silent buffer to warm up the model
        dummy = np.zeros(16000, dtype=np.float32)
        mlx_whisper.transcribe(
            dummy,
            path_or_hf_repo=_args.model,
            language=_args.language if _args.language != "auto" else None,
            verbose=False,
            condition_on_previous_text=False,
        )
        print("[whisper] Model loaded successfully", flush=True)
        _model_loaded = True
    except Exception as e:
        print(f"[whisper] Model loading failed: {e}", flush=True, file=sys.stderr)
        _model_error = str(e)
    finally:
        _model_loading = False


def _load_vad_sync():
    """Load Silero VAD model (CPU only, ~2MB, ~1s)."""
    global _vad_model, _vad_ready
    try:
        model, utils = torch.hub.load(
            repo_or_dir="snakers4/silero-vad",
            model="silero_vad",
            trust_repo=True,
        )
        _vad_model = model
        _vad_ready = True
        print("[vad] Silero VAD model loaded", flush=True)
    except Exception as e:
        print(f"[vad] Failed to load VAD model: {e}", flush=True, file=sys.stderr)


async def _background_load_model():
    global _model_loading
    _model_loading = True
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(executor, _load_model_sync)


@app.on_event("startup")
async def startup():
    loop = asyncio.get_event_loop()
    # Load VAD synchronously first (fast, ~1s)
    await loop.run_in_executor(None, _load_vad_sync)
    # Then start Whisper loading in background
    asyncio.create_task(_background_load_model())


@app.get("/health")
async def health():
    stage = "model_loaded" if _model_loaded else "model_loading" if _model_loading else "error" if _model_error else "process_started"
    return JSONResponse(
        content={
            "status": "ok" if _model_loaded else "warming_up",
            "stage": stage,
            "model": _args.model,
            "language": _args.language,
            "progress": None,
            "error": _model_error,
        }
    )


@app.post("/vad")
async def vad(file: UploadFile = File(...)):
    global _previous_speech_ratio

    if not _vad_ready or _vad_model is None:
        return JSONResponse(
            status_code=503,
            content={"error": "VAD model not loaded"},
        )

    try:
        content = await file.read()
        audio = _load_audio_from_bytes(content)
    except Exception as e:
        return JSONResponse(
            status_code=400,
            content={"error": f"Invalid audio: {e}"},
        )

    try:
        audio_tensor = torch.from_numpy(audio)
        # Get speech timestamps from Silero VAD
        speech_timestamps = _vad_model.get_speech_timestamps(
            audio_tensor, sampling_rate=16000,
            threshold=0.5,
            min_speech_duration_ms=100,
            min_silence_duration_ms=100,
        )

        sample_count = len(audio)
        duration_ms = sample_count / 16000 * 1000

        # Build speeches list
        speeches = []
        for ts in speech_timestamps:
            speeches.append({
                "start": round(ts["start"] / 16000, 3),
                "end": round(ts["end"] / 16000, 3),
            })

        # Compute has_speech and speech_ratio
        speech_samples = sum(ts["end"] - ts["start"] for ts in speech_timestamps)
        speech_ratio = round(speech_samples / sample_count, 3) if sample_count > 0 else 0.0
        has_speech = len(speech_timestamps) > 0

        # Compute trailing_silence_ms
        if speech_timestamps:
            last_speech_end = speech_timestamps[-1]["end"]
            trailing_silence_samples = sample_count - last_speech_end
            trailing_silence_ms = int(trailing_silence_samples / 16000 * 1000)
        else:
            trailing_silence_ms = int(duration_ms)

        # Compute suggest_cut
        suggest_cut = False
        if trailing_silence_ms >= 500 and speech_ratio < 0.3:
            suggest_cut = True
        elif _previous_speech_ratio > 0.8 and speech_ratio < 0.2:
            suggest_cut = True

        _previous_speech_ratio = speech_ratio

        return JSONResponse(content={
            "has_speech": has_speech,
            "speech_ratio": speech_ratio,
            "trailing_silence_ms": trailing_silence_ms,
            "suggest_cut": suggest_cut,
            "speeches": speeches,
        })
    except Exception as e:
        print(f"[vad] VAD inference failed: {e}", flush=True, file=sys.stderr)
        return JSONResponse(
            status_code=500,
            content={"error": str(e)},
        )


def _load_audio_from_bytes(content: bytes) -> np.ndarray:
    """Parse WAV bytes into a float32 numpy array at 16kHz (mono)."""
    buf = io.BytesIO(content)
    with wave.open(buf, "rb") as wf:
        nchannels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        nframes = wf.getnframes()
        raw = wf.readframes(nframes)

    # Convert raw bytes to numpy array based on sample width
    if sampwidth == 2:
        audio = np.frombuffer(raw, dtype=np.int16)
    elif sampwidth == 4:
        audio = np.frombuffer(raw, dtype=np.int32)
    elif sampwidth == 1:
        audio = np.frombuffer(raw, dtype=np.uint8)
        audio = (audio.astype(np.float32) - 128) / 128.0
        audio = (audio * 32767).astype(np.int16)
    else:
        raise ValueError(f"Unsupported sample width: {sampwidth}")

    # Convert to mono if stereo
    if nchannels == 2:
        audio = audio.reshape(-1, 2).mean(axis=1).astype(np.int16)
    elif nchannels > 2:
        audio = audio.reshape(-1, nchannels).mean(axis=1).astype(np.int16)

    # Convert int16 to float32 in range [-1.0, 1.0]
    audio = audio.astype(np.float32) / 32768.0

    # Resample to 16kHz if needed (simple linear interpolation)
    if framerate != 16000:
        # Use simple resampling
        ratio = 16000 / framerate
        new_length = int(len(audio) * ratio)
        indices = np.linspace(0, len(audio) - 1, new_length)
        audio = np.interp(indices, np.arange(len(audio)), audio).astype(np.float32)

    return audio


def _strip_repetitions(text: str, max_repeat: int = 3) -> str:
    """Detect and collapse consecutive repeated substrings (2-6 chars).

    Classic Whisper decoder-loop hallucination produces patterns like
    '回头回头回头...' (dozens of times). This catches them and collapses
    to a single occurrence.
    """
    if not text:
        return text
    original = text
    for pat_len in range(2, 7):
        out = []
        i = 0
        while i < len(text):
            if i + pat_len <= len(text):
                pat = text[i:i + pat_len]
                count = 1
                j = i + pat_len
                while j + pat_len <= len(text) and text[j:j + pat_len] == pat:
                    count += 1
                    j += pat_len
                if count >= max_repeat:
                    out.append(pat)
                    i = j
                    continue
            out.append(text[i])
            i += 1
        new_text = "".join(out)
        if len(new_text) < len(text):
            text = new_text
    if text != original:
        print(f"[whisper] Stripped repetitions: {len(original)} -> {len(text)} chars", flush=True)
    return text


@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    if not _model_loaded:
        return JSONResponse(
            status_code=503,
            content={"error": "Model not loaded yet", "stage": "model_loading"},
        )

    start_time = time.time()

    try:
        content = await file.read()
        audio = _load_audio_from_bytes(content)
    except Exception as e:
        print(f"[whisper] Failed to parse audio: {e}", flush=True, file=sys.stderr)
        return JSONResponse(
            status_code=400,
            content={"error": f"Invalid audio file: {e}"},
        )

    try:
        import mlx_whisper

        print(f"[whisper] Audio array: {len(audio)} samples, {len(audio)/16000:.2f}s", flush=True)

        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(
            executor,
            lambda: mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=_args.model,
                language=_args.language if _args.language != "auto" else None,
                verbose=False,
                condition_on_previous_text=False,
                hallucination_silence_threshold=2.0,
            ),
        )

        # Extract text and segments
        if hasattr(result, 'get'):
            raw_text = result.get("text", "").strip()
            segments = result.get("segments", [])
        else:
            raw_text = getattr(result, 'text', str(result)).strip()
            segments = []

        # Filter hallucinated segments by compression ratio
        if segments:
            good_segs = []
            for seg in segments:
                if not hasattr(seg, 'get'):
                    good_segs.append(seg)
                    continue
                cr = seg.get("compression_ratio", 0)
                nsp = seg.get("no_speech_prob", 0)
                seg_text = seg.get("text", "")
                if cr > 2.4 or nsp > 0.6:
                    print(f"[whisper] Filtered segment (cr={cr:.1f}, nsp={nsp:.2f}): {seg_text[:40]}", flush=True)
                    continue
                good_segs.append(seg)
            if len(good_segs) == len(segments):
                text = raw_text
            else:
                text = " ".join(
                    (s.get("text", "") if hasattr(s, 'get') else str(s)).strip()
                    for s in good_segs
                ).strip()
                print(f"[whisper] Segment filter: {len(segments)} -> {len(good_segs)} segments", flush=True)
        else:
            text = raw_text

        # Detect repetitive hallucination patterns in final text
        text = _strip_repetitions(text)

        print(f"[whisper] segments={len(segments)}, text_len={len(text)}", flush=True)

        duration = time.time() - start_time
        print(f"[whisper] Transcribed in {duration:.2f}s: {text[:80]}...", flush=True)
        return JSONResponse(content={"text": text})
    except Exception as e:
        print(f"[whisper] Transcription failed: {e}", flush=True, file=sys.stderr)
        import traceback
        traceback.print_exc()
        return JSONResponse(
            status_code=500,
            content={"error": str(e)},
        )


def find_free_port(start: int = 8765) -> int:
    import socket

    for port in range(start, start + 1000):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if s.connect_ex(("127.0.0.1", port)) != 0:
                return port
    raise RuntimeError("No free port found")


def main():
    global _args, _server_port

    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="mlx-community/whisper-large-v3-turbo")
    parser.add_argument("--language", default="auto", choices=["auto", "zh", "en"])
    parser.add_argument("--port", type=int, default=0, help="0 = auto-assign")
    _args = parser.parse_args()

    port = _args.port if _args.port else find_free_port()
    _server_port = port

    # Print the assigned port so the Swift launcher can read it
    print(f"SERVER_PORT={port}", flush=True)

    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning")
    server = uvicorn.Server(config)
    server.run()


if __name__ == "__main__":
    main()
