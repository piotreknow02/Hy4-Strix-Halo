#!/usr/bin/env bash
set -euo pipefail

# Stop the Hy4-Flash Strata container. Idempotent: if no such container,
# print and exit 0. Leaves the stopped container in place for
# `podman logs hy4-flash-strata` post-mortem (start.sh removes it on next
# launch). Container name overridable via env / .env, same as start.sh.

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

CONTAINER_NAME="${CONTAINER_NAME:-hy4-flash-strata}"

command -v podman >/dev/null 2>&1 || { echo "podman is not on PATH"; exit 1; }

if ! podman ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "Container ${CONTAINER_NAME} does not exist; nothing to stop"
  exit 0
fi

if podman ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "Stopping ${CONTAINER_NAME} (120s grace for clean Strata model unload)..."
  podman stop -t 120 "${CONTAINER_NAME}" >/dev/null
  echo "[$(date -Is)] container ${CONTAINER_NAME} stopped"
  echo "Stopped ${CONTAINER_NAME}."
else
  echo "Container ${CONTAINER_NAME} is not running"
fi
# Left in place; the next start.sh removes it, so `podman logs ${CONTAINER_NAME}`
# stays available for post-mortem.
