"""Import the hyphenated helper script as a module.

`opencode-usage.py` is a script, not a package member, so a plain `import`
can't reach it. Loading it by path keeps the script's name parallel to the
reference project's `claude-usage.py` without renaming it for the tests'
convenience.
"""
import importlib.util
import pathlib

_PATH = (pathlib.Path(__file__).resolve().parent.parent
         / "package" / "contents" / "code" / "opencode-usage.py")


def load():
    spec = importlib.util.spec_from_file_location("opencode_usage", _PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
