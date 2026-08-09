# opencode Usage — KDE Plasma 6 widget

A panel widget for KDE Plasma 6 showing your opencode Go subscription usage —
rolling, weekly, and monthly — with reset countdowns.

- **In the panel:** a circular progress ring for the rolling window,
  colour-coded green → orange → red at 50% / 80%.
- **Click → popup:** all three windows with bars and reset times.
- **Force a refresh:** the popup's **Refresh now** button, middle-click on the
  panel entry, or right-click → *Refresh now*.

## Layout

```
package/                          # the self-contained plasmoid
  metadata.json                   # id com.davegallant.opencodeusage
  contents/
    ui/main.qml                   # UI + logic
    code/opencode-usage.py        # Python helper, resolved at runtime
tests/                            # stdlib unittest, no dependencies
install.sh                        # dev install: symlink + cache clear + restart
build.sh                          # -> dist/opencode-usage.plasmoid
```

## Install

```sh
./install.sh
```

This symlinks `package/` into `~/.local/share/plasma/plasmoids/`, so editing
files here edits the live widget. Add it via right-click → *Add Widgets* →
"opencode Usage".

To build a distributable: `./build.sh`, then
`kpackagetool6 -t Plasma/Applet -i dist/opencode-usage.plasmoid`.

## Configuration

opencode publishes no usage API, so this widget replays a request the web
console makes and scrapes the numbers out of the response.

1. Open the opencode console in your browser.
2. Open DevTools → **Network**.
3. Refresh until you see a request to `_server` (`https://opencode.ai/_server?...`).
4. Right-click it → **Copy** → **Copy as cURL (bash)**.
5. Right-click the widget → **Configure** → paste it in → **OK**.

The widget writes what you paste to `~/.config/opencode-usage/curl.txt` at mode
`600`, which is what the helper actually reads. Editing that file by hand works
just as well if you prefer — set `OPENCODE_USAGE_CURL` to keep it elsewhere,
though the config dialog always writes the default path.

The whole curl command is stored, not just the cookie, because the `_server`
URL carries a server-function ID — and the request carries `x-server-id` /
`x-server-instance` headers — that all go stale together when opencode
redeploys. Re-pasting fixes them in one go.

> **Note:** what you paste contains a live session cookie. It ends up in two
> plaintext places in your home directory: the file above, and Plasma's
> `plasma-org.kde.plasma.desktop-appletsrc`.

The session cookie expires. When it does the widget shows "Session expired";
re-copy the curl. `OPENCODE_API_KEY` (the Zen inference key) is a different
credential and does **not** work here.

## Tests

```sh
python3 -m unittest discover -s tests -v
```

Standard library only — no pytest, no dependencies.

## Gotcha: the QML cache

Plasma serves a **compiled** copy of the QML from
`~/.cache/plasmashell/qmlcache/`. A plain plasmashell restart replays the
cached build, so source edits won't appear until it's cleared. `install.sh`
does this for you.
