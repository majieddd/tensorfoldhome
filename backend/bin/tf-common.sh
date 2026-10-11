# Shared helpers for TensorFold Home's backend scripts (sourced, not executed). The folder keeps the
# TensorFoldLauncher name from the first version, so existing installs and Hermes configs keep working.

ROOT="${TF_LAUNCHER_ROOT:-$HOME/Library/Application Support/TensorFoldLauncher}"
LOGS="$ROOT/logs"
STATE="$ROOT/state"
DOMAIN="gui/$(id -u)"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_ENV_HINTS=1

load_config() {
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  : "${MODEL:=qwythos-9b}" "${CONTEXT:=65536}" "${THINKING:=off}" "${IDLE_MINUTES:=30}"
  : "${GATEWAY_PORT:=8484}" "${ENGINE_PORT:=18484}" "${WEBUI_PORT:=3000}" "${SERVED_NAME:=tensorfold}"
  : "${ENDPOINT_AT_LOGIN:=1}" "${UPDATE_HOUR:=4}" "${UPDATE_MINUTE:=30}"
  : "${SHARE_ON_NETWORK:=0}" "${REQUIRE_KEY:=0}" "${AUTO_UPDATE:=1}"
  if [[ -z ${MEMORY_MODE:-} ]]; then if ((IDLE_MINUTES > 0)); then MEMORY_MODE=idle; else MEMORY_MODE=always; fi; fi
}

# Print the models.conf line for a key (key|label|engine|repo), or fail.
model_line() {
  grep -v '^\s*#' "$ROOT/models.conf" | awk -F'|' -v k="$1" '$1 == k { print; found = 1 } END { exit !found }'
}

model_field() { # model_field KEY N  (1=key 2=label 3=engine 4=repo)
  model_line "$1" | cut -d'|' -f"$2"
}

set_config() { # set_config KEY VALUE
  local file="$ROOT/config.env"
  if grep -q "^$1=" "$file"; then
    /usr/bin/sed -i '' "s|^$1=.*|$1=$2|" "$file"
  else
    printf '%s=%s\n' "$1" "$2" >>"$file"
  fi
}

http_ok() { # http_ok URL  -> 0 when the URL answers 2xx within 2s
  /usr/bin/curl -fsS -o /dev/null --max-time 2 "$1" 2>/dev/null
}

is_loaded() { launchctl print "$DOMAIN/$1" >/dev/null 2>&1; }

notify() { # notify "message" — macOS notification, ignored when no GUI session
  /usr/bin/osascript -e "display notification \"${1//\"/\\\"}\" with title \"TensorFold\"" >/dev/null 2>&1 || true
}

trim_log() { # keep logs under ~20 MB
  [[ -f $1 ]] && (($(stat -f %z "$1") > 20000000)) && tail -c 5000000 "$1" >"$1.tmp" && mv "$1.tmp" "$1"
  return 0
}
