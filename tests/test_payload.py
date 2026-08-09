import pathlib
import unittest

from loader import load

helper = load()

FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"


def read(name):
    return (FIXTURES / name).read_text()


class ExtractInlineTest(unittest.TestCase):
    def setUp(self):
        self.body = read("inline.txt")

    def test_extracts_rolling(self):
        self.assertEqual(helper.extract_usage(self.body, "rollingUsage"),
                         {"util": 42, "reset_in_sec": 3600})

    def test_extracts_weekly(self):
        self.assertEqual(helper.extract_usage(self.body, "weeklyUsage"),
                         {"util": 11, "reset_in_sec": 432000})

    def test_extracts_monthly(self):
        self.assertEqual(helper.extract_usage(self.body, "monthlyUsage"),
                         {"util": 63, "reset_in_sec": 1728000})


class ExtractBackrefTest(unittest.TestCase):
    """The bare `$R[n]` shape, where the object is assigned elsewhere."""

    def setUp(self):
        self.body = read("backref.txt")

    def test_extracts_rolling(self):
        self.assertEqual(helper.extract_usage(self.body, "rollingUsage"),
                         {"util": 42, "reset_in_sec": 3600})

    def test_extracts_monthly(self):
        self.assertEqual(helper.extract_usage(self.body, "monthlyUsage"),
                         {"util": 63, "reset_in_sec": 1728000})


class ExtractToleranceTest(unittest.TestCase):
    def test_accepts_quoted_keys(self):
        body = '{"rollingUsage":{"resetInSec":60,"usagePercent":7}}'
        self.assertEqual(helper.extract_usage(body, "rollingUsage"),
                         {"util": 7, "reset_in_sec": 60})

    def test_accepts_reordered_fields(self):
        body = 'rollingUsage:$R[1]={usagePercent:7,resetInSec:60,status:"ok"}'
        self.assertEqual(helper.extract_usage(body, "rollingUsage"),
                         {"util": 7, "reset_in_sec": 60})

    def test_does_not_match_a_different_window(self):
        # weeklyUsage must not satisfy a lookup for rollingUsage.
        body = 'weeklyUsage:{resetInSec:60,usagePercent:7}'
        with self.assertRaises(helper.ParseError):
            helper.extract_usage(body, "rollingUsage")

    def test_raises_when_label_absent(self):
        with self.assertRaises(helper.ParseError):
            helper.extract_usage("nothing here", "rollingUsage")

    def test_raises_when_reference_unresolved(self):
        with self.assertRaises(helper.ParseError):
            helper.extract_usage("rollingUsage:$R[9]", "rollingUsage")

    def test_raises_when_field_missing(self):
        body = 'rollingUsage:{status:"ok",usagePercent:7}'
        with self.assertRaises(helper.ParseError):
            helper.extract_usage(body, "rollingUsage")


class BuildPayloadTest(unittest.TestCase):
    NOW = 1_770_000_000_000

    def test_converts_relative_resets_to_absolute(self):
        payload = helper.build_payload(read("inline.txt"), self.NOW)
        self.assertEqual(payload["rolling"]["resets_ms"],
                         self.NOW + 3600 * 1000)
        self.assertEqual(payload["monthly"]["resets_ms"],
                         self.NOW + 1728000 * 1000)

    def test_carries_all_three_windows(self):
        payload = helper.build_payload(read("inline.txt"), self.NOW)
        self.assertEqual(payload["rolling"]["util"], 42)
        self.assertEqual(payload["weekly"]["util"], 11)
        self.assertEqual(payload["monthly"]["util"], 63)

    def test_stamps_fetched_ms(self):
        payload = helper.build_payload(read("inline.txt"), self.NOW)
        self.assertEqual(payload["fetched_ms"], self.NOW)

    def test_marks_ok(self):
        self.assertTrue(helper.build_payload(read("inline.txt"), self.NOW)["ok"])

    def test_does_not_emit_status(self):
        # Nothing in the UI shows it; don't carry dead data.
        payload = helper.build_payload(read("inline.txt"), self.NOW)
        self.assertNotIn("status", payload["rolling"])

    def test_propagates_parse_error(self):
        with self.assertRaises(helper.ParseError):
            helper.build_payload("garbage", self.NOW)


if __name__ == "__main__":
    unittest.main()
