# Common select interaction: actual browser DOM evidence

Captured 2026-10-23, from the `feat/browser-multi-select-20261023` worktree
based on `b4bd81124965c7829df08a3d8e36dec5027865a3`.
The exact extracted production JavaScript is identified in both receipts by
SHA-256 `05d7c7fe978b949f38ef46d31d87041080f85d89535c75bf6f90618ac22d178b`.
Related broad browser-parity goal: <https://github.com/jeong-sik/masc/issues/45556>.

## Execution and independent observation

`scripts/probe-browser-multi-select.mjs` extracts `Browser_interaction.script`
directly from the source and executes it against an owned loopback HTML fixture.
It separately reads `selectedOptions` and the fixture's input/change event log.
Both Firefox BiDi and ego passed the same 11 scenarios:

- Replace a multiple selection, returning actual DOM order.
- Reject a missing, disabled, disabled-optgroup, ambiguous or repeated requested
  value without changing any selection or dispatching events (five cases).
- Clear the whole multiple selection with `values: []`.
- Preserve single selection, including the empty string option (two cases).
- Report a partial effect when page handlers reselect an option or rewrite its
  value; preserve the application's changes (two cases).

Files: `firefox-proof.json`, `ego-proof.json`, `firefox-browser.json`.
Ego reuses goal-owned TaskSpace **54**, name `masc browser parity 20261023`,
page `p1`. The space remains open for the ongoing broader goal.

```sh
node scripts/probe-browser-multi-select.mjs firefox /Applications/Firefox.app/Contents/MacOS/firefox /tmp/masc-select-firefox
node scripts/probe-browser-multi-select.mjs ego /Users/dancer/.local/bin/ego-browser /tmp/masc-select-ego 54
node test/test_browser_interact_extension.mjs
```

Paths above describe the capture host; callers supply their own executables and
output directories. A new goal must use its own task space; continuing this goal
must reuse the existing one.

## Scope and remaining evidence

This proves actual Firefox and ego DOM execution of the extracted production
script. It does not exercise OCaml request decoding, the host/Add-on integration,
all browser backends, installed binaries, Keeper model tool selection, complete
user workflows or human-level performance. `elapsed_ms` includes probe calls and
the independent DOM read; it is not a Keeper latency benchmark. Selection uses
DOM mutation and synthetic input/change events, not trusted pointer input.

The extension dispatcher suite passed, including shared-script equality and
pre-effect versus partial/unknown-effect boundaries. Six changed OCaml files
passed parser-only checks; tool TOML parsed and `git diff --check` passed.
OCaml type checking, build, CI, installed runtime and end-to-end Keeper QA were
not performed for this capture. No local Dune build was run.

The initial ego probe used a synchronous child process and blocked its own HTTP
fixture server; that harness failure supplied no product evidence. The final
runner uses asynchronous spawn. Independent source review also corrected a
single-select reread that targeted the multiple-select element and cleanup of a
signal-terminated/unspawned Firefox child before these receipts were retained.
