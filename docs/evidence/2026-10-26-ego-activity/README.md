# Live browser request visibility

The installed runtime originally published transient activity only for
`page.interact` and native workflows. Reads, snapshots and navigation were not
recorded. TUI page cadence also did not refresh the connection inventory. A
short request vanished after its result, leaving no caller attribution.

This source change tracks every admitted live verb, including optional tab and
space scope, and retains one last result per caller for the connection lifetime.
Queued requests withdrawn before dispatch settle as refused; dispatched requests
whose caller loses the result settle as unknown. The wire decoders reject
malformed activity fields. TUI inventory and page reads run independently and
activity updates preserve the original pending read and browser identity.

Executed checks:

- `python3 scripts/check-browser-native-lifetime-component.py --activity`:
  actual lane sources compiled, 15 routing/activity cases passed (run SJ53ETM7).
- `python3 scripts/check-browser-native-lifetime-component.py`:
  independent reviewer compiled actual lane sources and passed all 8 watched-work
  cases. The helper stubs only the unused upload-lease alias; it does not exercise
  uploads or the full host.
- OCaml parser checks passed for the changed TUI implementation and feature tests.
- `git diff --check` passed.

`test/test_tui_browser_lane.ml` adds behavioral checks for the pending read,
browser identity, draft and previous observations. They have not been executed
against the full TUI dependencies. No TUI wording or layout test was added.

Adversarial review found synchronous pre/post Ego overlay calls could delay the
actual command and its receipt past the existing reply window. Those calls were
removed before publication. Ego native read/wait visibility remains unfinished;
this layer changes the MASC activity observation only.

This is component and source evidence. Full host/TUI typing, installation,
actual Keeper execution, visible TUI and Ego UI verification remain unverified.
It does not complete `task-2702` or `goal-ego-native-full-20261026`.
