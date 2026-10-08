# PR40960 recovery and wire-bound response

Response to comments 4177180255 and 4177180259 on
`bccd31b2e30186dfdd6f0429db40ed03d72f6572`.

Both regressions failed before changing production: a still-obstructed recovery
entry prevented canonical repair; a structured retention receipt fit as an object
but exceeded the configured envelope after MCP JSON-string encoding.
The tests derive the wire boundary from an actual receipt rather than a fixed cap.

Recovery now selects an existing regular recovery file for strict digest/ownership
verification; when the canonical path is missing and recovery is not regular, it
reconstructs the canonical blob from the journal without replacing the obstruction.
Existing regular-file digest, symlink, hardlink and synchronization guards remain.
All error messages, including structured ones, are bounded as encoded strings.
Completed outcome evidence stays durable; no model call is repeated.

Focused commands from this worktree (OCaml switch 5.5.1):

```sh
scripts/dune-local.sh build test/test_lane_addon_worker.exe
DUNE_SOURCEROOT="$PWD" MASC_BASE_PATH='' ZAI_API_KEY='' TYPESAFEAI_API_KEY='' MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false MASC_KEEPER_DOCKER_PLAYGROUND=false _build/default/test/test_lane_addon_worker.exe
```

RED selected lifecycle cases 0,1: two failures. GREEN: all 28 cases passed in
8.460s, including existing cancellation, journal, filesystem-identity and wire
bounds. The Docker controller is the existing hermetic subprocess fixture, not
real container enforcement. No full suite, CI, live model or deployment claim.
`manifest.json` records current source and executable hashes plus exact log bytes.
