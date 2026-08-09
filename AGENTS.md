# AGENTS.md — opencode-usage-widget

KDE Plasma 6 (Qt6/KF6) panel widget showing opencode Go subscription usage:
rolling, weekly, and monthly, with reset countdowns. A port of
[opencode-usage](https://github.com/davegallant/opencode-usage) (macOS menu
bar, SwiftUI) onto the structure of
[claude-usage-widget](https://github.com/davegallant/claude-usage-widget),
which remains the reference for every QML idiom here.

## Architecture

QML owns the UI. A Python helper owns credentials, HTTP, and scraping, and
prints a single line of JSON. They meet at a `Plasma5Support.DataSource` in
`exec` mode. Date arithmetic, network, and the scraping regex stay out of QML
entirely.

| Path | Responsibility |
|---|---|
| `package/metadata.json` | Plasmoid identity, Plasma API version |
| `package/contents/ui/main.qml` | All UI and state |
| `package/contents/ui/configGeneral.qml` | Config page: paste the curl |
| `package/contents/config/main.xml` | `curlCommand` config entry |
| `package/contents/config/config.qml` | Config category declaration |
| `package/contents/code/opencode-usage.py` | Curl parsing, HTTP, scraping, JSON |
| `tests/` | stdlib `unittest`, fixture-driven |
| `build.sh` / `install.sh` | `.plasmoid` build / dev symlink install |

The helper ships **inside** the package and is resolved at runtime via
`Qt.resolvedUrl`, so the widget is self-contained and distributable — nothing
lives in `~/.local/bin`.

## Constraints

- **Python standard library only.** pytest is not installed; tests are
  `unittest`. No third-party imports anywhere.
- Plugin ID `com.davegallant.opencodeusage`; author Dave Gallant; MIT;
  category System Information; icon `utilities-system-monitor`.
- Targets Plasma 6 (developed against 6.6.6), `X-Plasma-API-Minimum-Version`
  `6.0`.
- Poll 300000 ms; clock tick 15000 ms; HTTP timeout 10 s; busy watchdog
  20000 ms.
- Colour thresholds by raw percentage: `<= 50` positive, `<= 80` neutral, else
  negative.
- Error kinds, exactly: `no-curl`, `bad-curl`, `http-<n>`, `net`, `parse`,
  `save`, `exec`.
- Conventional Commits: `<type>(<scope>): <summary>`, imperative, ≤72 chars,
  no footers, no sign-offs.
- **Never commit an unredacted capture.** See Testing.

## Working on this

- `package/` is **symlinked** into
  `~/.local/share/plasma/plasmoids/com.davegallant.opencodeusage`. Run
  `./install.sh` to (re)create the symlink, clear the QML cache, and restart
  plasmashell.
- **Check where that path actually points before trusting it.** On this machine
  home-manager also declares the plasmoid, so the path is periodically a symlink
  into `/nix/store` rather than into this repo — and a store copy built from an
  earlier commit is byte-identical to your checkout right up until you edit
  something, at which point every check you run silently describes the old code.
  `ls -l ~/.local/share/plasma/plasmoids/` costs nothing. `install.sh` repoints
  it at the repo, which a later home-manager activation may undo.
- **Always clear `~/.cache/plasmashell/qmlcache/` after editing `main.qml`** —
  Plasma runs the *compiled* cache, not your source, so a plain restart shows
  no change. This is the biggest footgun here. `install.sh` handles it.
- Note that `install.sh` restarts plasmashell, which visibly disrupts the
  desktop. Ask before running it on someone's live session.
- Tests: `python3 -m unittest discover -s tests -v` from the repo root.

### Validating QML

Neither `plasmoidviewer` nor `qmllint` is installed by default on this machine.
Both are a `nix shell` away:

```sh
nix shell nixpkgs#qt6.qtdeclarative -c qmllint -I /run/current-system/sw/lib/qt-6/qml package/contents/ui/main.qml
nix shell nixpkgs#kdePackages.plasma-sdk -c plasmoidviewer -a com.davegallant.opencodeusage
```

`qmllint` run this way emits a wall of `[import]`, `[unqualified]`, and
`[unresolved-type]` warnings because the Plasma modules don't resolve outside
plasmashell. **Ignore those and grep for `[syntax]`** — that's the only
category that means the file is actually broken:

```sh
... qmllint ... 2>&1 | grep '\[syntax\]'
```

`plasmoidviewer` needs `-f horizontal` or `-f vertical` to show the in-panel
(compact) form — bare `-a` opens the popup instead. It resolves the applet by
plugin name, so it renders whatever the plasmoid path points at, with the
staleness trap above. Neither tool exercises the config dialog — that needs a
real install.

**`plasmoidviewer` does not render offscreen**, despite what this file used to
claim. With a live session it opens a real window on the desktop. There is no
headless route either: `-platform offscreen` never drives a render pass, so
`grabToImage`'s callback never fires and the process hangs until killed, and
`XMLHttpRequest` GET on a `file://` URL returns empty (reads are gated, not just
the PUT writes noted above).

So an agent working here **cannot see this widget**, and should not claim to.
What does work is `qmllint` for syntax, and an offscreen `qml` scene carrying
its result out through `Qt.exit(n)` — `console.log` is swallowed by this
environment's Qt logging rules, so the exit code is the only channel. That is
enough to check geometry and text metrics; appearance needs a human.

Two traps when writing throwaway QML to test something:

- `console.log` is swallowed by this environment's Qt logging rules. Carry
  results in the **exit code** (`Qt.exit(n)`) instead, or "no output" will look
  like success.
- `XMLHttpRequest` PUT to a `file://` URL is gated behind
  `QML_XHR_ALLOW_FILE_WRITE`. Without it the call hangs forever rather than
  failing. This is why the config page shells out instead.

## Data source

opencode publishes no usage API. The helper replays a request the web console
makes to `https://opencode.ai/_server`, captured via DevTools → "Copy as cURL
(bash)", and scrapes the three windows out of the response.

- The **whole curl** is stored, not just the cookie: the `_server` URL carries
  a server-function ID, and the request carries `x-server-id` /
  `x-server-instance` headers, which all go stale together when opencode
  redeploys. Re-pasting fixes them in one go.
- `parse_curl` **drops `accept-encoding`**. Chrome's copied curl asks for
  `gzip, deflate, br, zstd`; urllib forwards the header but never decompresses,
  so the scrape fails and the widget blames opencode for changing its format.
  Don't "fix" this by re-adding the header — zstd isn't in the stdlib.
- `parse_curl` captures `--data-raw` into `body`, and `fetch()` sends POST when
  it's present (urllib picks the method off `data`). Firefox and Chrome differ
  in whether they emit one. `-X` is *not* honoured; if a capture needs an
  explicit method, add it.
- The response is seroval/Solid-serialized. `extract_usage()` handles **two**
  shapes: inline (`rollingUsage: $R[7] = {…}`) and a bare back-reference
  (`rollingUsage: $R[7]`, object assigned elsewhere). Matching only the inline
  form drops the widget into a permanent `parse` error the moment opencode's
  serializer shares a reference — the most likely way this widget breaks.
  **As captured (Aug 2026) opencode emits the inline shape**, pretty-printed
  across newlines, inside a `self.$R["server-fn:5"]` IIFE; see
  `tests/fixtures/server-response.txt`. The back-reference branch is untested
  against real bytes and exists as insurance.
- The payload also carries `mine`, `useBalance`, and `region`. None are used.
- `resetInSec` is time *remaining* in the current window, not the window
  length — a "monthly" figure of ~7 days just means the month is three quarters
  gone. Don't read window sizes out of it.
- `resetInSec` is **relative**; the helper converts to absolute `resets_ms` so
  the QML never parses dates.
- `status` is matched structurally but not emitted — nothing shows it.
- `--parse-file <path>` runs the scraper against a saved body with no network.

### Emitted JSON

```json
{"ok": true,
 "rolling": {"util": 42, "resets_ms": 1770000000000},
 "weekly":  {"util": 11, "resets_ms": 1770400000000},
 "monthly": {"util": 63, "resets_ms": 1772000000000},
 "fetched_ms": 1769990000000}
```

Or `{"error": "<kind>", "fetched_ms": …}`.

### How the curl reaches the helper

`contents/config/` declares a single `curlCommand` entry; `main.qml`'s
`saveCurl()` writes it through to `~/.config/opencode-usage/curl.txt` at mode
600 (`$OPENCODE_USAGE_CURL` overrides the read path, but the config dialog
always writes the default). The helper only ever reads the file, so
hand-editing still works and there is one code path.

- **The curl is base64'd before it touches the shell.** A DevTools curl is full
  of single quotes (plus `$`, `;`, `"`), so interpolating it into a command
  would break instantly. `Qt.btoa` output is `[A-Za-z0-9+/=]`, safe inside
  single quotes for any input. Verified byte-identical to Python's
  `base64.b64encode`, and round-tripped through `printf | base64 -d` back
  through `parse_curl`.
- **Consequence:** the base64 curl appears in the write's command line, so it
  is briefly visible in `ps`. Accepted deliberately — see the QML trap above
  for why the no-shell alternative doesn't work.
- The secret therefore lives in two plaintext places: the file, and Plasma's
  `plasma-org.kde.plasma.desktop-appletsrc`.
- The write uses its own `writer` DataSource with its own `saveSeq` counter,
  for the same reason `refresh()` has `fetchSeq` — connecting the same source
  name twice is a silent no-op. A failed write sets `errorMsg = "save"`.

## UI conventions

- Panel: concentric rings, outside-in **rolling / weekly / monthly**, ordered
  by how soon each window bites. How many are drawn depends on `d` (the ring
  diameter, roughly panel thickness minus `smallSpacing`):

  | `d` | rings | centre |
  |---|---|---|
  | `>= 40` | rolling, weekly, monthly | empty — reading moves to the tooltip |
  | `32..39` | rolling, weekly | rolling percentage |
  | `< 32` | rolling | rolling percentage |

- **The centre label still appears in triple mode when there is no data.** With
  nothing to draw, every ring is an empty track, so the centre is free — and
  the `!` / `…` is the only thing separating "not configured" from "everything
  at zero". `visible: !ring.triple || !root.rolling`. Dropping it
  unconditionally loses that signal exactly when it matters most.
- In triple mode nothing on the panel says which arc is which; the tooltip
  names all three. In dual mode the centre number is *always* rolling, which is
  what disambiguates the rings: red in the stack while the number reads green
  can only be weekly.
- The second ring is dropped when `d < 32` (`d` being the ring diameter,
  roughly panel thickness minus `smallSpacing`). Below that, strokes hit the
  2px floor and the centre no longer holds a two-digit percentage above
  `minimumPixelSize` — the ring would be present but unreadable, which is worse
  than absent. Dual mode also thins the stroke (`0.085d` vs `0.12d`) and the
  label (`0.26d` vs `0.32d`). The smaller dual-mode factor keeps the common
  two-digit case at full size under typical fonts, but this is font-dependent
  — a wider default like DejaVu Sans can engage the shrink path sooner than
  Noto Sans or Liberation Sans. What actually makes this safe either way is
  `width: ring.clearD`, which lets `fontSizeMode` shrink the label rather than
  overflow it.
- The third ring appears only at `d >= 40`, where the innermost radius is
  8.3px against a 3.4px stroke. Below that the panel keeps two rings and the
  percentage, which carries more than three smudged arcs. Geometry is swept in
  0.1px steps from d=8 to d=200 against four invariants: `thirdR > 0`, the
  monthly stroke not swallowing the centre, `clearD > 0`, and no stroke-edge
  overlap between adjacent rings.
- **This reverses the original spec**, which ruled out three concentric rings
  as illegible at panel size. That judgement assumed the centred percentage
  stayed; dropping it frees exactly the space that made three rings cramped.
- There is still no "worst of N" ring — it would mean something different
  moment to moment. Every ring is bound to one fixed window.
- Colouring is by **raw percentage**. The Claude widget's pace-based tinting
  needs a window length, and opencode's payload never states one; assuming
  5h/7d/30d would bake in a guess that's wrong for the whole early part of each
  window.
- Manual refresh: popup button, middle-click, and the contextual action all
  call `root.refresh()`. It appends `" # <seq>"` to the command so each run is
  a *distinct* DataSource source.
- Credential errors (`no-curl`, `bad-curl`, `http-401`, `http-403`) blank the
  figures; transient ones (`net`, `parse`) keep the last-known values and show
  a "showing last known figures" note. `parse` and auth errors are deliberately
  distinct: both are fixed by re-pasting, but conflating them hides the case
  where opencode changed its format and the scraper needs updating.
- `build.sh`'s zip excludes must be unanchored (`'*__pycache__*'`, not
  `'__pycache__/*'`) — zip matches them against the full archive path, and the
  helper's cache lives at `contents/code/__pycache__/`.

## Testing

44 tests, stdlib `unittest`. The split matters:

- `tests/fixtures/inline.txt` and `backref.txt` are **synthetic**, covering the
  two serialization shapes structurally. On their own they only prove the regex
  matches itself.
- `tests/fixtures/server-response.txt` is a **real captured response**. This is
  the test that proves the widget works, and "validated against a real capture"
  is a completion requirement, not a nice-to-have. `test_real_fixture.py` skips
  cleanly when it's absent.
- Before committing any new capture: scan for `Set-Cookie`, bearer tokens,
  emails, account/user IDs, billing identifiers — and read it by eye, since a
  grep only catches the obvious shapes.

## Deliberately not done

- **`OPENCODE_API_KEY` is not usable.** The Zen inference key is a different
  credential from the web console's session cookie; no usage endpoint is known
  to accept it.
- No per-model breakdown — the payload carries three aggregate windows and
  nothing finer.
- No store.kde.org publishing, and no Nix/home-manager packaging.

## Open question

How long the opencode session cookie survives is unknown. If it's hours rather
than weeks, the widget spends much of its life asking for a fresh curl, which
would change what this is worth. Answerable only by observation.
