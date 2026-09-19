import argparse
from pathlib import Path
import tempfile

import fontforge
import psMat

from extra_glyphs import add_extra_glyphs, copy_donor_notices, publish_output


script_font_name = "CascadiaCode"
script_fonts = {
    "CascadiaCode": {
        "directory": "cascadia_frozen",
        "prefix": "CascadiaCode-",
        "scale": 1.0,
        "style_overrides": {"Italic": "SemiLightItalic"},
    },
    "Monaspace": {
        "directory": "monaspace",
        "prefix": "MonaspaceRadonFrozen-",
        "scale": 1.1,
        "style_overrides": {},
    },
    "VictorMono": {
        "directory": "victor_mono",
        "prefix": "VictorMono-",
        "scale": 1.0,
        "style_overrides": {},
    },
}
script_directory = Path(__file__).resolve().parent
source_prefix = "IosemkaCondensed-"
output_prefix = "IosemkaScript-"


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description="Create Script fonts from Nerd-patched condensed fonts")
    parser.add_argument("--donor", choices=script_fonts, default=script_font_name)
    parser.add_argument("--donor-dir", type=Path)
    parser.add_argument("--input-dir", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--defer-extra-glyphs", action="store_true", help="Generate intermediate fonts for Nerd patching before adding extra glyphs")
    args = parser.parse_args(argv)
    config = script_fonts[args.donor]
    dist_directory = script_directory.parent / "dist"
    args.donor_dir = (args.donor_dir or script_directory / config["directory"]).expanduser().resolve()
    args.input_dir = (args.input_dir or dist_directory / "iosevka-marcus-cond" / "ttf.patched").expanduser().resolve()
    output_stage = "unpatched" if args.defer_extra_glyphs else "final"
    args.output_dir = (args.output_dir or dist_directory / f"iosemka-script-{args.donor}.{output_stage}").expanduser().resolve()
    return args


def collect_fonts(input_directory):
    if not input_directory.is_dir():
        raise FileNotFoundError(f"Target font directory not found: {input_directory}")
    fonts = []
    styles = set()
    for path in sorted(input_directory.rglob("*")):
        if not path.is_file() or path.suffix.lower() != ".ttf":
            continue
        if not path.stem.startswith(source_prefix):
            raise ValueError(f"Invalid font found in target directory: {path.name}")
        style = path.stem[len(source_prefix):]
        if not style or style.casefold() in styles:
            raise ValueError(f"Empty or duplicate font style: {path.name}")
        styles.add(style.casefold())
        fonts.append((path, style))
    if not fonts:
        raise ValueError(f"No input TTF files found: {input_directory}")
    return fonts


def copy_metadata(font, source_font):
    for attribute in ("fontname", "familyname", "fullname"):
        setattr(font, attribute, getattr(source_font, attribute).replace("Condensed", "Script"))
    font.sfnt_names = tuple(
        (language, name, value.replace("Condensed", "Script"))
        for language, name, value in source_font.sfnt_names
    )
    for attribute in ("sfntRevision", "os2_weight", "os2_width", "os2_stylemap", "os2_panose"):
        setattr(font, attribute, getattr(source_font, attribute))


def process_font(source_path, style, donor_directory, config, output_directory, include_extra_glyphs=True):
    donor_path = None
    if style.endswith("Italic"):
        donor_style = config["style_overrides"].get(style, style)
        donor_path = donor_directory / f"{config['prefix']}{donor_style}.ttf"
        if not donor_path.is_file():
            print(f"Script font {donor_path.name} not found, skipping {style}")
            return False

    print(f"Processing {source_path.name}: {style}")
    source_font = fontforge.open(str(source_path))
    font = source_font
    try:
        if donor_path is not None:
            font = fontforge.open(str(donor_path))
        copy_metadata(font, source_font)
        if donor_path is not None:
            font.em = source_font.em
            font.selection.all()
            font.transform(psMat.scale(config["scale"]))
            font.removeOverlap()
            font.round()
            font.addExtrema()
            font.correctDirection()
        if include_extra_glyphs:
            add_extra_glyphs(font)
        font.generate(str(output_directory / f"{output_prefix}{style}.ttf"))
        return True
    finally:
        if font != source_font:
            font.close()
        source_font.close()


def main(argv=None):
    args = parse_arguments(argv)
    config = script_fonts[args.donor]
    fonts = collect_fonts(args.input_dir)
    if not args.donor_dir.is_dir():
        raise FileNotFoundError(f"Script font directory not found: {args.donor_dir}")
    for directory in (args.input_dir, args.donor_dir):
        if args.output_dir.is_relative_to(directory) or directory.is_relative_to(args.output_dir):
            raise ValueError(f"Output directory must not overlap an input directory: {directory}")

    args.output_dir.parent.mkdir(parents=True, exist_ok=True)
    staging_directory = Path(tempfile.mkdtemp(prefix=".script-glyphs-", dir=args.output_dir.parent))
    skipped_styles = []
    try:
        if not args.defer_extra_glyphs:
            copy_donor_notices(staging_directory)
        for source_path, style in fonts:
            if not process_font(source_path, style, args.donor_dir, config, staging_directory, include_extra_glyphs=not args.defer_extra_glyphs):
                skipped_styles.append(style)
        publish_output(staging_directory, args.output_dir)
    except Exception:
        print(f"Generation failed; staging directory retained at {staging_directory}")
        raise

    if skipped_styles:
        print("Skipped styles without a cursive donor: " + ", ".join(skipped_styles))
    print(f"Done: {args.output_dir}")


if __name__ == "__main__":
    main()