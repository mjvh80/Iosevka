

All the private-build-plans.toml are copied to their output dir.

Sample ps command: $font = "marcus-qpe"; npm run build -- "ttf::iosevka-$font"; copy-item .\private-build-plans.toml ".\dist\iosevka-$font\" -Force

Here "qpe" is the part in the toml sections, the family is the "full" name.

The fonts are then patched using nerd font.

Get-ChildItem ..\Iosevka\dist\io* -recurse -Filter *.ttf | ?{ !$_.FullName.Contains("ttf-unhinted") } | %{ &"C:\Program Files (x86)\FontForgeBuilds\fontforge.bat" -script font-patcher --complete --careful -out /C/Users/mjvh8/Repos/Iosevka/dist/iosevka-marcus/patched $_.FullName }  


Usual worflow is:

1. build the Iosevka font from the given plans
2. patch using nerdfont
3. add extra Japanese glyphs to the normal families
4. create Script fonts from condensed, patch their Nerd icons after donor substitution, then add extra Japanese glyphs

For glyph-source customization, see the [Patel, Spiro, and Bezier tutorial](doc/glyph-tutorial.md).

## Complete build

Run `marcus-custom/build_all.ps1` with PowerShell 7 or later. Nerd Fonts patching
uses four concurrent FontForge processes by default; `-patchJobs` controls the
limit, with `1` selecting serial patching. Plans remain sequential. The script
uses the sibling `nerd-fonts` checkout, not the bundled copy.

```powershell
.\marcus-custom\build_all.ps1 -patchJobs 4
.\marcus-custom\build_all.ps1 -skipIoBuild -nameFilter Condensed -patchJobs 8 -scriptDonor Monaspace
```

When the condensed plan is selected, the build also generates the Script family.
`-scriptDonor` selects `CascadiaCode` (the build default), `Monaspace`, or
`VictorMono`. `-skipScript` disables this branch; `-nameFilter` excluding the
condensed plan also skips it. `-skipIoBuild` skips only the Iosevka build, not
Nerd Fonts, Script generation, or extra glyphs.

Script output proceeds through `dist/iosemka-script-<donor>.unpatched`, then
`.patched`, then `.final`. Install only the final fonts. This ordering restores
Nerd icons after the italic donor has replaced the original font. Each Nerd
worker has its own output directory and log; failed batches retain their
`.nerd-fonts-*` work directory, preserve the previous patched output, and stop
the build before downstream stages.

Run the isolated worker and pipeline tests without rebuilding fonts:

```powershell
.\marcus-custom\test_patch_nerd_fonts.ps1
.\marcus-custom\test_build_all.ps1
```

Various scripts:

- opentype_freeze.py: freezes the ss01 feature set into the font (for freezing Cascadia's cursive)
- create_italic_script_font.py: supports Cascadia, Monaspace Radon, or Victor Mono, replacing the italic fonts with their cursive variants


Update to latest upstreams:

1. Fetch the relevant tag from the Iosevka remote and merge.
1. Update the nerd-fonts repository (outside of this one, not contained), checkout the relevant tag.
1. Update donor fonts

## Script font generation

The active `marcus-custom/create_italic_script_font.py` resolves its default
paths from its own location, not the working directory. Moving the repository
does not require editing drive letters or absolute paths. Keep the neighboring
`extra_glyphs.py` helper and donor folders with it.

From the repository root:

```powershell
fontforge -lang=py -script .\marcus-custom\create_italic_script_font.py
fontforge -lang=py -script .\marcus-custom\create_italic_script_font.py --donor Monaspace
fontforge -lang=py -script .\marcus-custom\create_italic_script_font.py --help
```

The first two commands generate fonts; `--help` does not. To run from another
working directory, supply the appropriate path to the script. Optional
`--input-dir`, `--donor-dir`, and `--output-dir` override the defaults; relative
overrides are resolved from your current working directory.

These standalone commands retain the original behavior: donor italics do not
gain missing Nerd icons. Use the complete build above for Nerd-patched Script
fonts. Its `--defer-extra-glyphs` generator mode omits Japanese glyphs and their
notices until the final stage, and defaults to `.unpatched` output instead of
`.final` when no output directory is supplied.

`script_font_name` remains the editable default donor. `script_fonts` groups
each donor's directory, filename prefix, scale, and style overrides. Cascadia
still maps regular Italic to SemiLightItalic at scale 1.0; Monaspace uses 1.1
and Victor Mono uses 1.0. Upright and oblique fonts are not donor-scaled.
The default input remains `dist/iosevka-marcus-cond/ttf.patched`, and output
remains `dist/iosemka-script-<donor>.final`. Non-font files are ignored;
unexpected font names, duplicate styles, and overlapping output/input
directories are rejected before generation.

Run the focused script tests without generating real fonts:

```powershell
fontforge -lang=py -script .\marcus-custom\test_create_italic_script_font.py
```

## Extra Japanese glyphs

`marcus-custom/extra_glyphs.py` adds U+30C4 (katakana tsu), U+30B7 (shi), and
U+30C3 (small tsu) only when they are missing. It uses FontForge's Python,
not the standalone Python interpreter. The editor may flag `fontforge` and
`psMat` as unresolved when its Python environment lacks FontForge's modules;
use the FontForge commands below to run and test these scripts.
Noto Sans CJK JP `Sans2.004` Regular
and Bold are stored in `marcus-custom/noto-sans-cjk-jp` with their license,
source URLs, and SHA-256 hashes.

Change `extra_glyph_font_name` in `extra_glyphs.py` to select another donor;
add its directory, weight-to-filename mapping, and license notices to
`extra_glyph_fonts`. This choice is independent of `script_font_name` in
`create_italic_script_font.py`, which still selects the cursive italic donor.
The closest donor weight is used, with ties going to the lighter weight.
Japanese glyphs remain upright, use two digit-zero advances, and retain their
relative proportions, including the smaller outline of small tsu.

The output flow is now:

1. `build_all.ps1`: Iosevka -> Nerd Fonts in `dist/<plan>/ttf.patched` -> extra
	glyphs in `dist/<plan>/ttf.final`. Install from `ttf.final` for these families.
2. The Script branch of `build_all.ps1`: reads condensed `ttf.patched`, runs
	`create_italic_script_font.py --defer-extra-glyphs` to substitute and scale
	cursive donors, patches Nerd icons in the resulting Script fonts, then adds
	the Japanese glyphs. Output goes to `dist/iosemka-script-<donor>.final`.

Final output directories are staged, then published. Previous final directories
are retained with a `.previous-<timestamp>` suffix. Missing cursive styles are
reported and excluded from the new Script output, not inherited from old runs.
A failed Script run leaves its `.script-glyphs-*` staging directory for inspection
but does not replace the previous final directory. Keep donor license notices
with distributed fonts. The extra-glyph stage only adds Japanese glyphs; the
Script branch's preceding Nerd patching stage restores the donor's missing icons.

Patch existing fonts without building Iosevka or running Nerd Fonts, from the
repository root:

```powershell
fontforge -lang=py -script .\marcus-custom\extra_glyphs.py --input-dir .\dist\iosevka-marcus-cond\ttf.patched --output-dir .\dist\iosevka-marcus-cond\ttf.final
```

For a small sample instead, use `--fonts` followed by explicit TTF paths and
`--output-dir .\dist\extra-glyphs-preview`. The command processes only those files.
It never overwrites its inputs. Rerunning on already-patched fonts copies them
byte-for-byte. The Script generator itself still processes the whole family.

Validation commands (no Iosevka build):

```powershell
fontforge -lang=py -script .\marcus-custom\test_extra_glyphs.py
node .\marcus-custom\validate_extra_glyphs.mjs .\dist\iosevka-marcus-cond\ttf.patched\IosemkaCondensed-Regular.ttf .\dist\extra-glyphs-preview\IosemkaCondensed-Regular.ttf
```

The Node validator uses the repository's installed `ot-builder` and `harfbuzzjs`
dependencies. It checks original glyphs, advances, hinting, naming, metrics, and
sample shaping across OpenType features. Check new outlines visually for clipping
and size before installation. `build_all.ps1 -skipIoBuild` still runs Nerd Fonts
and extra-glyph patching; it is not a dry run.





