# Repeated acknowledged input and session CPU

The comparison workflow accepts `input_cycles`, defaulting to one. Each cycle
contains ten transitions: roster arrows, wheel and page keys in both directions,
and detail keys and wheel in both directions. Every input requires a completed
frame with its distinct expected selection/window before the next input is sent.
This is repeated closed-loop interaction, not a fixed-rate overload test.

Each sample retains its cycle and the elapsed time from the preceding timed
acknowledgement to its input. The first sample of each roster/detail phase has
no preceding timed acknowledgement. This exposes observer preparation overhead;
navigation, draft entry and resize between the two phases are not a timed gap.

The scenario also records `RUSAGE_CHILDREN` user/system CPU after the helper
reaps its launcher. The launcher waits for the TUI. The numbers therefore cover
the whole launcher/TUI session and waited descendants, including startup,
navigation, draft entry and shutdown, and exclude observer CPU. Wall time covers
the whole helper call, including fixture setup/cleanup. Neither value is CPU or
wall time spent solely in the timed actions. No per-action CPU claim is made.
See [Python resource usage documentation](https://docs.python.org/3/library/resource.html#resource.RUSAGE_CHILDREN).

## Verification

- Eight Python receipt/fixture tests pass. They reject missing/duplicate/changed cycle
  samples, invalid latency or resource values, inconsistent CPU totals, missing
  gaps, nonfinite/negative gaps, and incorrect phase boundaries.
- An optional retained-Channels workload must report its matching loaded
  binding count, name-directory hash, rendered count and return to Info.
- Python syntax and `git diff --check` pass; no local OCaml build.
- A local existing binary, copied without a neighboring server executable,
  completed two cycles (20 transitions), draft verification, exit and termios
  restoration using only temporary fixtures. Its SHA-256 is
  `514de059bef299d9998c7453bef842318ec0acdcac37d7c334c0abdd59844e11`.
  `local-smoke.stdout.txt` retains the receipt: child CPU 0.131390 seconds and
  whole helper wall time 3.25878025 seconds. This verifies the harness; it is
  not a source-attributed optimization comparison or a production measurement.

The comparator retains every raw observation and CPU receipt and verifies the
same actions/cycles for both binaries. Same-runner repeated-input comparisons
remain necessary before attributing a CPU or latency change to a source edit.

## Failed first repeated comparison and setup correction

[Run 36042758515](https://github.com/jeong-sik/masc/actions/runs/36042758515)
on `829ab9e2933c0e01d8411b1dbc809d8d04e4b218` failed during the second
candidate's initial roster selection, before any of its timed inputs. The
retained terminal output says `MASC Keepers (not loaded)`; no second-candidate
timing/resource receipt was produced. This is an incomplete comparison, not a
600-transition pass. The cause of that old binary's startup loading is not
established by these logs.

The benchmark now requests a roster refresh once during setup for both binaries
and requires the resulting keeper row before timing. It measures navigation
against a loaded snapshot; it does not verify automatic startup loading. A
failure now emits its stage and any partial observations after fixture cleanup,
without a PASS marker or complete resource receipt. The local smoke receipt
above predates this setup adjustment and is not proof of the adjusted scenario.

## Source-pinned metadata and preflight

[Run 36233452828](https://github.com/jeong-sik/masc/actions/runs/36233452828)
on `91d1e037044b86cb3d3b548995d5199e85f5931e` failed before any timed input.
The screen had `MASC Keepers (0)` and no metadata, unlike the earlier
`not loaded` failure. The current shared fixture had removed `trace_history`
and `last_handoff_ts`. Both compared binaries require those fields and silently
exclude metadata that fails their current-schema parser. Refresh cannot repair
this fixture mismatch.

The optional `--keeper-metadata` argument (workflow input `keeper_metadata`)
now supplies an explicit alpha/beta JSON fixture for both binaries. It replaces
only benchmark metadata before launch. The default still uses the current
product fixture. `candidate2-and-3-metadata.json` is exactly the output of
`keeper_metadata` at `8e2224bde96ba4aeddb79bdbea79ff03482ee1e3` for both names;
use it only for this historical candidate2/candidate3 experiment. Their metadata
parsers have the same required fields. The shared product fixture is unchanged.

Before timing, the scenario selects beta and then alpha and requires each
completed selected-row frame. Receipts include both acknowledged names and
`metadata_sha256`, the SHA-256 of `json.dumps(metadata, sort_keys=True).encode()`.
This is a normalized JSON content hash, not the raw file hash. The comparator
retains the supplied JSON and requires identical preflight receipts in all runs.
The two setup selections affect the first timed input's cadence and whole-session
CPU. Do not pool these measurements with earlier runs using different setup.

An existing local binary with SHA-256 `514de059bef299d9998c7453bef842318ec0acdcac37d7c334c0abdd59844e11`
reproduced the empty roster with the default current fixture. With the explicit
snapshot it passed 20 transitions, draft verification, exit and terminal cleanup.
`pinned-fixture-smoke.stdout.txt` retains the success receipt. This is fixture
repair evidence; the binary's source is unverified and it proves no optimization.

## Draft return acknowledgement

[Run 36234498852](https://github.com/jeong-sik/masc/actions/runs/36234498852)
at `1f379b78e2ae6fe25310300ae7df0fdc9ddab8d9` passed preflight and all 100
transitions for baseline/candidate in each of the first two repetitions. The
third baseline completed 60 roster transitions, then failed in draft cleanup.
There is no complete third repetition or aggregate comparison. Artifact
`10903447626` retains the partial receipts; these 460 observations are not a
600-transition pass.

The failed completed screen is alpha's Detail/Info view. The `i` shortcut can
focus an inline composer or open chat, depending on which input owner claims
it. The scenario incorrectly assumed Escape always returned to the roster.
It now explicitly opens alpha detail, then its chat, before typing the draft.
Ctrl-U and Escape must produce the completed detail title before resize and
timed scrolling. This fixes the fixture's navigation assumption; no production
input routing is changed. The updated local two-cycle smoke passes and its
receipt is in `pinned-fixture-smoke.stdout.txt`. This additional setup belongs
to whole-session CPU and is not pooled with the earlier experiment.

## Retained hidden Channels workload

`--retained-channels N` and the corresponding workflow input load N synthetic
alpha bindings, one beta binding and N synthetic channel names. Server and
person name scopes return empty pages of their own kind; channel names follow
the requested page limit and cursor. The default is
zero and skips this setup. The profile visits Channels after the draft check,
requires the completed current screen to contain both `N here / N+1 total` and
the first resolved channel name, then acknowledges a return to Info. Detail
scroll timings start after this setup and resize; roster timings precede it.

Receipts retain the requested count, rendered count, returned tab and the
SHA-256 of the normalized connector/name payloads. The comparator requires the
requested profile and identical preflight receipts for every binary/repetition.
It still measures the same ten transitions per cycle. Whole-session CPU now
also includes the optional channel loading/rendering setup; it is not Info-only
CPU. Frame timing histograms likewise include setup frames and are not directly
matched to individual inputs. The fixture density is a controlled stress
parameter, not a claim about the live runtime's channel population.

An existing local binary with SHA-256
`7c9579ccdfb04b42a20d8df783bf5984ebd43d918c460a88dc942349d336d1ec`
passed N=250, two cycles, all 20 transitions and the draft check. Its source was
not attributed for this smoke run, so it proves fixture operation only. The
normalized channel fixture hash was
`a57996f8ba3a01b5357180200dbd61d7ec7433dbd799b07ec2609efe4e2b73a8`.
`retained-channels-smoke.stdout.txt` contains the complete receipt.

The controlled builds for #39279 share base
`5bb84d077c4adeb3e3c06df5511019c6b1184f40` and the same drained-input scheduler
from #39270. Baseline `d40a5b18e6c5db66340c34f8946c08724a4cb98a` is built by
[Release 36237833472](https://github.com/jeong-sik/masc/actions/runs/36237833472).
Candidate `9c244cd88c147811a8534ee7df4c0ffb160f5000` is built by
[Release 36237885748](https://github.com/jeong-sik/masc/actions/runs/36237885748).
Their bin/lib diff contains only the four deferred Keeper detail builders in
`bin/masc_tui_render.ml`; the additional diff is a changelog fragment. These
integration builds are not installed runtime binaries. Comparison results are
pending; the older 600-transition scheduler comparison is a separate experiment.
