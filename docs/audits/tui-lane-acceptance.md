# TUI Lane operational acceptance

Target: at least 95% of the twenty operator journeys below, with every critical
journey passing on the same delivered native candidate. This is an acceptance
ratio, not an estimate of code completeness. A skipped, fixture-only real-work,
or unexecuted journey does not count as passed. All failures remain visible.

The user has prioritized TUI over Dashboard. Existing Dashboard work is retained;
new work closes the terminal journeys first.

| ID | Operator journey | Critical | Required evidence |
| --- | --- | --- | --- |
| T01 | Open Lanes, enter Add-ons, return without losing context | yes | Native PTY keys and frames |
| T02 | Switch Timeline, Connections, Installations, Instances, Rows | yes | Native PTY keys and frames |
| T03 | Compare multiple lanes and select simultaneous events individually | yes | Exact selected row IDs |
| T04 | Keep selected lane/event visible after narrow/wide resize | yes | Frames at 64 and 140 columns |
| T05 | Read dates, original source clocks, Unicode names and long identities | no | Frames and original fixture coordinates |
| T06 | Open a package path and inspect actual package/image status | yes | Native UI plus returned preview |
| T07 | Fill required/optional binding fields, including object arrays | yes | Native UI and exact submitted binding |
| T08 | Review then save an installation; distinguish draft, saved and applied | yes | Exact declaration request and applied revision |
| T09 | Edit existing config; resolve a concurrent change without losing draft | yes | Native PTY, conflict and saved bytes |
| T10 | Observe the selected worker and inspect its result/coverage | yes | Exact request target and result |
| T11 | Fill a parameterized action, review, submit once and read receipt | yes | Request ID/input and result receipt |
| T12 | Cancel forms and survive late responses without reverting selection | yes | Controlled delayed responses and frames |
| T13 | Select Keeper/output, add/remove subscription with explicit review | yes | Exact configuration revision and subscription |
| T14 | Show subscription position without acknowledging on Keeper's behalf | yes | UI state and absence of read/ack mutations |
| T15 | Select original evidence and preserve it under its actual producer | yes | Exact worker and row IDs; reject mixed owners |
| T16 | Distinguish empty/failed/stale/partial data and retry the correct worker | yes | Failure response, retained frame, retry target |
| T17 | Inspect recorded connections and outside-view relationships honestly | yes | Source identities and relationship IDs |
| T18 | Detach the selected worker while retaining original evidence | yes | Target, detached state and retained rows |
| T19 | Refresh/chat details without losing selection, draft or flickering frame | yes | Native PTY frame sequence |
| T20 | Use an external Lane result in a real Keeper project decision | yes | Deployed identities, source, read and decision evidence |

Native fixture tests prove interaction and target identity; they do not prove
worker execution or Keeper consumption. T20 requires the actual isolated project
workspace. Passing tests on a source revision does not imply that the user's
launcher runs that revision. Record both identities before marking this complete.

## Inspection on 2026-09-14

Candidate `fc77be4852` improves the five-pane timeline but omits the guided
installer, schema action form and subscription panel present in the earlier
integration. It also falls back to the first worker for unresolved action
selection. These are critical open failures, so this candidate does not meet the
95% acceptance threshold. No completion percentage has been asserted.

The `feat/tui-lane-operability` follow-up restores these flows without changing
the five-pane navigation. Current results belong in CI artifacts and local
runtime proof, not in unchecked claims in this document.
