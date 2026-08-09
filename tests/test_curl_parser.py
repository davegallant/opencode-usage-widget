import unittest

from loader import load

helper = load()


class TokenizeTest(unittest.TestCase):
    def test_splits_on_whitespace(self):
        self.assertEqual(helper.tokenize("curl https://x.test"),
                         ["curl", "https://x.test"])

    def test_single_quotes_hold_spaces_together(self):
        self.assertEqual(helper.tokenize("-H 'accept: text/x-component'"),
                         ["-H", "accept: text/x-component"])

    def test_double_quotes_hold_spaces_together(self):
        self.assertEqual(helper.tokenize('-H "accept: text/plain"'),
                         ["-H", "accept: text/plain"])

    def test_backslash_escapes_next_character(self):
        # The escaped space joins "a" and "b"; the unescaped one still splits.
        self.assertEqual(helper.tokenize(r"a\ b c"), ["a b", "c"])

    def test_line_continuations_are_dropped(self):
        # DevTools emits multi-line curl with trailing backslashes.
        self.assertEqual(helper.tokenize("curl \\\n  https://x.test"),
                         ["curl", "https://x.test"])


class ParseCurlTest(unittest.TestCase):
    COMMAND = (
        "curl 'https://opencode.ai/_server?id=abc123' \\\n"
        "  -H 'accept: text/x-component' \\\n"
        "  -H 'user-agent: Mozilla/5.0' \\\n"
        "  -H 'Cookie: session=deadbeef; other=1' \\\n"
        "  --compressed"
    )

    def test_extracts_url(self):
        self.assertEqual(helper.parse_curl(self.COMMAND)["url"],
                         "https://opencode.ai/_server?id=abc123")

    def test_extracts_headers(self):
        headers = helper.parse_curl(self.COMMAND)["headers"]
        self.assertEqual(headers["accept"], "text/x-component")
        self.assertEqual(headers["user-agent"], "Mozilla/5.0")

    def test_cookie_is_lifted_out_of_headers(self):
        parsed = helper.parse_curl(self.COMMAND)
        self.assertEqual(parsed["cookie"], "session=deadbeef; other=1")
        self.assertNotIn("Cookie", parsed["headers"])
        self.assertNotIn("cookie", parsed["headers"])

    def test_accepts_b_flag_for_cookie(self):
        command = "curl 'https://x.test' -b 'session=abc'"
        self.assertEqual(helper.parse_curl(command)["cookie"], "session=abc")

    def test_rejects_empty_command(self):
        with self.assertRaises(helper.CurlError):
            helper.parse_curl("   ")

    def test_rejects_command_without_url(self):
        with self.assertRaises(helper.CurlError):
            helper.parse_curl("curl -H 'Cookie: a=b'")

    def test_rejects_command_without_cookie(self):
        with self.assertRaises(helper.CurlError):
            helper.parse_curl("curl 'https://x.test' -H 'accept: x'")

    def test_skips_flag_values_that_look_like_urls(self):
        # --data-raw payloads can embed URLs; only the bare positional arg
        # is the request target.
        command = ("curl --data-raw 'https://decoy.test' "
                   "'https://real.test' -b 'a=b'")
        self.assertEqual(helper.parse_curl(command)["url"], "https://real.test")

    def test_drops_accept_encoding(self):
        # urllib forwards it but never decompresses, so replaying Chrome's
        # accept-encoding yields gzip bytes that fail to scrape.
        command = ("curl 'https://x.test' -b 'a=b' "
                   "-H 'accept-encoding: gzip, deflate, br, zstd'")
        headers = helper.parse_curl(command)["headers"]
        self.assertNotIn("accept-encoding", [k.lower() for k in headers])

    def test_captures_request_body(self):
        command = "curl 'https://x.test' -b 'a=b' --data-raw '[\"arg\"]'"
        self.assertEqual(helper.parse_curl(command)["body"], '["arg"]')

    def test_body_is_none_when_absent(self):
        command = "curl 'https://x.test' -b 'a=b'"
        self.assertIsNone(helper.parse_curl(command)["body"])


if __name__ == "__main__":
    unittest.main()
