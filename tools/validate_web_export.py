#!/usr/bin/env python3
"""Validate the Web preset and every resource loaded from a dynamic path."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PRESET_PATH = PROJECT_ROOT / "export_presets.cfg"
PROJECT_PATH = PROJECT_ROOT / "project.godot"
MCP_EXCLUDE_PATTERNS = (
    "addons/godot_mcp/**",
    "addons/godot_mcp_legacy_20260822/**",
)
MCP_BUNDLE_MARKERS = (
    b"MCPRuntimeBridge",
    b"MCPInputBridge",
    b"MCPScreenshotBridge",
    b"addons/godot_mcp/",
)

PRODUCTION_SCENE_DIRS = (
    "scenes/entities",
    "scenes/locations",
    "scenes/main",
    "scenes/map",
    "scenes/ui",
)

DYNAMIC_GROUPS = {
    "scripts": (
        "scripts/*.gd",
        "scripts/autoload/*.gd",
        "scripts/entities/*.gd",
        "scripts/llm/*.gd",
        "scripts/locations/*.gd",
        "scripts/map/*.gd",
        "scripts/ui/*.gd",
    ),
    "data": ("data/**/*.json", "data/npcs/*.md"),
    "audio_buses": ("assets/audio/*.tres",),
    "bgm": ("assets/audio/bgm/*.ogg",),
    "sfx": ("assets/audio/sfx/*.ogg",),
    "fonts": ("assets/fonts/*.otf", "assets/fonts/*.ttf", "assets/fonts/*.tres", "assets/fonts/*.txt"),
    "themes": ("assets/theme/*.tres",),
    "ui": ("assets/ui/*.png", "assets/ui/*/*.png"),
    "items": ("assets/items/*.png",),
    "portraits": ("assets/portraits/*.png",),
    "map_images": ("assets/maps/*.png",),
    "map_masks": ("assets/maps/masks/*.png",),
    "scene_masks": ("assets/scenes/masks/*.png",),
    "scene_images": ("assets/scenes/*.png", "assets/scenes/*.jpg", "assets/scenes/*.jpeg"),
    "documents": ("assets/documents/*.png", "assets/documents/*.jpg", "assets/documents/*.jpeg"),
}


def web_preset(text: str) -> str:
    match = re.search(r'(?ms)^\[preset\.\d+\]\n\nname="Web"\n.*?(?=^\[preset\.\d+\.options\])', text)
    if not match:
        raise SystemExit("WEB_EXPORT_INVALID missing Web preset")
    return match.group(0)


def production_presets(text: str) -> list[tuple[str, str]]:
    blocks: list[tuple[str, str]] = []
    pattern = re.compile(
        r'(?ms)^\[preset\.\d+\]\n\nname="([^"]+)"\n.*?(?=^\[preset\.\d+\.options\])'
    )
    for match in pattern.finditer(text):
        blocks.append((match.group(1), match.group(0)))
    return blocks


def quoted_values(line: str) -> list[str]:
    return re.findall(r'"([^"]+)"', line)


def path_matches(path: str, pattern: str) -> bool:
    # Godot filters use comma-separated glob patterns. The project patterns only
    # need '*' and '**', so translate those explicitly and anchor the result.
    escaped = re.escape(pattern)
    escaped = escaped.replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
    return re.fullmatch(escaped, path) is not None


def expected_scenes() -> list[str]:
    paths: list[str] = []
    for relative_dir in PRODUCTION_SCENE_DIRS:
        paths.extend(
            f"res://{path.relative_to(PROJECT_ROOT).as_posix()}"
            for path in (PROJECT_ROOT / relative_dir).glob("*.tscn")
        )
    return sorted(paths)


def dynamic_files() -> list[str]:
    paths: set[str] = set()
    for patterns in DYNAMIC_GROUPS.values():
        for pattern in patterns:
            paths.update(
                path.relative_to(PROJECT_ROOT).as_posix()
                for path in PROJECT_ROOT.glob(pattern)
                if path.is_file()
            )
    return sorted(paths)


def validate_runtime_catalogs() -> None:
    locations = json.loads((PROJECT_ROOT / "data/locations.json").read_text(encoding="utf-8"))
    if len(locations) != 12:
        raise SystemExit(f"WEB_EXPORT_INVALID expected 12 locations, got {len(locations)}")
    for location in locations:
        for key in ("scene", "bgm"):
            path = PROJECT_ROOT / str(location[key]).removeprefix("res://")
            if not path.is_file():
                raise SystemExit(f"WEB_EXPORT_MISSING location {key}: {path}")

    item_files = sorted((PROJECT_ROOT / "data/items").glob("*.json"))
    portrait_files = sorted((PROJECT_ROOT / "assets/portraits").glob("*.png"))
    if len(item_files) != 21:
        raise SystemExit(f"WEB_EXPORT_INVALID expected 21 items, got {len(item_files)}")
    if len(portrait_files) != 51:
        raise SystemExit(f"WEB_EXPORT_INVALID expected 51 portraits, got {len(portrait_files)}")
    for item_path in item_files:
        item = json.loads(item_path.read_text(encoding="utf-8"))
        item_id = str(item.get("id", item_path.stem))
        icon_path = str(item.get("icon_path", "")).strip()
        if not icon_path:
            icon_path = f"res://assets/items/{item_id}.png"
        if not (PROJECT_ROOT / icon_path.removeprefix("res://")).is_file():
            raise SystemExit(f"WEB_EXPORT_MISSING item icon: {icon_path}")


def validate_mcp_isolation(preset_text: str) -> None:
    project_text = PROJECT_PATH.read_text(encoding="utf-8")
    forbidden_autoloads = (
        "autoload/MCPRuntimeBridge",
        "autoload/MCPInputBridge",
        "autoload/MCPScreenshotBridge",
    )
    leaked = [key for key in forbidden_autoloads if key in project_text]
    if leaked:
        raise SystemExit("RELEASE_MCP_AUTOLOAD_LEAK " + ", ".join(leaked))

    presets = production_presets(preset_text)
    if not presets:
        raise SystemExit("RELEASE_EXPORT_INVALID no production presets")
    for name, block in presets:
        exclude_line = next(
            (line for line in block.splitlines() if line.startswith("exclude_filter=")), ""
        )
        values = quoted_values(exclude_line)
        patterns = [part.strip() for part in values[0].split(",")] if values else []
        missing = [pattern for pattern in MCP_EXCLUDE_PATTERNS if pattern not in patterns]
        if missing:
            raise SystemExit(
                f"RELEASE_MCP_EXCLUDE_MISSING preset={name} patterns={','.join(missing)}"
            )


def validate_bundle(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"RELEASE_BUNDLE_MISSING {path}")
    payload = path.read_bytes()
    leaked = [marker.decode("ascii") for marker in MCP_BUNDLE_MARKERS if marker in payload]
    if leaked:
        raise SystemExit("RELEASE_MCP_BUNDLE_LEAK " + ", ".join(leaked))
    print(f"RELEASE_BUNDLE_MCP_FREE path={path} bytes={len(payload)}")


def main() -> int:
    preset_text = PRESET_PATH.read_text(encoding="utf-8")
    preset = web_preset(preset_text)
    validate_mcp_isolation(preset_text)
    if 'export_filter="scenes"' not in preset:
        raise SystemExit("WEB_EXPORT_INVALID export_filter must be scenes")

    export_line = next((line for line in preset.splitlines() if line.startswith("export_files=")), "")
    selected = set(quoted_values(export_line))
    missing_scenes = sorted(set(expected_scenes()) - selected)
    if missing_scenes:
        raise SystemExit("WEB_EXPORT_MISSING_SCENES " + ", ".join(missing_scenes))

    include_line = next((line for line in preset.splitlines() if line.startswith("include_filter=")), "")
    include_values = quoted_values(include_line)
    patterns = [part.strip() for part in include_values[0].split(",")] if include_values else []
    if any(path_matches("llm_config.json", pattern) for pattern in patterns):
        raise SystemExit("WEB_EXPORT_SECRET_RISK llm_config.json must not be exported")
    missing_dynamic = [
        path for path in dynamic_files() if not any(path_matches(path, pattern) for pattern in patterns)
    ]
    if missing_dynamic:
        raise SystemExit("WEB_EXPORT_MISSING_DYNAMIC " + ", ".join(missing_dynamic[:20]))

    validate_runtime_catalogs()
    if "--check-bundle" in sys.argv:
        validate_bundle(PROJECT_ROOT / "dist/index.pck")
    print(
        f"WEB_EXPORT_MANIFEST_OK scenes={len(selected)} "
        f"dynamic_files={len(dynamic_files())} patterns={len(patterns)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
