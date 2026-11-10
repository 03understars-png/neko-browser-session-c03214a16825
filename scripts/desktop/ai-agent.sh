#!/usr/bin/env bash
set -u
work=$1
mode=${2:-}
exec >>"$work/agent.log" 2>&1
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
state() {
  printf '%s\n' "$*" >"$work/agent-state"
  [[ -n ${CB_AGENT_MARK:-} ]] && printf '%s\n' "$*" >"$CB_AGENT_MARK"   # model-only: the desktop's copy
  log "state: $*"
}
lim() { perl -e 'alarm shift; exec @ARGV' "$@" 2>/dev/null || timeout "$@"; }
renice -n 10 $$ >/dev/null 2>&1
state checking
os=$(uname -s)
CONTEXT=65536
OLLAMA_HOME="$HOME/.local/ollama"
export PATH="$HOME/.local/bin:$OLLAMA_HOME/bin:$OLLAMA_HOME:$PATH"

HOST_MARK=/etc/compute-base-agent-host
if [[ $mode != model-only && -f $HOST_MARK ]]; then
  state "waiting for the model on the notebook machine"
  for _ in $(seq 1 720); do grep -q -E '^(ready|skipped|failed)' "$HOST_MARK" && break; sleep 5; done
  grep -q '^ready' "$HOST_MARK" || { state "$(cat "$HOST_MARK")"; exit 0; }
  MODEL=$(cut -d' ' -f2 "$HOST_MARK")
else
  if [[ $os == Darwin ]]; then
    ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    cores=$(sysctl -n hw.ncpu)
  else
    ram_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1048576 ))
    cores=$(nproc)
  fi
  gpu_mb=0
  command -v nvidia-smi >/dev/null 2>&1 &&
    gpu_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -n | tail -n 1 | tr -dc 0-9)
  gpu_mb=${gpu_mb:-0}
  if (( gpu_mb >= 12000 )) || [[ $os == Darwin && $ram_gb -ge 14 ]] || (( ram_gb >= 24 && cores >= 16 )); then
    MODEL=gemma4:12b-it-qat
  elif (( ram_gb >= 9 )); then
    MODEL=gemma4:e4b-it-qat
  else
    state "skipped this machine has ${ram_gb} GB; the desktop needs most of it"
    exit 0
  fi
  log "machine: ${ram_gb} GB, ${cores} cores, GPU ${gpu_mb} MB: $MODEL"

  state "installing Ollama"
  if ! "$OLLAMA_HOME/bin/ollama" --version >/dev/null 2>&1 && ! "$OLLAMA_HOME/ollama" --version >/dev/null 2>&1; then
    mkdir -p "$OLLAMA_HOME"
    release=https://github.com/ollama/ollama/releases/latest/download
    if [[ $os == Darwin ]]; then
      curl -fsSL --retry 3 "$release/ollama-darwin.tgz" | tar -xz -C "$OLLAMA_HOME" || { state "failed Ollama did not download"; exit 1; }
    else
      arch=amd64; [[ $(uname -m) == aarch64 ]] && arch=arm64
      unzst() { zstd -dc; }
      command -v zstd >/dev/null 2>&1 || {
        python3 -c 'import zstandard' 2>/dev/null || python3 -m pip install -q --user zstandard >/dev/null 2>&1
        unzst() { python3 -c 'import sys, zstandard; zstandard.ZstdDecompressor().copy_stream(sys.stdin.buffer, sys.stdout.buffer)'; }
      }
      curl -fsSL --retry 3 "$release/ollama-linux-$arch.tar.zst" | unzst | tar -x -C "$OLLAMA_HOME" ||
        { state "failed Ollama did not download"; exit 1; }
    fi
  fi
  ollama=$(command -v ollama || true)
  [[ -x $ollama ]] || { state "failed Ollama is not runnable"; exit 1; }
  log "ollama: $("$ollama" --version 2>&1 | tail -n 1)"
  if ! curl -fsS --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    OLLAMA_HOST=127.0.0.1:11434 OLLAMA_CONTEXT_LENGTH=$CONTEXT OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 \
      OLLAMA_KEEP_ALIVE=-1 OLLAMA_NUM_PARALLEL=2 OLLAMA_MAX_LOADED_MODELS=1 \
      nice -n 10 bash -c '"$0" serve </dev/null >>"$1/ollama.log" 2>&1 & echo $! >"$1/ollama.pid"' "$ollama" "$work"   # not nohup: it refuses without a terminal
    for _ in {1..60}; do curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break; sleep 1; done
  fi
  curl -fsS --max-time 3 http://127.0.0.1:11434/api/version >/dev/null || { state "failed Ollama did not start"; exit 1; }

  state "downloading $MODEL"
  for attempt in 1 2 3; do
    "$ollama" pull "$MODEL" >>"$work/ollama-pull.log" 2>&1 && break
    sleep 10
  done
  "$ollama" show "$MODEL" >/dev/null 2>&1 || { state "failed $MODEL did not download"; exit 1; }
  {
    printf 'FROM %s\nPARAMETER num_ctx %s\n' "$MODEL" "$CONTEXT"
    (( cores > 2 )) && printf 'PARAMETER num_thread %s\n' "$(( cores - 1 ))"
    [[ $os == Darwin ]] && printf 'PARAMETER num_gpu 0\n'
  } >"$work/Modelfile"
  "$ollama" create cb-gemma4 -f "$work/Modelfile" >>"$work/ollama-pull.log" 2>&1 || { state "failed the model could not be set up"; exit 1; }
  curl -fsS --max-time 600 http://127.0.0.1:11434/api/generate -d '{"model":"cb-gemma4","prompt":"","keep_alive":-1}' >/dev/null ||
    log "the model did not load yet; it loads at the first task"
fi
if [[ $mode == model-only ]]; then
  state "ready $MODEL"
  exit 0
fi

state "installing Hermes Agent"
if ! hermes --version >/dev/null 2>&1; then
  curl -fsSL --retry 3 https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive \
    >>"$work/hermes-install.log" 2>&1
fi
hermes --version >/dev/null 2>&1 || { state "failed Hermes did not install (hermes-install.log)"; exit 1; }
log "hermes: $(hermes --version 2>&1 | head -n 1)"
hermes config set model.provider custom
hermes config set model.base_url http://127.0.0.1:11434/v1
hermes config set model.default cb-gemma4
hermes config set model.context_length "$CONTEXT"
hermes config set approvals.mode off
hermes config set auxiliary.title_generation.enabled false   # a model call per chat for its title, not needed here
for tool in computer_use browser web terminal file; do
  hermes tools enable "$tool" --platform cli >/dev/null 2>&1 || log "tool $tool: not enabled ($(hermes tools enable "$tool" --platform cli 2>&1 | tail -n 1))"
done
for tool in image_gen tts connections cronjob delegation session_search clarify code_execution; do
  hermes tools disable "$tool" --platform cli >/dev/null 2>&1
done
hermes computer-use doctor >>"$work/agent.log" 2>&1 || true
if [[ $(cat /proc/1/comm 2>/dev/null) == s6-svscan* ]]; then
  HERMES_GATEWAY_NO_SUPERVISE=1 setsid hermes gateway run --no-supervise </dev/null >>"$work/gateway.log" 2>&1 &
  sleep 5
  log "gateway: $(tail -n 1 "$work/gateway.log" 2>/dev/null)"
fi
cua=$(command -v cua-driver || find "$HOME/.hermes" -name cua-driver -type f -perm -u+x 2>/dev/null | head -n 1)
[[ -n $cua ]] && printf '%s\n' "$cua" >"$work/agent-cua"
state "ready $MODEL"
