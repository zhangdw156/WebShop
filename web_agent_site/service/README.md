# WebShop HTTP environment service

This package exposes the original in-process `WebAgentTextEnv` as a small JSON API for external RL trainers.

Start from the WebShop repo after the normal product data and search-index setup:

```bash
PORT=3001 NUM_PRODUCTS=1000 ./run_webshop_service.sh
```

Endpoints:

- `GET /health` — service status, active session count, and goal count.
- `GET /v1/goals?limit=0` — stable goal count plus optional goal previews (`limit` is capped at 100).
- `POST /v1/reset` — payload: `session_id`, optional `goal_idx`, optional `observation_mode`.
- `POST /v1/step` — payload: `session_id`, `action`.
- `DELETE /v1/session/<session_id>` — best-effort session cleanup.
- `GET /v1/sessions` — active session ids.

`goal_idx` is the stable index used by the slime WebShop example to make train/eval splits reproducible.
