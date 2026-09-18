import unittest
from unittest.mock import patch
from pathlib import Path
import tempfile

import fontforge

import extra_glyphs


def rectangle(font, codepoint, size, width):
    glyph = font.createChar(codepoint)
    pen = glyph.glyphPen()
    pen.moveTo((100, 0))
    pen.lineTo((100, size))
    pen.lineTo((100 + size, size))
    pen.lineTo((100 + size, 0))
    pen.closePath()
    pen = None
    glyph.width = width
    return glyph


class ExtraGlyphTests(unittest.TestCase):
    def setUp(self):
        self.target = fontforge.font()
        self.target.encoding = "UnicodeFull"
        self.target.em = 1000
        self.target.ascent = 800
        self.target.descent = 200
        self.target.os2_weight = 400
        rectangle(self.target, ord("0"), 500, 680)

    def tearDown(self):
        self.target.close()

    def make_donor(self):
        donor = fontforge.font()
        donor.encoding = "UnicodeFull"
        donor.em = 1000
        for codepoint in extra_glyphs.extra_glyph_codepoints:
            rectangle(donor, codepoint, 350 if codepoint == 0x30C3 else 700, 1000)
        return donor

    def test_adds_missing_glyphs_without_changing_existing_glyphs_or_metrics(self):
        zero_bounds = self.target[ord("0")].boundingBox()
        rectangle(self.target, 0x30B7, 200, 777)
        existing_bounds = self.target[0x30B7].boundingBox()
        with patch.object(extra_glyphs.fontforge, "open", return_value=self.make_donor()):
            added = extra_glyphs.add_extra_glyphs(self.target)
        self.assertEqual(added, [0x30C4, 0x30C3])
        self.assertEqual(self.target[0x30B7].boundingBox(), existing_bounds)
        self.assertEqual(self.target[0x30B7].width, 777)
        self.assertEqual(self.target[ord("0")].boundingBox(), zero_bounds)
        self.assertEqual(self.target[ord("0")].width, 680)
        self.assertEqual((self.target.em, self.target.ascent, self.target.descent), (1000, 800, 200))
        self.assertEqual(self.target[0x30C4].width, 1360)
        self.assertEqual(self.target[0x30C3].width, 1360)
        self.assertLess(self.target[0x30C3].boundingBox()[3], self.target[0x30C4].boundingBox()[3])

    def test_second_run_does_not_open_donor_or_change_glyphs(self):
        with patch.object(extra_glyphs.fontforge, "open", return_value=self.make_donor()):
            extra_glyphs.add_extra_glyphs(self.target)
        bounds = self.target[0x30C4].boundingBox()
        with patch.object(extra_glyphs.fontforge, "open") as open_donor:
            self.assertEqual(extra_glyphs.add_extra_glyphs(self.target), [])
            open_donor.assert_not_called()
        self.assertEqual(self.target[0x30C4].boundingBox(), bounds)

    def test_incomplete_donor_fails_before_adding_any_glyphs(self):
        donor = self.make_donor()
        donor.removeGlyph(0x30C3)
        with patch.object(extra_glyphs.fontforge, "open", return_value=donor):
            with self.assertRaisesRegex(ValueError, "missing U\\+30C3"):
                extra_glyphs.add_extra_glyphs(self.target)
        self.assertFalse(extra_glyphs.has_glyph(self.target, 0x30C4))

    def test_donor_weight_and_selection_are_configurable(self):
        self.assertEqual(extra_glyphs.donor_path_for(self.target).name, "NotoSansCJKjp-Regular.otf")
        self.target.os2_weight = 600
        self.assertEqual(extra_glyphs.donor_path_for(self.target).name, "NotoSansCJKjp-Bold.otf")
        alternative = {"directory": "alternative", "weights": {400: "Alternate.ttf"}}
        with patch.object(extra_glyphs, "extra_glyph_font_name", "Alternative"):
            with patch.dict(extra_glyphs.extra_glyph_fonts, {"Alternative": alternative}):
                self.assertEqual(extra_glyphs.donor_path_for(self.target).name, "Alternate.ttf")

    def test_non_unicode_encodings_are_supported(self):
        self.target.encoding = "ISO8859-1"
        donor = self.make_donor()
        donor.encoding = "ISO8859-1"
        with patch.object(extra_glyphs.fontforge, "open", return_value=donor):
            self.assertEqual(extra_glyphs.add_extra_glyphs(self.target), list(extra_glyphs.extra_glyph_codepoints))
        for codepoint in extra_glyphs.extra_glyph_codepoints:
            self.assertTrue(extra_glyphs.has_glyph(self.target, codepoint))

    def test_outlines_fit_without_squashing_small_katakana(self):
        self.target[ord("0")].width = 300
        with patch.object(extra_glyphs.fontforge, "open", return_value=self.make_donor()):
            extra_glyphs.add_extra_glyphs(self.target)
        for codepoint in extra_glyphs.extra_glyph_codepoints:
            minimum_x, minimum_y, maximum_x, maximum_y = self.target[codepoint].boundingBox()
            self.assertGreaterEqual(minimum_x, 0)
            self.assertLessEqual(maximum_x, 600)
            self.assertGreaterEqual(minimum_y, -self.target.descent)
            self.assertLessEqual(maximum_y, self.target.ascent)
        self.assertAlmostEqual(self.target[0x30C3].boundingBox()[3] * 2, self.target[0x30C4].boundingBox()[3], delta=1)


class OutputTests(unittest.TestCase):
    def test_failed_batch_preserves_previous_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "final"
            output.mkdir()
            previous = output / "existing.ttf"
            previous.write_bytes(b"previous output")
            with patch.object(extra_glyphs, "copy_donor_notices"):
                with patch.object(extra_glyphs, "patch_font_file", side_effect=ValueError("bad donor")):
                    with self.assertRaisesRegex(ValueError, "bad donor"):
                        extra_glyphs.patch_fonts([root / "input.ttf"], output)
            self.assertEqual(previous.read_bytes(), b"previous output")
            self.assertEqual(list(root.iterdir()), [output])

    def test_publishing_keeps_backup_and_excludes_stale_styles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "final"
            output.mkdir()
            (output / "old.ttf").write_bytes(b"old font")
            staged = root / "staged"
            staged.mkdir()
            (staged / "new.ttf").write_bytes(b"new font")
            extra_glyphs.publish_output(staged, output)
            self.assertEqual((output / "new.ttf").read_bytes(), b"new font")
            self.assertFalse((output / "old.ttf").exists())
            backups = list(root.glob("final.previous-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual((backups[0] / "old.ttf").read_bytes(), b"old font")

    def test_output_cannot_contain_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "must not contain"):
                extra_glyphs.patch_fonts([Path(directory) / "input.ttf"], directory)

    def test_noop_file_patch_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.ttf"
            output = Path(directory) / "output.ttf"
            font = fontforge.font()
            font.encoding = "UnicodeFull"
            rectangle(font, ord("0"), 400, 680)
            for codepoint in extra_glyphs.extra_glyph_codepoints:
                rectangle(font, codepoint, 600, 1360)
            font.generate(str(source))
            font.close()
            with patch.object(extra_glyphs, "donor_path_for") as choose_donor:
                result = extra_glyphs.patch_font_file(source, output)
                choose_donor.assert_not_called()
            self.assertEqual(result["added"], [])
            self.assertEqual(source.read_bytes(), output.read_bytes())


if __name__ == "__main__":
    unittest.main()