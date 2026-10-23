# ego lite input through the browser Add-on worker — 2026-10-23

[input_probe.ml](input_probe.ml) drove a real ego lite 0.6.0.16 (Chromium
154.0.8037.44) through the worker's ego connection, `Browser_addon_live_ego.run`.
Commands went through `Browser_addon_owner.dispatch`, the path a server issue
takes inside the worker. The page was [fixture.html](fixture.html), served from
this folder on 127.0.0.1. Its own script writes each event it receives into the
page, and the probe reads that log back with `BrowserRead`.

[probe.out](probe.out) is the whole output, with the commit the probe was built
from. A later restack changes that hash; the probe source here is what ran.

## What the run shows

Every input below was answered with a receipt, and the page logged it.

| Input | Answer | Page log |
|---|---|---|
| `click #send` | 0.30 s | `click send 80,40 trusted=true` |
| `click_at` secondary at the `#ctx` box's centre | 0.17 s | `contextmenu ctx 261,41` |
| `double_click #dbl` | 0.28 s | `dblclick dbl trusted=true` |
| `hover #hov` | 0.97 s | `mouseenter hov trusted=true` |
| `fill #name` "héllo" | 0.12 s | the form value below |
| `click #name`, then `type_text` " world" | 0.95 s, 0.13 s | one trusted `keydown` per character |
| `press_key Enter` | 0.17 s | `keydown Enter trusted=true`, `submit name=héllo world` |
| `select_option #month 10` | 0.11 s | `change month=10` |
| `scroll_at` the `#pane` centre, 0,120 | 0.58 s | `scroll pane top=120` |
| `follow_link` the scene's link node | 0.12 s | a read afterwards is on `next.html` |

- The click landed at CSS pixel 80,40. The box `#send` spans 20–142 by
  20–62, so its centre is 81,41; the fraction is cut to a whole pixel. The
  right click landed at the point the probe gave, 261,41. Coordinates are
  viewport CSS pixels.
- Two inputs were refused before any input, with no event in the log:
  `click #missing` (`element_not_found`, from the pointer target script) and a
  `click_at` carrying a document id the page does not have
  (`observed_viewport_changed`, from the guard script).
- `drag` was refused by the lane table before it reached ego.
- After the run the tab closed, retirement answered with a receipt, no client
  was left, and ego listed no space with the probe's name.

## What ego itself answered while this layer was written

Run directly with `ego-browser nodejs`, not through the worker:

- `page.evaluate` sees the same `window` from one run to the next, so the
  scene runtime's document id survives between the run that observes a page
  and the run that acts on it.
- `page.keyboard.press` took `" "`, `"~"`, `"+"`, `"Shift++"`,
  `"Control++"` and `"Control+Shift+a"`, and refused `"é"`, `"ß"`, `"€"` and
  `"Control+é"` as `Unknown key`. `page.keyboard.type` typed `é€ß 한글 ok` into
  the text input as written. So this connection refuses `press_key` with a
  character past `~` before the run, and types any text.
- [keys_probe.js](keys_probe.js) pressed every name MASC sends: the eleven
  named keys (`Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, the four
  arrows, `Home`, `End`) and `Control`, `Meta`, `Alt` and `Shift` with a
  letter or a named key. ego took all of them, and the page logged each as a
  trusted `keydown` with the same key name ([keys_probe.out](keys_probe.out)).

## What it does not show

- Only the fixture page was used, so no logged-in site is recorded here.
- A stopped run, a result delivered after the server stopped waiting, and two
  runs sharing one window were checked with a fake `ego-browser` and a fake
  clock in `test/test_browser_addon_live_ego.ml` and
  `test/test_browser_ego_peer.ml`, not against a real ego.

## Running it again

The probe opens a task space named `masc ego input probe` in the operator's
ego lite, opens the fixture there, and ends the space when it finishes.

1. Serve this folder: `python3 -m http.server 18765 --bind 127.0.0.1 --directory <this folder>`.
2. Copy `input_probe.ml`, and `dune.probe` as `dune`, into a new directory
   inside the masc checkout (dune does not build directories whose names start
   with a dot).
3. `dune build ./<directory>/input_probe.exe`
4. `./_build/default/<directory>/input_probe.exe "$(command -v ego-browser)" http://127.0.0.1:18765`
