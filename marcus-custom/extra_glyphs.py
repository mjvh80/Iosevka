import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

import fontforge
import psMat


extra_glyph_font_name = "NotoSansCJKJP"
extra_glyph_fonts = {
    "NotoSansCJKJP": {
        "directory": "noto-sans-cjk-jp",
        "weights": {
            400: "NotoSansCJKjp-Regular.otf",
            700: "NotoSansCJKjp-Bold.otf",
        },
        "notices": ["LICENSE", "SOURCES.md", "SHA256SUMS.json"],
    },
}
extra_glyph_codepoints = (0x30C4, 0x30B7, 0x30C3)


def get_glyph(font, codepoint):
    slot = font.findEncodingSlot(codepoint)
    return font[slot] if slot >= 0 and slot in font else None


def has_glyph(font, codepoint):
    glyph = get_glyph(font, codepoint)
    return glyph is not None and glyph.isWorthOutputting()


def donor_path_for(font):
    config = extra_glyph_fonts[extra_glyph_font_name]
    weight = min(config["weights"], key=lambda value: (abs(value - font.os2_weight), value))
    return Path(__file__).resolve().parent / config["directory"] / config["weights"][weight]


def add_extra_glyphs(font):
    missing = [codepoint for codepoint in extra_glyph_codepoints if not has_glyph(font, codepoint)]
    if not missing:
        return []
    if not has_glyph(font, ord("0")) or get_glyph(font, ord("0")).width <= 0:
        raise ValueError("Target font must have a positive-width digit zero")

    path = donor_path_for(font)
    donor = fontforge.open(str(path))
    try:
        if donor.cidfontname:
            donor.cidFlatten()
        for codepoint in extra_glyph_codepoints:
            if not has_glyph(donor, codepoint):
                raise ValueError(f"Donor {path.name} is missing U+{codepoint:04X}")
            get_glyph(donor, codepoint).unlinkRef()

        advance = get_glyph(font, ord("0")).width * 2
        scale = font.em / donor.em
        for codepoint in extra_glyph_codepoints:
            glyph = get_glyph(donor, codepoint)
            if glyph.width <= 0:
                raise ValueError(f"Donor U+{codepoint:04X} has no advance width")
            minimum_x, minimum_y, maximum_x, maximum_y = glyph.boundingBox()
            extent = max(glyph.width, maximum_x * 2 - glyph.width, glyph.width - minimum_x * 2)
            scale = min(scale, advance / extent)
            if maximum_y > 0:
                scale = min(scale, font.ascent / maximum_y)
            if minimum_y < 0:
                scale = min(scale, font.descent / -minimum_y)

        for codepoint in missing:
            source = get_glyph(donor, codepoint)
            target = font.createChar(codepoint)
            outlines = source.foreground
            outlines.is_quadratic = target.foreground.is_quadratic
            target.foreground = outlines
            target.transform(psMat.scale(scale))
            target.transform(psMat.translate((advance - source.width * scale) / 2, 0))
            target.round()
            target.width = advance

        print(f"Extra glyphs from {path.name}: " + ", ".join(f"U+{value:04X}" for value in missing))
        return missing
    finally:
        donor.close()


def copy_donor_notices(output_directory):
    config = extra_glyph_fonts[extra_glyph_font_name]
    directory = Path(__file__).resolve().parent / config["directory"]
    for name in config.get("notices", []):
        shutil.copyfile(directory / name, Path(output_directory) / f"{extra_glyph_font_name}-{name}")


def patch_font_file(input_path, output_path):
    input_path = Path(input_path).resolve()
    output_path = Path(output_path).resolve()
    if input_path == output_path:
        raise ValueError("Input and output font paths must differ")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    font = fontforge.open(str(input_path))
    try:
        added = add_extra_glyphs(font)
        if added:
            font.generate(str(output_path))
        else:
            shutil.copyfile(input_path, output_path)
    finally:
        font.close()

    generated = fontforge.open(str(output_path))
    try:
        for codepoint in extra_glyph_codepoints:
            if not has_glyph(generated, codepoint):
                raise ValueError(f"Generated font is missing U+{codepoint:04X}: {output_path}")
        for codepoint in added:
            if get_glyph(generated, codepoint).width != get_glyph(generated, ord("0")).width * 2:
                raise ValueError(f"Unexpected advance for U+{codepoint:04X}: {output_path}")
    finally:
        generated.close()
    return {"file": input_path.name, "added": [f"U+{value:04X}" for value in added]}


def publish_output(staged_output, output_directory):
    output_directory = Path(output_directory)
    if not any(Path(staged_output).glob("*.ttf")):
        raise ValueError("Refusing to publish an empty font directory")
    backup = None
    if output_directory.exists():
        backup = output_directory.with_name(f"{output_directory.name}.previous-{time.time_ns()}")
        os.replace(output_directory, backup)
    try:
        os.replace(staged_output, output_directory)
    except BaseException:
        if backup is not None:
            os.replace(backup, output_directory)
        raise
    if backup is not None:
        print(f"Previous output retained at {backup}")


def patch_fonts(input_paths, output_directory):
    input_paths = [Path(path).resolve() for path in input_paths]
    output_directory = Path(output_directory).resolve()
    if not input_paths:
        raise ValueError("No input TTF files found")
    if len({path.name.casefold() for path in input_paths}) != len(input_paths):
        raise ValueError("Input filenames must be unique")
    if any(path.is_relative_to(output_directory) for path in input_paths):
        raise ValueError("Output directory must not contain the input fonts")
    output_directory.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=".extra-glyphs-", dir=output_directory.parent) as staging:
        staged_output = Path(staging) / "fonts"
        staged_output.mkdir()
        copy_donor_notices(staged_output)
        results = [patch_font_file(path, staged_output / path.name) for path in input_paths]
        manifest = {"donor": extra_glyph_font_name, "fonts": results}
        (staged_output / "extra-glyphs.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        publish_output(staged_output, output_directory)
    print(f"Patched {len(results)} fonts into {output_directory}")


def main():
    parser = argparse.ArgumentParser(description="Add missing Japanese glyphs to existing fonts without rebuilding Iosevka")
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--input-dir", type=Path)
    inputs.add_argument("--fonts", nargs="+", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    input_paths = sorted(args.input_dir.glob("*.ttf")) if args.input_dir else args.fonts
    patch_fonts(input_paths, args.output_dir)


if __name__ == "__main__":
    main()