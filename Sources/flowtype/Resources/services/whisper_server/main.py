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
from fastapi import FastAPI, File, UploadFile
from fastapi.responses import JSONResponse
import uvicorn

# Global state
_model_loaded = False
_model_loading = False
_model_error: Optional[str] = None
_server_port: int = 0
_args: argparse.Namespace

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
        )
        print("[whisper] Model loaded successfully", flush=True)
        _model_loaded = True
    except Exception as e:
        print(f"[whisper] Model loading failed: {e}", flush=True, file=sys.stderr)
        _model_error = str(e)
    finally:
        _model_loading = False


async def _background_load_model():
    global _model_loading
    _model_loading = True
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(executor, _load_model_sync)


@app.on_event("startup")
async def startup():
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
            ),
        )

        # Debug: log full result structure
        result_type = type(result).__name__
        if hasattr(result, 'get'):
            text = result.get("text", "").strip()
            segments = result.get("segments", [])
            print(f"[whisper] Result type={result_type}, segments={len(segments)}, text_len={len(text)}", flush=True)
            if segments:
                for i, seg in enumerate(segments[:5]):
                    seg_text = seg.get("text", "") if hasattr(seg, 'get') else str(seg)
                    print(f"[whisper]   seg[{i}]: {seg_text[:60]}", flush=True)
            # Fallback: build text from segments if top-level text is empty or suspiciously short
            if not text and segments:
                text = " ".join(
                    (seg.get("text", "") if hasattr(seg, 'get') else str(seg)).strip()
                    for seg in segments
                ).strip()
                print(f"[whisper] Rebuilt text from segments: {text[:80]}", flush=True)
        else:
            # Result might be a dataclass or namedtuple
            text = getattr(result, 'text', str(result)).strip()
            print(f"[whisper] Result type={result_type}, text={text[:80]}", flush=True)

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
