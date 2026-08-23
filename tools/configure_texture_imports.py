#!/usr/bin/env python3
"""Apply or verify the agreed 1920x1080 texture import profile."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROFILES = {
    "assets/scenes": {"size_limit": 1920, "quality": 0.85, "recursive": False},
    "assets/portraits": {"size_limit": 640, "quality": 0.85, "recursive": False},
    "assets/items": {"size_limit": 768, "quality": 0.85, "recursive": False},
}


def import_files(relative_root: str, recursive: bool) -> list[Path]:
    root = PROJECT_ROOT / relative_root
    iterator = root.rglob("*.import") if recursive else root.glob("*.import")
    return sorted(path for path in iterator if path.is_file())


def replace_param(text: str, key: str, value: str) -> str:
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    replacement = f"{key}={value}"
    if not pattern.search(text):
        raise ValueError(f"Missing import parameter: {key}")
    return pattern.sub(replacement, text, count=1)


def expected_text(path: Path, profile: dict[str, object]) -> str:
    text = path.read_text(encoding="utf-8")
    text = replace_param(text, "compress/mode", "1")
    text = replace_param(text, "compress/lossy_quality", str(profile["quality"]))
    text = replace_param(text, "process/size_limit", str(profile["size_limit"]))
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    changed: list[Path] = []
    checked = 0
    for relative_root, profile in PROFILES.items():
        files = import_files(relative_root, bool(profile["recursive"]))
        if not files:
            raise SystemExit(f"No import files found under {relative_root}")
        for path in files:
            checked += 1
            current = path.read_text(encoding="utf-8")
            expected = expected_text(path, profile)
            if current == expected:
                continue
            changed.append(path)
            if not args.check:
                path.write_text(expected, encoding="utf-8", newline="\n")

    if args.check and changed:
        sample = ", ".join(str(path.relative_to(PROJECT_ROOT)) for path in changed[:10])
        raise SystemExit(f"TEXTURE_IMPORT_PROFILE_MISMATCH count={len(changed)} sample={sample}")
    mode = "CHECKED" if args.check else "APPLIED"
    print(f"TEXTURE_IMPORT_PROFILE_{mode} files={checked} changed={len(changed)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
