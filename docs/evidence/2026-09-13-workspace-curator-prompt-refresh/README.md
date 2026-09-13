# Workspace curator prompt refresh

HTTP prompt Set/Clear now persists first and notifies an existing curator only
for `workspace_memory_curator`. The HTTP response and Dashboard separately show
queued, no owner, or unavailable. None asserts model execution or completion.
No observer, timer, model default or extra synchronous provider call was added.

The native feature test now uses the actual persisted mutation helper for an
unchanged memory inventory: Set before owner startup, changed Set, invalid
variable rejection, failed Set/Clear writes, and successful Clear. Native
execution remains for CI. Six OCaml files parsed, 17 mounted component tests,
whole-project TypeScript checking and ESLint passed locally.

Browser evidence uses synthetic HTTP responses in the source component on a
Vite dev server. It clicks Set/Clear and verifies all three notification outcomes,
including mobile overflow and zero page errors. It does not run the native HTTP
handler, write runtime configuration, call a model or prove Keeper adoption.
Desktop and mobile PNGs were directly viewed. Initial missing Vite proxy setup
and mixed dependency-cache failure remain recorded. The successful run used a
fresh external cache directory with htm/preact dependencies preoptimized.

Runtime slot writes, preset batches and arbitrary file edits are outside this
change. An already running model retains its captured prompt. Pending work
uses the latest override and existing request-identity cache rules.
