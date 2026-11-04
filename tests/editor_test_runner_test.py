import unittest

from run_editor_test import failure_reason


class EditorTestRunnerTest(unittest.TestCase):
    MARKER = "auto_apply_editor_test: 0 failures"

    def test_clean_completion(self):
        self.assertEqual(failure_reason(0, self.MARKER, self.MARKER), "")

    def test_zero_assertions_do_not_accept_a_crash(self):
        self.assertTrue(failure_reason(-11, self.MARKER, self.MARKER))

    def test_zero_exit_does_not_accept_shutdown_errors(self):
        for diagnostic in [
            "ERROR: Parameter current_window is null.",
            "SCRIPT ERROR: Parse Error: bad source",
            "WARNING: 6 RIDs of type Canvas were leaked.",
            "WARNING: ObjectDB instances leaked at exit.",
        ]:
            with self.subTest(diagnostic=diagnostic):
                self.assertTrue(failure_reason(0, self.MARKER + "\n" + diagnostic, self.MARKER))

    def test_missing_completion_is_not_a_pass(self):
        self.assertTrue(failure_reason(0, "Editor opened", self.MARKER))

    def test_ansi_colored_errors_are_still_errors(self):
        self.assertTrue(failure_reason(0, self.MARKER + "\n\x1b[31mERROR:\x1b[0m leaked", self.MARKER))


if __name__ == "__main__":
    unittest.main()
