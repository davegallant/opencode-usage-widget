#!/usr/bin/env python3
"""Fetch opencode Go subscription usage for the Plasma widget.

opencode publishes no usage API, so this replays a request the web console
makes to https://opencode.ai/_server and scrapes the three usage windows out
of the Solid-serialized response. The user supplies that request by pasting
DevTools' "Copy as cURL (bash)" into ~/.config/opencode-usage/curl.txt.

Emits one line of compact JSON. Reset times arrive relative (resetInSec) and
are converted to absolute epoch milliseconds here so the QML never has to do
date arithmetic.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CURL_PATH = os.path.expanduser(
    os.environ.get("OPENCODE_USAGE_CURL", "~/.config/opencode-usage/curl.txt"))

# (emitted key, label in the serialized payload)
WINDOWS = (
    ("rolling", "rollingUsage"),
    ("weekly", "weeklyUsage"),
    ("monthly", "monthlyUsage"),
)

# curl flags that take no value, so the walk must not swallow the next token.
_VALUELESS = frozenset([
    "--compressed", "-L", "--location", "-s", "--silent", "-S", "-v",
    "--verbose", "-I", "-i", "--include", "--http1.1", "--http2",
    "-k", "--insecure", "-g", "--globoff", "--no-buffer",
])

# Headers that must not be replayed. accept-encoding is the dangerous one:
# Chrome's "Copy as cURL" sends `gzip, deflate, br, zstd`, urllib forwards it
# but never decompresses, and the compressed bytes then fail to scrape --
# surfacing as a bogus "opencode changed its response format".
_DROP_HEADERS = frozenset(["accept-encoding", "content-length", "host"])

_BODY_FLAGS = frozenset(["-d", "--data", "--data-raw", "--data-binary",
                         "--data-ascii"])


class CurlError(Exception):
    """The saved curl command couldn't be understood."""


def tokenize(command):
    """Split a shell command, honouring quotes and backslash escapes."""
    tokens = []
    current = ""
    started = False          # distinguishes '' from absent
    single = double = False
    escaping = False

    for char in command:
        if escaping:
            # A backslash before a newline is a line continuation, not an
            # escaped character -- DevTools wraps long curl commands that way.
            if char != "\n":
                current += char
                started = True
            escaping = False
            continue
        if char == "\\" and not single:
            escaping = True
            continue
        if single:
            if char == "'":
                single = False
            else:
                current += char
            continue
        if double:
            if char == '"':
                double = False
            else:
                current += char
            continue
        if char == "'":
            single = True
            started = True
            continue
        if char == '"':
            double = True
            started = True
            continue
        if char.isspace():
            if started or current:
                tokens.append(current)
            current = ""
            started = False
            continue
        current += char
        started = True

    if started or current:
        tokens.append(current)
    return tokens


def parse_curl(command):
    """Pull the URL, headers, cookie, and body out of a DevTools curl."""
    tokens = tokenize(command.strip())
    if not tokens:
        raise CurlError("empty command")

    url = None
    headers = {}
    cookie = None
    body = None

    index = 0
    while index < len(tokens):
        token = tokens[index]

        if index == 0 and token.lower() == "curl":
            index += 1
            continue
        if token in _VALUELESS:
            index += 1
            continue

        if token in ("-H", "--header"):
            if index + 1 >= len(tokens):
                raise CurlError("missing value for %s" % token)
            name, sep, value = tokens[index + 1].partition(":")
            if sep:
                lowered = name.strip().lower()
                if lowered == "cookie":
                    cookie = value.strip()
                elif lowered not in _DROP_HEADERS:
                    headers[name.strip()] = value.strip()
            index += 2
            continue

        if token in _BODY_FLAGS:
            if index + 1 >= len(tokens):
                raise CurlError("missing value for %s" % token)
            body = tokens[index + 1]
            index += 2
            continue

        if token in ("-b", "--cookie"):
            if index + 1 >= len(tokens):
                raise CurlError("missing value for %s" % token)
            cookie = tokens[index + 1]
            index += 2
            continue

        # Any other flag is assumed to take a value, so skip both. This is
        # what keeps a URL inside --data-raw from being mistaken for the
        # request target.
        if token.startswith("-"):
            index += 2 if index + 1 < len(tokens) else 1
            continue

        if token.lower().startswith(("http://", "https://")):
            url = token
        index += 1

    if url is None:
        raise CurlError("no URL found")
    if cookie is None:
        raise CurlError("no cookie found")
    return {"url": url, "headers": headers, "cookie": cookie, "body": body}


class ParseError(Exception):
    """The response didn't contain the usage figures where expected."""


def _field(obj, key):
    match = re.search(r'["\']?' + key + r'["\']?\s*:\s*(\d+)', obj)
    if match is None:
        raise ParseError("missing field %s" % key)
    return int(match.group(1))


def _fields(obj):
    return {"util": _field(obj, "usagePercent"),
            "reset_in_sec": _field(obj, "resetInSec")}


def extract_usage(body, label):
    """Read one usage window out of the serialized response.

    Handles both shapes seroval emits: the value inlined after the label, and
    a bare `$R[n]` back-reference whose object is assigned elsewhere in the
    body. Matching only the inline form would drop into a permanent `parse`
    error the moment opencode's serializer decides to share a reference.
    """
    quoted = r'["\']?' + re.escape(label) + r'["\']?\s*:\s*'

    inline = re.search(quoted + r'(?:\$R\[\d+\]\s*=\s*)?(\{[^{}]*\})', body)
    if inline:
        return _fields(inline.group(1))

    ref = re.search(quoted + r'\$R\[(\d+)\]', body)
    if ref is None:
        raise ParseError("no match for %s" % label)

    assigned = re.search(r'\$R\[' + ref.group(1) + r'\]\s*=\s*(\{[^{}]*\})',
                         body)
    if assigned is None:
        raise ParseError("unresolved reference for %s" % label)
    return _fields(assigned.group(1))


def build_payload(body, now_ms):
    """Turn a raw response body into the JSON the widget consumes."""
    payload = {"ok": True, "fetched_ms": now_ms}
    for key, label in WINDOWS:
        item = extract_usage(body, label)
        payload[key] = {
            "util": item["util"],
            # resetInSec is relative; the QML's countdown wants an absolute
            # epoch. Converting here keeps date handling out of QML entirely.
            "resets_ms": now_ms + item["reset_in_sec"] * 1000,
        }
    return payload


def emit(obj):
    """Print one line of JSON and stop. Every exit path goes through here."""
    obj.setdefault("fetched_ms", int(time.time() * 1000))
    print(json.dumps(obj))
    raise SystemExit(0)


def read_curl():
    with open(CURL_PATH) as handle:
        return handle.read()


def fetch(parsed):
    # No explicit method: urllib sends GET without a body and POST with one,
    # which is what the captured request needs. Solid's _server endpoints are
    # POST when they carry serialized arguments.
    body = parsed.get("body")
    request = urllib.request.Request(
        parsed["url"], data=body.encode() if body else None)
    for name, value in parsed["headers"].items():
        request.add_header(name, value)
    request.add_header("Cookie", parsed["cookie"])
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.read().decode("utf-8", "replace")


def _emit_parsed(body):
    try:
        emit(build_payload(body, int(time.time() * 1000)))
    except ParseError:
        emit({"error": "parse"})


def main(argv):
    # Offline mode: run the scraper against a saved body. This is how the
    # regex gets validated against a real capture without a live session.
    if len(argv) > 2 and argv[1] == "--parse-file":
        try:
            with open(argv[2]) as handle:
                body = handle.read()
        except OSError:
            emit({"error": "net"})
        _emit_parsed(body)

    try:
        command = read_curl()
    except OSError:
        emit({"error": "no-curl"})

    try:
        parsed = parse_curl(command)
    except CurlError:
        emit({"error": "bad-curl"})

    try:
        body = fetch(parsed)
    except urllib.error.HTTPError as error:
        # 401/403 mean the session cookie died; the QML turns that into
        # "re-copy your curl" rather than a generic failure.
        emit({"error": "http-%d" % error.code})
    except Exception:
        emit({"error": "net"})

    _emit_parsed(body)


if __name__ == "__main__":
    main(sys.argv)
