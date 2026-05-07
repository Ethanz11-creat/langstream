#!/bin/bash
set -e

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="$PROJECT_ROOT/services/whisper_server"

echo "=========================================="
echo "  Flowtype Whisper Local Setup"
echo "=========================================="

# 1. Check uv
if ! command -v uv &> /dev/null; then
    echo "❌ uv is not installed."
    echo "   Please install uv first:"
    echo "   curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi
echo "✅ uv found: $(which uv)"

# 2. Check Python version
PYTHON_VERSION=$(uv run python --version 2>/dev/null || echo "")
if [ -z "$PYTHON_VERSION" ]; then
    echo "⚠️  No Python found via uv. uv will use its managed Python."
else
    echo "✅ Python: $PYTHON_VERSION"
fi

# 3. Create venv if missing
cd "$SERVER_DIR"
if [ ! -d ".venv" ]; then
    echo "📦 Creating Python virtual environment..."
    uv venv
else
    echo "✅ Virtual environment already exists"
fi

# 4. Install dependencies
echo "📦 Installing Python dependencies..."
uv pip install -r requirements.txt

# 5. Pre-download model
echo "📦 Pre-downloading model mlx-community/whisper-large-v3-turbo..."
echo "   (This may take a while for the first time, ~1.6GB download)"
.venv/bin/python -c "
import mlx_whisper
import numpy as np
# Run a dummy transcription to trigger model download
dummy = np.zeros(16000, dtype=np.float32)
mlx_whisper.transcribe(dummy, path_or_hf_repo='mlx-community/whisper-large-v3-turbo', verbose=False)
print('✅ Model cached successfully')
"

echo ""
echo "=========================================="
echo "  ✅ Setup complete!"
echo "=========================================="
echo ""
echo "You can now start the Flowtype app."
echo "The local ASR service will be started automatically."
