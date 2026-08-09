"""Validates the scraper against a real captured response.

Synthetic fixtures only prove the regex matches itself. This is the test that
proves the widget works.
"""
import pathlib
import unittest

from loader import load

helper = load()

FIXTURE = (pathlib.Path(__file__).resolve().parent
           / "fixtures" / "server-response.txt")


@unittest.skipUnless(FIXTURE.exists(), "no real capture available")
class RealFixtureTest(unittest.TestCase):
    def setUp(self):
        self.body = FIXTURE.read_text()

    def test_all_three_windows_extract(self):
        for label in ("rollingUsage", "weeklyUsage", "monthlyUsage"):
            with self.subTest(label=label):
                item = helper.extract_usage(self.body, label)
                self.assertIn("util", item)
                self.assertIn("reset_in_sec", item)

    def test_percentages_are_in_range(self):
        payload = helper.build_payload(self.body, 1_770_000_000_000)
        for key in ("rolling", "weekly", "monthly"):
            with self.subTest(key=key):
                self.assertGreaterEqual(payload[key]["util"], 0)
                self.assertLessEqual(payload[key]["util"], 100)

    def test_resets_are_in_the_future(self):
        now = 1_770_000_000_000
        payload = helper.build_payload(self.body, now)
        for key in ("rolling", "weekly", "monthly"):
            with self.subTest(key=key):
                self.assertGreater(payload[key]["resets_ms"], now)


if __name__ == "__main__":
    unittest.main()
