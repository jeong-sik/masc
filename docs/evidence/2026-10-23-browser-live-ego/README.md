# ego lite through the browser Add-on worker — 2026-10-23

[ego_probe.ml](ego_probe.ml) drove a real ego lite 0.6.0.16 (Chromium
154.0.8037.44) through the worker's ego connection, `Browser_addon_live_ego.run`.
Commands went through `Browser_addon_owner.dispatch`, the path a server issue
takes inside the worker. The server's HTTP routes and a Keeper turn were not
part of this run.

[probe.out](probe.out) is the whole output, with the commit the probe was built
from. A later restack of the stack changes that hash; the probe source here is
what ran.

## What the run shows

- The client registers as `ego_lite · ego_task_space · 0.6.0.16 · 154.0.8037.44`.
- A new task space lists one page, `p1` at `chrome://newtab/`, as tab 1.
- `open_tab` opens tab 2 in 0.40 s. Reads of tab 2 answer in 0.10–0.14 s: text,
  elements, scene, and a 115,536-byte base64 screenshot (0.21 s).
- A click is refused by the lane table before any script runs (0.00 s).
- `goto` moves tab 2 in 0.44 s. A load ego refuses (`net::ERR_UNSAFE_PORT`)
  answers `effectPhase: partial` with the URL the tab now shows.
- `p1` moves too: the first page is the agent's. A `javascript:` URL is refused
  before a run.
- `close_tab 2` closes in 0.16 s. A read of tab 2 afterwards is refused with
  `browser tab is no longer present`, without a run.
- Retirement answers with a receipt, no client is left, and ego lists no space
  with the probe's name.

## What it does not show

- Only public pages were opened, so this run used no login. ego lite's own
  guide says agents in a task space use the operator's logged-in sites; no
  logged-in page is recorded here.
- A stopped run, a result delivered after the server stopped waiting, and
  retirement during a command were checked with a fake `ego-browser` in
  `test/test_browser_addon_live_ego.ml`, not against a real ego.

## Running it again

The probe opens a task space named `masc ego evidence probe` in the operator's
ego lite, opens example.com, en.wikipedia.org and example.org pages there, and
ends the space when it finishes.

1. Copy `ego_probe.ml`, and `dune.probe` as `dune`, into a new directory inside
   the masc checkout (dune does not build directories whose names start with a
   dot).
2. `dune build ./<directory>/ego_probe.exe`
3. `./_build/default/<directory>/ego_probe.exe "$(command -v ego-browser)"`
