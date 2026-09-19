import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import create_italic_script_font as script


class PathTests(unittest.TestCase):
    def test_defaults_follow_relocated_script_not_working_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            relocated = root / "relocated-repo" / "marcus-custom"
            previous_directory = Path.cwd()
            try:
                os.chdir(root)
                with patch.object(script, "script_directory", relocated):
                    args = script.parse_arguments([])
            finally:
                os.chdir(previous_directory)
            self.assertEqual(args.donor_dir, relocated / "cascadia_frozen")
            self.assertEqual(args.input_dir, relocated.parent / "dist" / "iosevka-marcus-cond" / "ttf.patched")
            self.assertEqual(args.output_dir, relocated.parent / "dist" / "iosemka-script-CascadiaCode.final")

    def test_donor_defaults_and_explicit_paths(self):
        for name, config in script.script_fonts.items():
            with self.subTest(donor=name):
                args = script.parse_arguments(["--donor", name])
                self.assertEqual(args.donor_dir, script.script_directory / config["directory"])
                self.assertEqual(args.output_dir.name, f"iosemka-script-{name}.final")
        args = script.parse_arguments([
            "--input-dir", "input fonts", "--donor-dir", "donor fonts", "--output-dir", "output fonts",
        ])
        self.assertEqual(args.input_dir, (Path.cwd() / "input fonts").resolve())
        self.assertEqual(args.donor_dir, (Path.cwd() / "donor fonts").resolve())
        self.assertEqual(args.output_dir, (Path.cwd() / "output fonts").resolve())

    def test_deferred_glyphs_default_to_intermediate_output(self):
        args = script.parse_arguments(["--defer-extra-glyphs"])
        self.assertEqual(args.output_dir.name, "iosemka-script-CascadiaCode.unpatched")
        self.assertTrue(args.defer_extra_glyphs)

    def test_collection_ignores_notices_and_rejects_duplicate_styles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "LICENSE").touch()
            regular = root / "IosemkaCondensed-Regular.ttf"
            regular.touch()
            self.assertEqual(script.collect_fonts(root), [(regular, "Regular")])
            nested = root / "nested"
            nested.mkdir()
            (nested / regular.name).touch()
            with self.assertRaisesRegex(ValueError, "duplicate"):
                script.collect_fonts(root)

    def test_empty_and_unexpected_fonts_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "No input TTF"):
                script.collect_fonts(root)
            (root / "Unexpected.ttf").touch()
            with self.assertRaisesRegex(ValueError, "Invalid font"):
                script.collect_fonts(root)


class ProcessingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = Mock(
            fontname="IosemkaCondensed-Italic", familyname="Iosemka Condensed",
            fullname="Iosemka Condensed Italic", sfntRevision=34.8, em=1000,
            os2_weight=400, os2_width=5, os2_stylemap=1, os2_panose=(2, 11, 5),
            sfnt_names=(("English (US)", "Family", "Iosemka Condensed"),),
        )

    def test_regular_and_oblique_are_not_scaled_and_close_once(self):
        for style in ("Regular", "Oblique"):
            with self.subTest(style=style):
                self.source.reset_mock()
                path = self.root / f"IosemkaCondensed-{style}.ttf"
                with patch.object(script.fontforge, "open", return_value=self.source) as open_font:
                    with patch.object(script, "add_extra_glyphs") as add_glyphs:
                        result = script.process_font(path, style, self.root, script.script_fonts["Monaspace"], self.root)
                self.assertTrue(result)
                open_font.assert_called_once_with(str(path))
                self.source.transform.assert_not_called()
                self.source.removeOverlap.assert_not_called()
                self.source.close.assert_called_once()
                add_glyphs.assert_called_once_with(self.source)

    def test_italic_mapping_metadata_and_processing_order(self):
        donor = Mock()
        (self.root / "CascadiaCode-SemiLightItalic.ttf").touch()
        source_path = self.root / "IosemkaCondensed-Italic.ttf"
        calls = Mock()
        calls.attach_mock(donor.transform, "scale")
        calls.attach_mock(donor.correctDirection, "cleanup")
        calls.attach_mock(donor.generate, "generate")
        with patch.object(script.fontforge, "open", side_effect=[self.source, donor]) as open_font:
            with patch.object(script, "add_extra_glyphs") as add_glyphs:
                calls.attach_mock(add_glyphs, "extra")
                self.assertTrue(script.process_font(source_path, "Italic", self.root, script.script_fonts["CascadiaCode"], self.root))
        self.assertEqual(open_font.call_args_list[1].args[0], str(self.root / "CascadiaCode-SemiLightItalic.ttf"))
        self.assertEqual(donor.fontname, "IosemkaScript-Italic")
        self.assertEqual(donor.sfnt_names, (("English (US)", "Family", "Iosemka Script"),))
        for attribute in ("em", "sfntRevision", "os2_weight", "os2_width", "os2_stylemap", "os2_panose"):
            self.assertEqual(getattr(donor, attribute), getattr(self.source, attribute))
        self.assertEqual([call[0] for call in calls.mock_calls], ["scale", "cleanup", "extra", "generate"])
        donor.close.assert_called_once()
        self.source.close.assert_called_once()

    def test_intermediate_fonts_defer_extra_glyphs(self):
        with patch.object(script.fontforge, "open", return_value=self.source):
            with patch.object(script, "add_extra_glyphs") as add_glyphs:
                self.assertTrue(script.process_font(
                    self.root / "source.ttf", "Regular", self.root,
                    script.script_fonts["CascadiaCode"], self.root, include_extra_glyphs=False,
                ))
        add_glyphs.assert_not_called()
        self.source.generate.assert_called_once_with(str(self.root / "IosemkaScript-Regular.ttf"))
        self.source.close.assert_called_once()

    def test_missing_italic_is_skipped_before_opening_source(self):
        with patch.object(script.fontforge, "open") as open_font:
            self.assertFalse(script.process_font(self.root / "input.ttf", "HeavyItalic", self.root, script.script_fonts["CascadiaCode"], self.root))
            open_font.assert_not_called()

    def test_generation_failure_closes_both_fonts(self):
        donor = Mock()
        donor.generate.side_effect = RuntimeError("generation failed")
        (self.root / "VictorMono-BoldItalic.ttf").touch()
        with patch.object(script.fontforge, "open", side_effect=[self.source, donor]):
            with patch.object(script, "add_extra_glyphs"):
                with self.assertRaisesRegex(RuntimeError, "generation failed"):
                    script.process_font(self.root / "source.ttf", "BoldItalic", self.root, script.script_fonts["VictorMono"], self.root)
        donor.close.assert_called_once()
        self.source.close.assert_called_once()


class WorkflowTests(unittest.TestCase):
    def test_intermediate_workflow_defers_glyphs_and_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = root / "inputs"
            donors = root / "donors"
            inputs.mkdir()
            donors.mkdir()
            (inputs / "IosemkaCondensed-Regular.ttf").touch()
            with patch.object(script, "copy_donor_notices") as notices:
                with patch.object(script, "process_font", return_value=True) as process:
                    with patch.object(script, "publish_output") as publish:
                        script.main([
                            "--input-dir", str(inputs), "--donor-dir", str(donors),
                            "--output-dir", str(root / "unpatched"), "--defer-extra-glyphs",
                        ])
            notices.assert_not_called()
            self.assertFalse(process.call_args.kwargs["include_extra_glyphs"])
            publish.assert_called_once()

    def test_failed_batch_does_not_publish(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = root / "inputs"
            donors = root / "donors"
            output = root / "new-parent" / "final"
            inputs.mkdir()
            donors.mkdir()
            (inputs / "IosemkaCondensed-Regular.ttf").touch()
            with patch.object(script, "copy_donor_notices"):
                with patch.object(script, "process_font", side_effect=RuntimeError("test failure")):
                    with patch.object(script, "publish_output") as publish:
                        with self.assertRaisesRegex(RuntimeError, "test failure"):
                            script.main(["--input-dir", str(inputs), "--donor-dir", str(donors), "--output-dir", str(output)])
                        publish.assert_not_called()
            self.assertFalse(output.exists())
            self.assertEqual(len(list(output.parent.glob(".script-glyphs-*"))), 1)

    def test_overlapping_output_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "IosemkaCondensed-Regular.ttf").touch()
            with self.assertRaisesRegex(ValueError, "must not overlap"):
                script.main(["--input-dir", str(root), "--donor-dir", str(root), "--output-dir", str(root / "final")])
            self.assertFalse((root / "final").exists())


if __name__ == "__main__":
    unittest.main()