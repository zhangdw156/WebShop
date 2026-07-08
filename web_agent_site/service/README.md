# WebShop HTTP environment service

This package exposes the original in-process `WebAgentTextEnv` as a small JSON API for external RL trainers.

Small synthetic setup:

```bash
cd ../WebShop
./setup.sh
PORT=3001 SEED=0 ./run_webshop_service.sh
```

The service loads the configured product and instruction files directly; there is no product-count override at the service entry point.

Endpoints:

- `GET /health` — service status, active session count, goal count, and default seed.
- `GET /v1/goals?limit=0` — stable goal count.
- `GET /v1/goals?goal_seed=7&limit=5` — previews the seeded goal order for a worker seed.
- `POST /v1/reset` — payload: `session_id`, optional `goal_idx`, optional `goal_seed`, optional `observation_mode`.
- `POST /v1/step` — payload: `session_id`, `action`.
- `DELETE /v1/session/<session_id>` — best-effort session cleanup.
- `GET /v1/sessions` — active session ids.

`goal_idx` plus `goal_seed` is the stable pair used by the slime WebShop example. The service caches seeded goal orders so one HTTP service can reproduce per-worker synthetic-goal ordering.
