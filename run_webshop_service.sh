#!/usr/bin/env bash
set -euo pipefail

HOST=${HOST:-0.0.0.0}
PORT=${PORT:-3001}
OBSERVATION_MODE=${OBSERVATION_MODE:-text}
SEED=${SEED:-0}

ARGS=(
  --host "${HOST}"
  --port "${PORT}"
  --observation-mode "${OBSERVATION_MODE}"
  --seed "${SEED}"
)

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
if [[ -n "${WEBSHOP_ATTR_PATH:-}" ]]; then
  ARGS+=(--attr-path "${WEBSHOP_ATTR_PATH}")
fi

python -m web_agent_site.service.api "${ARGS[@]}"
