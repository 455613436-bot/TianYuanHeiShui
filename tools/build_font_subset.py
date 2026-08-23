#!/usr/bin/env python3
"""Build and verify the single runtime Chinese font used by the game."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

try:
    from fontTools import subset
    from fontTools.ttLib import TTFont
except ModuleNotFoundError as exc:  # pragma: no cover - actionable CLI error
    raise SystemExit(
        "fontTools is required. Install tools/requirements-font-subset.txt first."
    ) from exc


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = PROJECT_ROOT / "tools/font_source/SourceHanSerifSC-Bold.otf"
DEFAULT_OUTPUT = PROJECT_ROOT / "assets/fonts/SourceHanSerifSC-Game.otf"
DEFAULT_SYMBOL_SOURCE = PROJECT_ROOT / "tools/font_source/DejaVuSans.ttf"
DEFAULT_SYMBOL_OUTPUT = PROJECT_ROOT / "assets/fonts/TianyuanSymbols.ttf"
SYMBOL_CODEPOINTS = {0x27F3}
SUBSET_FAMILY_NAME = "Tianyuan Serif"
SUBSET_FULL_NAME = "Tianyuan Serif Bold"
SUBSET_POSTSCRIPT_NAME = "TianyuanSerif-Bold"
TEXT_ROOTS = (
    PROJECT_ROOT / "scripts",
    PROJECT_ROOT / "scenes",
    PROJECT_ROOT / "data",
    PROJECT_ROOT / "assets/theme",
)
TEXT_SUFFIXES = {".gd", ".tscn", ".tres", ".json", ".md"}


def gb2312_characters() -> set[str]:
    characters: set[str] = set()
    for lead in range(0xA1, 0xF8):
        for trail in range(0xA1, 0xFF):
            try:
                characters.add(bytes((lead, trail)).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return characters


def static_project_characters() -> set[str]:
    characters: set[str] = set()
    for root in TEXT_ROOTS:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.is_file() and path.suffix.lower() in TEXT_SUFFIXES:
                characters.update(path.read_text(encoding="utf-8", errors="ignore"))
    return characters


def required_characters() -> set[str]:
    characters = static_project_characters() | gb2312_characters()
    characters.update(chr(codepoint) for codepoint in range(0x20, 0x7F))
    characters.update(chr(codepoint) for codepoint in range(0xA0, 0x100))
    characters.update(chr(codepoint) for codepoint in range(0x2000, 0x2070))
    characters.update(chr(codepoint) for codepoint in range(0x3000, 0x3040))
    characters.update(chr(codepoint) for codepoint in range(0xFF00, 0xFFF0))
    return {char for char in characters if not char.isspace() or char == " "}


def font_codepoints(path: Path) -> set[int]:
    font = TTFont(path, lazy=True)
    try:
        codepoints: set[int] = set()
        for table in font["cmap"].tables:
            if table.isUnicode():
                codepoints.update(table.cmap)
        return codepoints
    finally:
        font.close()


def rename_subset_font(font: TTFont) -> None:
    """Comply with the OFL Reserved Font Name requirement for derivatives."""
    name_table = font["name"]
    replacements = {
        1: SUBSET_FAMILY_NAME,
        2: "Bold",
        3: "Tianyuan Serif Bold; game subset",
        4: SUBSET_FULL_NAME,
        6: SUBSET_POSTSCRIPT_NAME,
        16: SUBSET_FAMILY_NAME,
        17: "Bold",
    }
    platforms = {
        (record.platformID, record.platEncID, record.langID)
        for record in name_table.names
    }
    for name_id, value in replacements.items():
        name_table.removeNames(nameID=name_id)
        for platform_id, encoding_id, language_id in platforms:
            try:
                name_table.setName(value, name_id, platform_id, encoding_id, language_id)
            except (UnicodeEncodeError, LookupError):
                continue

    if "CFF " in font:
        top_dict = font["CFF "].cff.topDictIndex[0]
        top_dict.FamilyName = SUBSET_FAMILY_NAME
        top_dict.FullName = SUBSET_FULL_NAME
        top_dict.FontName = SUBSET_POSTSCRIPT_NAME


def rename_symbol_font(font: TTFont) -> None:
    """Give the one-glyph fallback its own family and PostScript names."""
    name_table = font["name"]
    replacements = {
        1: "Tianyuan Symbols",
        2: "Regular",
        3: "Tianyuan Symbols Regular; game subset",
        4: "Tianyuan Symbols Regular",
        6: "TianyuanSymbols-Regular",
        16: "Tianyuan Symbols",
        17: "Regular",
    }
    platforms = {
        (record.platformID, record.platEncID, record.langID)
        for record in name_table.names
    }
    for name_id, value in replacements.items():
        name_table.removeNames(nameID=name_id)
        for platform_id, encoding_id, language_id in platforms:
            try:
                name_table.setName(value, name_id, platform_id, encoding_id, language_id)
            except (UnicodeEncodeError, LookupError):
                continue


def build(source: Path, output: Path) -> None:
    requested = required_characters()
    source_codepoints = font_codepoints(source)
    requested_codepoints = {ord(char) for char in requested}
    supported = requested_codepoints & source_codepoints
    unsupported = requested_codepoints - source_codepoints

    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14, 16, 17]
    options.name_languages = [0x409, 0x804]
    options.notdef_glyph = True
    options.notdef_outline = True
    options.recommended_glyphs = True
    options.recalc_average_width = True
    options.recalc_max_context = True

    font = subset.load_font(str(source), options)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=supported)
    subsetter.subset(font)
    rename_subset_font(font)
    output.parent.mkdir(parents=True, exist_ok=True)
    subset.save_font(font, str(output), options)

    print(
        f"FONT_SUBSET_BUILT supported={len(supported)} "
        f"source_unsupported={len(unsupported)} bytes={output.stat().st_size}"
    )


def verify(source: Path, output: Path) -> None:
    source_codepoints = font_codepoints(source)
    output_codepoints = font_codepoints(output)
    required = {ord(char) for char in required_characters()} & source_codepoints
    missing = sorted(required - output_codepoints)
    if missing:
        sample = " ".join(f"U+{codepoint:04X}" for codepoint in missing[:20])
        raise SystemExit(f"FONT_SUBSET_MISSING count={len(missing)} sample={sample}")
    print(
        f"FONT_SUBSET_OK codepoints={len(output_codepoints)} "
        f"bytes={output.stat().st_size}"
    )


def build_symbol_font(source: Path, output: Path) -> None:
    source_codepoints = font_codepoints(source)
    missing_source = SYMBOL_CODEPOINTS - source_codepoints
    if missing_source:
        raise SystemExit("Symbol source does not contain U+27F3")
    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14, 16, 17]
    options.name_languages = [0x409, 0x804]
    options.notdef_glyph = True
    options.notdef_outline = True
    options.recommended_glyphs = True
    font = subset.load_font(str(source), options)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=SYMBOL_CODEPOINTS)
    subsetter.subset(font)
    rename_symbol_font(font)
    output.parent.mkdir(parents=True, exist_ok=True)
    subset.save_font(font, str(output), options)
    print(f"SYMBOL_FONT_BUILT codepoints=1 bytes={output.stat().st_size}")


def verify_symbol_font(output: Path) -> None:
    codepoints = font_codepoints(output)
    missing = SYMBOL_CODEPOINTS - codepoints
    if missing:
        raise SystemExit("SYMBOL_FONT_MISSING U+27F3")
    print(f"SYMBOL_FONT_OK bytes={output.stat().st_size}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--symbol-source", type=Path, default=DEFAULT_SYMBOL_SOURCE)
    parser.add_argument("--symbol-output", type=Path, default=DEFAULT_SYMBOL_OUTPUT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    source = args.source.resolve()
    output = args.output.resolve()
    symbol_source = args.symbol_source.resolve()
    symbol_output = args.symbol_output.resolve()
    if not source.is_file():
        raise SystemExit(f"Font source not found: {source}")
    if not symbol_source.is_file():
        raise SystemExit(f"Symbol font source not found: {symbol_source}")
    if args.check:
        if not output.is_file():
            raise SystemExit(f"Font subset not found: {output}")
        if not symbol_output.is_file():
            raise SystemExit(f"Symbol font subset not found: {symbol_output}")
    else:
        build(source, output)
        build_symbol_font(symbol_source, symbol_output)
    verify(source, output)
    verify_symbol_font(symbol_output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
