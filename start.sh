#!/usr/bin/env bash
set -euo pipefail

# Hy4-Flash SQ-128 on AMD Strix Halo (gfx1151) — one-command deploy.
#
# Uses the official prebuilt Strata image (nothing to build). Order of
# operations: preflight -> pull image (cached) -> run container -> wait for
# /health -> print endpoints. On first start the container downloads the
# ~181 GB model itself into the ${DATA_DIR} bind (resumable, SHA-256 verified).
# Idempotent: re-running skips pull/download and reports "already running" if
# the container is up.
#
# Precedence (highest first):
#   1. shell env vars already exported when you run ./start.sh
#   2. values in ./.env
#   3. inline defaults below

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    key="${key%$'\r'}"; value="${value%$'\r'}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    if [[ -z "${!key:-}" ]]; then
      export "${key}=${value}"
    fi
  done < "${SCRIPT_DIR}/.env"
fi

IMAGE="${IMAGE:-ghcr.io/niko1221/strata:0.2.19-rocm-gfx1151}"
CONTAINER_NAME="${CONTAINER_NAME:-hy4-flash-strata}"
PORT="${PORT:-8080}"                       # host publish port (container listens on 8080)
DATA_DIR="${DATA_DIR:-${SCRIPT_DIR}/strata-data}"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/.hy4.log}"
READY_TIMEOUT="${READY_TIMEOUT:-14400}"    # seconds; first start downloads ~181 GB
FAMILY="${FAMILY:-hy4-flash}"
MODEL="${MODEL:-SQ-128}"
# Optional passthroughs — empty means the container/vendor default
# (128K context, vision on, DFly2 drafting). Do NOT set DRAFTING: the hy4
# family drafter set is off|dfly2, while the entrypoint's DRAFTING values
# (auto|mtp|dflash2|off) belong to the Qwen families and could be rejected.
CONTEXT="${CONTEXT:-}" VISION="${VISION:-}" KV="${KV:-}" PARALLEL="${PARALLEL:-}" TUNE="${TUNE:-}" STRATA_SET="${STRATA_SET:-}"

# ---- preflight ---------------------------------------------------------------
command -v podman >/dev/null 2>&1 || { echo "podman is not on PATH"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is not on PATH"; exit 1; }

[[ -e /dev/kfd && -d /dev/dri ]] || { echo "ERROR: /dev/kfd and/or /dev/dri not found — AMD GPU driver not loaded"; exit 1; }
if ! id -nG | grep -qw render; then
  echo "warning: current user is not in the 'render' group; rootless /dev/kfd access may fail"
fi

# memlock: informational only. Rootless podman clamps --ulimit memlock to the
# user session's hard limit; the flag below takes effect if it's already raised.
# If the engine later dies with HSA "Cannot allocate memory" pin errors, raise it
# once (optional, needs sudo — see README troubleshooting).
MEMLOCK_HARD="$(systemctl show "user@$(id -u).service" -p LimitMEMLOCK --value 2>/dev/null || echo unknown)"
if [[ "${MEMLOCK_HARD}" != "infinity" ]]; then
  echo "note: user session memlock limit is '${MEMLOCK_HARD}' (not infinity)"
  echo "      if you see HSA pin errors at runtime, raise it once (see README troubleshooting)"
fi

# RAM: the SQ-128 footprint (~113 GB) fits 128 GiB unified memory at 128K
# context with zero SSD reads. On smaller boxes the engine still runs but
# streams experts from SSD — much slower. A 128 GiB Strix Halo reports ~124 GiB
# in MemTotal (firmware/GPU carve-out), so the warning threshold is 120 GiB.
RAM_GIB="$(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo)"
if (( RAM_GIB < 120 )); then
  echo "warning: ${RAM_GIB} GiB RAM detected; SQ-128 expects 128 GiB — on less it streams experts from SSD (set MODEL=SQ-96 or SQ-64 in .env)"
fi

# Disk: the three .strata files total 181.23 GB; plus image + engine headroom.
mkdir -p "${DATA_DIR}"
DISK_GB="$(df -BG --output=avail "${DATA_DIR}" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $1); print $1+0}')"
if [[ -n "${DISK_GB}" ]] && (( DISK_GB < 200 )); then
  echo "warning: only ${DISK_GB} GB free at ${DATA_DIR}; SQ-128 + Engram + Vision need ~182 GB plus headroom"
fi

# Port: rootless podman's pasta fails with a raw "Address already in use"
# error when something already listens on the publish port (e.g. another
# container). Fail early with an actionable message instead.
if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
  echo "ERROR: port ${PORT} is already in use on 127.0.0.1 — set PORT=<free port> in .env (or stop the conflicting service)"
  exit 1
fi

# ---- image -------------------------------------------------------------------
if podman image exists "${IMAGE}"; then
  echo "Image ${IMAGE} already present"
else
  echo "Pulling ${IMAGE} ..."
  podman pull "${IMAGE}"
fi

# ---- container lifecycle (idempotent) ----------------------------------------
if podman ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  if podman ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Container ${CONTAINER_NAME} is already running"
    exit 0
  fi
  # Stopped container exists — remove it so we can recreate with fresh config.
  echo "Removing stopped container ${CONTAINER_NAME} ..."
  podman rm "${CONTAINER_NAME}" >/dev/null
fi

echo "Starting ${CONTAINER_NAME} (port: ${PORT}, family: ${FAMILY}, model: ${MODEL})"
echo "Data dir: ${DATA_DIR} -> /data (model files land in Strata-data/models/${FAMILY}/)"

# --group-add keep-groups carries the host render group into the rootless
# container for /dev/kfd. --security-opt label=disable is required on SELinux
# hosts: the container policy denies mmap on /dev/kfd (hsa_device_t), so HSA
# queue setup dies with "Memory critical error ... Reason: Memory in use" at
# model load (root cause per ROCm/ROCm#6182). :z relabels the bind for SELinux.
# --ulimit memlock lets the engine pin RAM; --shm-size 2g and --stop-timeout
# 120 per DOCKER.md (the SIGTERM handler drains requests and unloads the model
# before exit). The port is bound to loopback: no API key by default, so the
# server stays local-only.
ENVS=()
RUN_CMD=()
if [[ -n "${API_KEY:-}" ]]; then
  # Keyed mode: the vendor entrypoint's `run` (env -> strata launch flags;
  # inside the container Strata never serves beyond loopback without a key).
  ENVS+=(-e "FAMILY=${FAMILY}" -e "MODEL=${MODEL}" -e "API_KEY=${API_KEY}")
  for v in CONTEXT VISION KV PARALLEL TUNE STRATA_SET; do
    [[ -n "${!v}" ]] && ENVS+=(-e "${v}=${!v}")
  done
else
  # Keyless mode (default): the entrypoint always turns a key on, so pass a
  # direct `strata launch --no-api-key` via the entrypoint's CMD passthrough.
  # `strata launch` exits once the server is up — the engine is a detached
  # daemon — so a keep-alive wrapper supervises it and mirrors the
  # entrypoint's stop contract: SIGTERM -> `strata launch --stop`.
  KFLAGS=(launch --no-tui --access lan --no-api-key --port 8080
          --data-dir /data/Strata-data --family "${FAMILY}" --model "${MODEL}"
          --save-preset nokey)
  [[ -n "${CONTEXT}" ]] && KFLAGS+=(--context "${CONTEXT}")
  [[ -n "${VISION}" ]] && KFLAGS+=(--vision "${VISION}")
  [[ -n "${KV}" ]] && KFLAGS+=(--kv "${KV}")
  [[ -n "${PARALLEL}" ]] && KFLAGS+=(--parallel "${PARALLEL}")
  [[ -n "${TUNE}" ]] && KFLAGS+=(--tune "${TUNE}")
  if [[ -n "${STRATA_SET}" ]]; then
    for kv in ${STRATA_SET}; do KFLAGS+=(--set "${kv}"); done
  fi
  RUN_CMD=(sh -c 'S=/opt/strata/terminal/bin/strata
on_stop(){ "$S" launch --stop --preset nokey >/dev/null 2>&1; exit 0; }
trap on_stop TERM INT
"$S" "$@" || exit 1
bad=0
while :; do sleep 10 & wait $!
  if "$S" launch --status --output json 2>/dev/null | grep -q "\"state\": *\"ready\""; then bad=0; else bad=$((bad+1)); [ "$bad" -ge 3 ] && exit 1; fi
done' strata "${KFLAGS[@]}")
fi
podman run -d \
  --name "${CONTAINER_NAME}" \
  --device /dev/kfd --device /dev/dri \
  --group-add keep-groups \
  --security-opt label=disable \
  --ulimit memlock=-1:-1 --shm-size 2g --stop-timeout 120 \
  -p "127.0.0.1:${PORT}:8080" \
  -v "${DATA_DIR}:/data:z" \
  "${ENVS[@]}" \
  "${IMAGE}" \
  "${RUN_CMD[@]}" \
  >/dev/null

echo "Spawned container ${CONTAINER_NAME}"

# ---- readiness ---------------------------------------------------------------
log_follow_pid=""
cleanup() {
  if [[ -n "${log_follow_pid}" ]]; then
    # The follower runs in its own process group (setsid below): signal the whole
    # group so `podman logs -f` dies together with `tee`. Killing only the
    # pipeline's last pid leaves podman alive, and the `wait` below then blocks
    # forever right after a successful start.
    kill -- "-${log_follow_pid}" 2>/dev/null \
      || kill "${log_follow_pid}" 2>/dev/null || true
    wait "${log_follow_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Stream the engine log to the terminal AND record it in .hy4.log.
# setsid isolates the `podman logs -f | tee` pipeline in its own process group so
# cleanup can reap both ends (see above); without it, start.sh never returns.
setsid bash -c 'podman logs -f "$1" 2>&1 | tee -a "$2"' _ "${CONTAINER_NAME}" "${LOG_FILE}" &
log_follow_pid=$!

# /health answers without a key in both modes (keyed mode: /v1/* needs one).
READY_URL="http://127.0.0.1:${PORT}/health"
echo "Waiting for HTTP readiness at ${READY_URL} (timeout ${READY_TIMEOUT}s)"
deadline=$(( $(date +%s) + READY_TIMEOUT ))
heartbeat=0
until curl -fsS "${READY_URL}" >/dev/null 2>&1; do
  if ! podman ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Container exited before becoming ready"
    tail -n 200 "${LOG_FILE}" || true
    exit 1
  fi
  if (( $(date +%s) >= deadline )); then
    echo "Timed out after ${READY_TIMEOUT}s waiting for readiness"
    tail -n 200 "${LOG_FILE}" || true
    exit 1
  fi
  # The log itself is streaming above; only a light heartbeat every ~30s.
  if (( heartbeat % 6 == 0 )); then
    echo "  still starting..."
  fi
  heartbeat=$((heartbeat + 1))
  sleep 5
done

SERVED_ID="${FAMILY}-$(printf '%s' "${MODEL}" | tr '[:upper:]' '[:lower:]')"
echo "Hy4-Flash ${MODEL} is ready"
echo "OpenAI base URL: http://127.0.0.1:${PORT}/v1"
if [[ -n "${API_KEY:-}" ]]; then
  echo "API key:         ${API_KEY}"
  KEY_HDR=" -H \\\"Authorization: Bearer ${API_KEY}\\\""
else
  echo "API key:         none (loopback-only; set API_KEY in .env to require one)"
  KEY_HDR=""
fi
echo "Served model id: ${SERVED_ID}"
echo "Recommended sampling: temperature 0.9, top_p 1.0, top_k off"
echo "Try: curl -s http://127.0.0.1:${PORT}/v1/chat/completions${KEY_HDR} -H 'Content-Type: application/json' -d '{\"model\":\"${SERVED_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":64,\"temperature\":0.9,\"top_p\":1.0}'"
