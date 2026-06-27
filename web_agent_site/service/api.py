"""HTTP API for using WebShop as a client/server environment.

The original WebShop text environment keeps the simulator in-process: a
``WebAgentTextEnv`` owns a ``SimBrowser`` that calls ``SimServer.receive``
directly.  This module keeps that behavior intact on the server side and
exposes a small JSON API so training code can interact with WebShop without
installing WebShop's heavier dependencies in the training environment.
"""

from __future__ import annotations

import argparse
import uuid
from dataclasses import dataclass
from typing import Any, Dict, Optional

from flask import Flask, jsonify, request

from web_agent_site.envs.web_agent_text_env import SimServer, WebAgentTextEnv
from web_agent_site.utils import DEFAULT_ATTR_PATH, DEFAULT_FILE_PATH


@dataclass(frozen=True)
class ServiceConfig:
    """Static WebShop backend configuration.

    A single service process owns one ``SimServer``.  Dataset and index choices
    are process-wide because the search engine and product tables are loaded at
    service startup.
    """

    file_path: str = DEFAULT_FILE_PATH
    attr_path: str = DEFAULT_ATTR_PATH
    base_url: str = "http://127.0.0.1:3000"
    observation_mode: str = "text"
    human_goals: bool = False
    limit_goals: int = -1
    show_attrs: bool = False
    num_prev_obs: int = 0
    num_prev_actions: int = 0
    seed: int = 0


class WebShopService:
    """Stateful session manager around the original WebShop text environment."""

    def __init__(self, config: Optional[ServiceConfig] = None) -> None:
        self.config = config or ServiceConfig()
        self.server = SimServer(
            base_url=self.config.base_url,
            file_path=self.config.file_path,
            attr_path=self.config.attr_path,
            limit_goals=self.config.limit_goals,
            human_goals=self.config.human_goals,
            show_attrs=self.config.show_attrs,
            seed=self.config.seed,
        )
        self.envs: Dict[str, WebAgentTextEnv] = {}

    @property
    def session_count(self) -> int:
        return len(self.envs)

    @property
    def goal_count(self) -> int:
        return len(self.server.goals)

    def health(self) -> Dict[str, Any]:
        return {
            "ok": True,
            "sessions": self.session_count,
            "goals": self.goal_count,
            "goal_count": self.goal_count,
            "observation_mode": self.config.observation_mode,
            "seed": self.config.seed,
        }

    def goals_summary(self, *, offset: int = 0, limit: int = 0, goal_seed: Optional[int] = None) -> Dict[str, Any]:
        """Return stable goal-index metadata for data preparation."""

        offset = max(0, int(offset))
        limit = max(0, min(int(limit), 100))
        goals = self.server.get_goals_for_seed(goal_seed)
        end = min(len(goals), offset + limit)
        items = []
        for goal_idx in range(offset, end):
            goal = goals[goal_idx]
            items.append(
                {
                    "goal_idx": goal_idx,
                    "instruction_text": goal.get("instruction_text"),
                    "weight": goal.get("weight"),
                }
            )
        return {
            "ok": True,
            "goal_count": len(goals),
            "goal_seed": self.config.seed if goal_seed is None else int(goal_seed),
            "offset": offset,
            "limit": limit,
            "items": items,
        }

    def reset(
        self,
        *,
        session_id: Optional[str] = None,
        goal_idx: Optional[int] = None,
        observation_mode: Optional[str] = None,
        goal_seed: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Create or replace one environment session and return its initial state."""

        if goal_idx is not None and not 0 <= int(goal_idx) < self.goal_count:
            raise ValueError(f"goal_idx {goal_idx} is outside [0, {self.goal_count})")

        session_id = session_id or uuid.uuid4().hex
        if session_id in self.envs:
            self.close(session_id)

        env = WebAgentTextEnv(
            observation_mode=observation_mode or self.config.observation_mode,
            file_path=self.config.file_path,
            attr_path=self.config.attr_path,
            base_url=self.config.base_url,
            server=self.server,
            session=session_id,
            num_prev_obs=self.config.num_prev_obs,
            num_prev_actions=self.config.num_prev_actions,
            show_attrs=self.config.show_attrs,
            auto_reset=False,
        )
        env.reset(session=session_id, goal_idx=goal_idx, goal_seed=goal_seed)
        self.envs[session_id] = env

        return self._state(env, reward=0.0, done=False, info={"reset": True})

    def step(self, *, session_id: str, action: str) -> Dict[str, Any]:
        if session_id not in self.envs:
            raise KeyError(f"unknown session_id: {session_id}")
        if not isinstance(action, str) or not action.strip():
            raise ValueError("action must be a non-empty string")

        env = self.envs[session_id]
        observation, reward, done, info = env.step(action)
        return self._state(
            env,
            observation=observation,
            reward=float(reward),
            done=bool(done),
            info={"gym_info": info, "action": action},
        )

    def close(self, session_id: str) -> Dict[str, Any]:
        env = self.envs.pop(session_id, None)
        if env is not None:
            env.close()
        self.server.user_sessions.pop(session_id, None)
        return {"ok": True, "session_id": session_id, "closed": env is not None}

    def _state(
        self,
        env: WebAgentTextEnv,
        *,
        reward: float,
        done: bool,
        info: Optional[Dict[str, Any]] = None,
        observation: Optional[str] = None,
    ) -> Dict[str, Any]:
        session = self.server.user_sessions.get(env.session, {})
        try:
            available_actions = env.get_available_actions()
        except Exception:
            available_actions = {"has_search_bar": False, "clickables": []}

        merged_info: Dict[str, Any] = {
            "url": env.browser.current_url,
            "page_done": bool(session.get("done", done)),
        }
        if "reward" in session:
            merged_info["session_reward"] = session["reward"]
        if "verbose_info" in session:
            merged_info["reward_info"] = session["verbose_info"]
        if info:
            merged_info.update(info)

        return {
            "session_id": env.session,
            "observation": env.observation if observation is None else observation,
            "instruction_text": env.instruction_text,
            "available_actions": available_actions,
            "reward": float(reward),
            "done": bool(done),
            "info": merged_info,
        }


def _json_error(message: str, status_code: int):
    response = jsonify({"ok": False, "error": message})
    response.status_code = status_code
    return response


def create_app(service: Optional[WebShopService] = None) -> Flask:
    """Create a Flask app around a ``WebShopService`` instance."""

    service = service or WebShopService()
    app = Flask(__name__)
    app.config["webshop_service"] = service

    @app.get("/health")
    def health():
        return jsonify(service.health())

    @app.get("/v1/goals")
    def goals():
        try:
            offset = int(request.args.get("offset", 0))
            limit = int(request.args.get("limit", 0))
            goal_seed_arg = request.args.get("goal_seed")
            goal_seed = int(goal_seed_arg) if goal_seed_arg is not None else None
        except (TypeError, ValueError) as exc:
            return _json_error(str(exc), 400)
        return jsonify(service.goals_summary(offset=offset, limit=limit, goal_seed=goal_seed))

    @app.post("/v1/reset")
    def reset():
        payload = request.get_json(silent=True) or {}
        try:
            state = service.reset(
                session_id=payload.get("session_id"),
                goal_idx=payload.get("goal_idx"),
                observation_mode=payload.get("observation_mode"),
                goal_seed=payload.get("goal_seed"),
            )
        except (TypeError, ValueError) as exc:
            return _json_error(str(exc), 400)
        return jsonify(state)

    @app.post("/v1/step")
    def step():
        payload = request.get_json(silent=True) or {}
        if "session_id" not in payload or "action" not in payload:
            return _json_error("payload must include session_id and action", 400)
        try:
            state = service.step(
                session_id=payload["session_id"],
                action=payload["action"],
            )
        except KeyError as exc:
            return _json_error(str(exc), 404)
        except (TypeError, ValueError) as exc:
            return _json_error(str(exc), 400)
        return jsonify(state)

    @app.delete("/v1/session/<session_id>")
    def close(session_id: str):
        return jsonify(service.close(session_id))

    @app.get("/v1/sessions")
    def sessions():
        return jsonify({"sessions": sorted(service.envs.keys())})

    return app


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run WebShop as a JSON HTTP environment service.")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=3001)
    parser.add_argument("--file-path", default=DEFAULT_FILE_PATH)
    parser.add_argument("--attr-path", default=DEFAULT_ATTR_PATH)
    parser.add_argument("--base-url", default="http://127.0.0.1:3000")
    parser.add_argument("--observation-mode", default="text", choices=["html", "text", "text_rich", "url"])
    parser.add_argument("--human-goals", action="store_true")
    parser.add_argument("--limit-goals", type=int, default=-1)
    parser.add_argument("--show-attrs", action="store_true")
    parser.add_argument("--num-prev-obs", type=int, default=0)
    parser.add_argument("--num-prev-actions", type=int, default=0)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--debug", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    config = ServiceConfig(
        file_path=args.file_path,
        attr_path=args.attr_path,
        base_url=args.base_url,
        observation_mode=args.observation_mode,
        human_goals=args.human_goals,
        limit_goals=args.limit_goals,
        show_attrs=args.show_attrs,
        num_prev_obs=args.num_prev_obs,
        num_prev_actions=args.num_prev_actions,
        seed=args.seed,
    )
    app = create_app(WebShopService(config))
    app.run(host=args.host, port=args.port, debug=args.debug)


if __name__ == "__main__":
    main()
