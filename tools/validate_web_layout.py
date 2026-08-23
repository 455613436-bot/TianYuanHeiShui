#!/usr/bin/env python3
"""Validate the fixed-aspect Web shell and Web-only display safeguards."""

from __future__ import annotations

import math
from pathlib import Path
import re


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROJECT_SETTINGS = PROJECT_ROOT / "project.godot"
EXPORT_PRESETS = PROJECT_ROOT / "export_presets.cfg"
WEB_SHELL = PROJECT_ROOT / "web/custom_shell.html"
SETTINGS_MENU = PROJECT_ROOT / "scripts/ui/SettingsMenu.gd"
EXPORTED_HTML = PROJECT_ROOT / "dist/index.html"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"WEB_LAYOUT_INVALID {message}")


def setting_value(text: str, key: str) -> str:
    match = re.search(rf"(?m)^{re.escape(key)}=(.+)$", text)
    if not match:
        raise SystemExit(f"WEB_LAYOUT_INVALID missing setting: {key}")
    return match.group(1).strip().strip('"')


def web_preset(text: str) -> str:
    match = re.search(
        r'(?ms)^\[preset\.\d+\]\n\nname="Web"\n.*?(?=^\[preset\.\d+\.options\]\n\n)(.*?)'
        r'(?=^\[preset\.\d+\]|\Z)',
        text,
    )
    if not match:
        raise SystemExit("WEB_LAYOUT_INVALID missing Web preset")
    return match.group(0)


def display_size(width: int, height: int, target_width: int, target_height: int) -> tuple[int, int]:
    safe_width = max(1, width)
    safe_height = max(1, height)
    scale = min(1.0, safe_width / target_width, safe_height / target_height)
    return (
        max(1, math.floor(target_width * scale)),
        max(1, math.floor(target_height * scale)),
    )


def main() -> int:
    project = PROJECT_SETTINGS.read_text(encoding="utf-8")
    require(setting_value(project, "window/size/viewport_width") == "1280", "viewport width")
    require(setting_value(project, "window/size/viewport_height") == "720", "viewport height")
    require(setting_value(project, "window/size/window_width_override") == "1920", "Windows width override")
    require(setting_value(project, "window/size/window_height_override") == "1080", "Windows height override")

    preset = web_preset(EXPORT_PRESETS.read_text(encoding="utf-8"))
    require('html/canvas_resize_policy=1' in preset, "Web canvas policy must be Project")
    require(
        'html/custom_html_shell="res://web/custom_shell.html"' in preset,
        "custom Web shell is not configured",
    )

    shell = WEB_SHELL.read_text(encoding="utf-8")
    for placeholder in (
        "$GODOT_URL",
        "$GODOT_CONFIG",
        "$GODOT_THREADS_ENABLED",
        "$GODOT_PROJECT_NAME",
        "$GODOT_SPLASH",
        "$GODOT_SPLASH_COLOR",
        "$GODOT_SPLASH_CLASSES",
    ):
        require(placeholder in shell, f"missing shell placeholder {placeholder}")
    require("width: 100% !important" in shell, "canvas CSS width must follow the frame")
    require("height: 100% !important" in shell, "canvas CSS height must follow the frame")
    require("canvas.width =" not in shell, "shell must not mutate the canvas drawing width")
    require("canvas.height =" not in shell, "shell must not mutate the canvas drawing height")
    require("window.tianyuanSetDisplaySize" in shell, "missing display-size setter")
    require("window.tianyuanGetDisplaySize" in shell, "missing display-size getter")
    require("tianyuan_web_display_size" in shell, "display-size choice is not persisted")

    width_match = re.search(r"const MAX_DISPLAY_WIDTH = (\d+);", shell)
    height_match = re.search(r"const MAX_DISPLAY_HEIGHT = (\d+);", shell)
    require(width_match is not None and height_match is not None, "missing display limits")
    max_width = int(width_match.group(1))
    max_height = int(height_match.group(1))
    require((max_width, max_height) == (1920, 1080), "display limit must be 1920x1080")

    expected_cases = {
        (1280, 720): (1280, 720),
        (1366, 768): (1365, 768),
        (1920, 1080): (1920, 1080),
        (2560, 1440): (1920, 1080),
        (3840, 2160): (1920, 1080),
        (1024, 768): (1024, 576),
    }
    for viewport, expected in expected_cases.items():
        actual = display_size(*viewport, max_width, max_height)
        require(actual == expected, f"viewport {viewport} produced {actual}, expected {expected}")
    selectable_cases = {
        (1920, 1080, 1280, 720): (1280, 720),
        (1920, 1080, 1600, 900): (1600, 900),
        (1920, 1080, 1920, 1080): (1920, 1080),
        (1024, 768, 1920, 1080): (1024, 576),
    }
    for case, expected in selectable_cases.items():
        actual = display_size(*case)
        require(actual == expected, f"display choice {case} produced {actual}, expected {expected}")

    settings = SETTINGS_MENU.read_text(encoding="utf-8")
    require('OS.has_feature("web")' in settings, "SettingsMenu has no Web feature guard")
    require('resolution_option.add_item("自动（最高 1920 × 1080）")' in settings, "missing automatic display size")
    require('resolution_option.add_item("1280 × 720")' in settings, "missing 720p display size")
    require('resolution_option.add_item("1600 × 900")' in settings, "missing 900p display size")
    require('resolution_option.add_item("1920 × 1080")' in settings, "missing 1080p display size")
    require("tianyuanSetDisplaySize" in settings, "SettingsMenu does not call the Web display API")
    require(
        re.search(r"func _apply_display_settings\([^)]*\).*?if _is_web_runtime\(\):\n\t\treturn", settings, re.S)
        is not None,
        "Web can still apply native window settings",
    )

    if EXPORTED_HTML.is_file():
        exported = EXPORTED_HTML.read_text(encoding="utf-8")
        require('"canvasResizePolicy":1' in exported, "exported HTML is not using Project policy")
        require('id="game-frame"' in exported, "exported HTML is not using the custom shell")
        require("const MAX_DISPLAY_WIDTH = 1920;" in exported, "exported HTML lost width cap")
        require("const MAX_DISPLAY_HEIGHT = 1080;" in exported, "exported HTML lost height cap")
        require("window.tianyuanSetDisplaySize" in exported, "exported HTML lost display-size controls")
        require("$GODOT_" not in exported, "exported HTML contains unresolved placeholders")

    print(
        f"WEB_LAYOUT_OK cases={len(expected_cases)} "
        f"logical=1280x720 max_display={max_width}x{max_height}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
