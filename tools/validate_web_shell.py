#!/usr/bin/env python3
"""Static release checks for the Web user-gesture audio gate."""

from __future__ import annotations

import argparse
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
REQUIRED_MARKERS = (
    'id="start-game-button"',
    "点击进入游戏（启用声音）",
    "let gameStarted = false;",
    "const startGameOnce = () =>",
    "if (gameStarted)",
    "startGameButton.addEventListener('click', startGameOnce, { once: true });",
    "setStatusMode('ready');",
)


def validate(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    missing = [marker for marker in REQUIRED_MARKERS if marker not in text]
    if missing:
        raise SystemExit(f"WEB_SHELL_MISSING path={path} markers={missing}")
    if text.count("engine.startGame({") != 1:
        raise SystemExit(f"WEB_SHELL_START_COUNT path={path} count={text.count('engine.startGame({')}")
    listener_index = text.index("startGameButton.addEventListener")
    ready_index = text.index("setStatusMode('ready');", listener_index)
    if ready_index < listener_index:
        raise SystemExit(f"WEB_SHELL_READY_ORDER path={path}")
    print(f"WEB_SHELL_OK path={path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        default=[PROJECT_ROOT / "web/custom_shell.html", PROJECT_ROOT / "dist/index.html"],
    )
    args = parser.parse_args()
    for path in args.paths:
        validate(path.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
