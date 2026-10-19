#!/usr/bin/env bash
# Создаёт .venv и ставит GigaAM + torch (Apple Silicon: MPS-ускорение).
set -euo pipefail

cd "$(dirname "$0")/.."

PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv не найден. Ставлю через brew..." >&2
  brew install uv
fi

if [ ! -d .venv ]; then
  uv venv --python "$PYTHON_VERSION" .venv
fi

uv pip install --python .venv/bin/python \
  "gigaam @ git+https://github.com/salute-developers/GigaAM.git" \
  "torch>=2.6" \
  "torchaudio>=2.6"

echo
echo "Готово. Прогрев модели (скачает ~450 МБ весов в ~/.cache/gigaam):"
.venv/bin/python - <<'PY'
import gigaam
model = gigaam.load_model("v3_e2e_rnnt", device="mps")
print("model loaded ok:", type(model).__name__)
PY
