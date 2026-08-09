import contextlib
import io
import json
import pathlib
import unittest

from loader import load

helper = load()

FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"


@contextlib.contextmanager
def self_exit():
    """Swallow the SystemExit every emit() path raises."""
    try:
        yield
    except SystemExit:
        pass


def run(argv):
    """Run main(), returning the parsed JSON it printed."""
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer), self_exit():
        helper.main(argv)
    return json.loads(buffer.getvalue())


class EmitTest(unittest.TestCase):
    def test_stamps_fetched_ms_when_absent(self):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer), self_exit():
            helper.emit({"error": "net"})
        self.assertIn("fetched_ms", json.loads(buffer.getvalue()))

    def test_preserves_existing_fetched_ms(self):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer), self_exit():
            helper.emit({"ok": True, "fetched_ms": 123})
        self.assertEqual(json.loads(buffer.getvalue())["fetched_ms"], 123)

    def test_exits(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit):
                helper.emit({"error": "net"})


class ParseFileModeTest(unittest.TestCase):
    def test_emits_payload_for_a_good_body(self):
        result = run(["opencode-usage.py", "--parse-file",
                      str(FIXTURES / "inline.txt")])
        self.assertTrue(result["ok"])
        self.assertEqual(result["rolling"]["util"], 42)

    def test_emits_parse_error_for_a_bad_body(self):
        bad = FIXTURES / "unparseable.txt"
        bad.write_text("not a usage payload")
        try:
            result = run(["opencode-usage.py", "--parse-file", str(bad)])
            self.assertEqual(result["error"], "parse")
        finally:
            bad.unlink()

    def test_emits_net_error_for_a_missing_file(self):
        result = run(["opencode-usage.py", "--parse-file", "/nonexistent"])
        self.assertEqual(result["error"], "net")


class CredentialTest(unittest.TestCase):
    def setUp(self):
        # main() reads the module global at call time, so pointing it
        # elsewhere is enough -- but put it back, or later tests inherit it.
        original = helper.CURL_PATH
        self.addCleanup(setattr, helper, "CURL_PATH", original)

    def test_no_curl_when_file_missing(self):
        helper.CURL_PATH = "/nonexistent/curl.txt"
        result = run(["opencode-usage.py"])
        self.assertEqual(result["error"], "no-curl")

    def test_bad_curl_when_file_unparseable(self):
        path = FIXTURES / "broken-curl.txt"
        path.write_text("curl --compressed")   # no URL, no cookie
        self.addCleanup(path.unlink)
        helper.CURL_PATH = str(path)
        result = run(["opencode-usage.py"])
        self.assertEqual(result["error"], "bad-curl")


if __name__ == "__main__":
    unittest.main()
