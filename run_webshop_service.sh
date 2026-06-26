#!/usr/bin/env bash
set -euo pipefail

HOST=${HOST:-0.0.0.0}
PORT=${PORT:-3001}
NUM_PRODUCTS=${NUM_PRODUCTS:-1000}
OBSERVATION_MODE=${OBSERVATION_MODE:-text}

ARGS=(
  --host "${HOST}"
  --port "${PORT}"
  --observation-mode "${OBSERVATION_MODE}"
)

if [[ -n "${NUM_PRODUCTS}" && "${NUM_PRODUCTS}" != "none" && "${NUM_PRODUCTS}" != "None" ]]; then
  ARGS+=(--num-products "${NUM_PRODUCTS}")
fi
if [[ "${HUMAN_GOALS:-0}" == "1" ]]; then
  ARGS+=(--human-goals)
fi
if [[ -n "${LIMIT_GOALS:-}" ]]; then
  ARGS+=(--limit-goals "${LIMIT_GOALS}")
fi
if [[ "${SHOW_ATTRS:-0}" == "1" ]]; then
  ARGS+=(--show-attrs)
fi
if [[ -n "${WEBSHOP_FILE_PATH:-}" ]]; then
  ARGS+=(--file-path "${WEBSHOP_FILE_PATH}")
fi

python -m web_agent_site.service.api "${ARGS[@]}"
