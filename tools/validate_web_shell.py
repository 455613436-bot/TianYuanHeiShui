#!/usr/bin/env python3
"""Static release checks for the Web automatic loading shell."""

from __future__ import annotations

import argparse
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
REQUIRED_MARKERS = (
    'id="status-message"',
    "正在编译着色器…",
    "let gameStarted = false;",
    "const startGame = () =>",
    "if (gameStarted)",
    "setStatusMode('progress');",
    "startGame();",
)


def validate(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    missing = [marker for marker in REQUIRED_MARKERS if marker not in text]
    if missing:
        raise SystemExit(f"WEB_SHELL_MISSING path={path} markers={missing}")
    if text.count("engine.startGame({") != 1:
        raise SystemExit(f"WEB_SHELL_START_COUNT path={path} count={text.count('engine.startGame({')}")
    start_index = text.index("const startGame = () =>")
    invocation_index = text.rindex("startGame();")
    if invocation_index < start_index:
        raise SystemExit(f"WEB_SHELL_AUTOSTART_ORDER path={path}")
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
