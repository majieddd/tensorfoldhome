#!/bin/bash
# Installs (or repairs) the backend TensorFold Home drives: the scripts, TensorFold 1.0 (Homebrew), TensorFold 0.6
# (its own Python environment; it runs the 9B models and the endpoint), launchd agents and the tfctl command.
# Keeps an existing config.env, models.conf, Python environments and Open WebUI data.
#   install.sh            everything except Open WebUI
#   install.sh --webui    also Open WebUI (a browser chat on the same endpoint, about 2 GB)
# TensorFold Home runs this from Server > Set up; it can also be run by hand.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HOME/Library/Application Support/TensorFoldLauncher"
REPO_URL=https://github.com/ashhart/TensorFold.git
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_ENV_HINTS=1
WEBUI=0
[[ ${1:-} == --webui ]] && WEBUI=1
step() { printf '\n==> %s\n' "$*"; }

[[ $(uname -m) == arm64 ]] || { echo "TensorFold needs an Apple-silicon Mac."; exit 1; }
command -v brew >/dev/null || { echo "Homebrew is required first: https://brew.sh"; exit 1; }

step "Copying the scripts to $ROOT"
mkdir -p "$ROOT"/{bin,launchd,logs,state,webui-data}
find "$SRC/bin" -maxdepth 1 -type f ! -name '.*' -exec cp {} "$ROOT/bin/" \;
chmod 755 "$ROOT"/bin/tfctl "$ROOT"/bin/tf-engine "$ROOT"/bin/tf-webui "$ROOT"/bin/tf-update "$ROOT"/bin/tf-gateway.py
[[ -f $SRC/VERSION ]] && cp "$SRC/VERSION" "$ROOT/bin/.bundle-version"
[[ -f $ROOT/config.env ]] || cp "$SRC/config.env.default" "$ROOT/config.env"
[[ -f $ROOT/models.conf ]] || cp "$SRC/models.conf" "$ROOT/models.conf"
[[ -f $ROOT/state/webui_secret ]] || (umask 077; openssl rand -hex 32 >"$ROOT/state/webui_secret")

if ! command -v uv >/dev/null; then step "Installing uv (Python environments)"; brew install uv; fi

if ! command -v tensorfold >/dev/null; then
  step "Installing TensorFold 1.0 from Homebrew"
  brew install ashhart/tensorfold/tensorfold
fi
tensorfold --version || true

if [[ ! -x $ROOT/venv-tf06/bin/tensorfold ]]; then
  step "Installing TensorFold 0.6 (python-0.6 branch)"
  uv venv "$ROOT/venv-tf06" --python 3.12
  VIRTUAL_ENV="$ROOT/venv-tf06" uv pip install "tensorfold[grammar] @ git+$REPO_URL@python-0.6"
fi
# The grammar extra (xgrammar, with PyTorch, ~0.5 GB) lets requests ask for JSON-schema output, which Hermes and other
# agents use (Hermes's chat titles, for one). Added to existing installs too.
"$ROOT/venv-tf06/bin/python" -c 'import xgrammar' 2>/dev/null ||
  { step "Adding structured-output support (xgrammar)"; VIRTUAL_ENV="$ROOT/venv-tf06" uv pip install "xgrammar>=0.2.8,<0.3"; }

if ((WEBUI)) && [[ ! -x $ROOT/venv-webui/bin/open-webui ]]; then
  step "Installing Open WebUI"
  uv venv "$ROOT/venv-webui" --python 3.12
  VIRTUAL_ENV="$ROOT/venv-webui" uv pip install open-webui
fi

step "Linking tfctl into ~/.local/bin"
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/bin/tfctl" "$HOME/.local/bin/tfctl"

step "Writing the launchd agents"
"$ROOT/bin/tfctl" install-agents
# shellcheck disable=SC1091
source "$ROOT/config.env"
if [[ ${ENDPOINT_AT_LOGIN:-1} == 1 ]]; then
  "$ROOT/bin/tfctl" gateway restart >/dev/null && echo "endpoint running at http://127.0.0.1:${GATEWAY_PORT:-8484}/v1"
fi

step "Done"
echo "Models download from Hugging Face the first time they start (about 5 GB for a 9B model)."
