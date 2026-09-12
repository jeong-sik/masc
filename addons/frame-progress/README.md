# MSX observed frame progress

This optional package adds a frame-difference value Lane to the existing MSX
observer. Install [msx-frames.toml](../../docs/examples/lane-addons/msx-frames.toml)
and [frame-progress.toml](../../docs/examples/lane-addons/frame-progress.toml)
in the resolved configuration directory, adjusting their manifest paths. Their
run IDs must match. The second declaration selects the first installation with
`kind = "lane_output"` and `selection = "latest_completed"`. No MSX-specific host
dispatcher, Dashboard component, manual attach, or additional machine is needed.

The package reads exactly one MSX capture per supplied completed output. It
requires the requested machine, `matches_binding = true`, the capture subject,
machine incarnation, integer frame and `msx/<machine>/<incarnation>/frame` clock
to agree. An arbitrary numeric field, DOS capture sequence, input count, score,
or elapsed wall time cannot substitute for the MSX frame. The MSX input cursor
may stay unchanged while frames advance; it is retained without controlling the
calculation. Multiple configured upstream sources have independent baselines.

Each value row has `unit = "frames"` and `scope = "between_supplied_msx_captures"`:

| State | Meaning |
|---|---|
| `baseline` | One complete sample is known; `value = null`. The reason identifies the first sample, producer change, machine incarnation change, or frame regression. |
| `measured` | `value` is current frame minus previous frame within the same producer and machine incarnation. Zero means those two frames were equal. |
| `unknown` | Incomplete input or inconsistent/reversed producer cursor; `value = null` and the baseline is cleared. |

Within a valid source envelope, missing, malformed, mismatched or ambiguous
capture data has incomplete coverage and no metric row. It clears that source's
baseline. A following complete sample
starts a new baseline; it never reports a zero to conceal the gap. Removing a
source from the input clears its baseline too. Different producer installation,
instance, run, configuration or package revision starts a fresh baseline. A
restore changes the machine incarnation and starts a fresh baseline even when
its frame number happens to match an earlier frame. Frame regression within
one incarnation is also a baseline discontinuity, never negative progress.

Malformed JSON-RPC, binding or top-level source envelopes are rejected by the
shared protocol before this calculation receives an observation. Those rejected
requests do not transition the baseline. Normal MASC source acquisition supplies
typed envelopes and represents acquisition failure as unavailable coverage;
that unavailable input reaches the calculation and clears its baseline.

Repeated reads of the same producer cursor and capture return the previously
computed interval. They do not move the baseline or accumulate a total. A later
producer sequence containing the same frame measures zero. Host scheduling may
coalesce outputs; this package measures the difference between the two supplied
frames, without claiming it observed every intermediate output, event or input.
Frame differences do not establish strategic progress, game turns, or causality.

Every measurement preserves both original capture rows, source cursors and
coverage, producer identity and revisions, producer status, upstream coverage,
and both retained output and screenshot references. `previous` is null only
when there is no prior valid sample. A calculation has `actor = null`; the
original actors remain on its input references. `related_ids` is empty because
these cross-package IDs are not package-local causal links. The generic host
still records this package's own revision and actual worker execution.

**Baseline storage is worker memory.** A worker/server restart, replacement or
detach loses the baseline. The first new complete sample reports `baseline`,
and the second can measure a new interval. This is a sampled difference gauge,
not a restart-continuous or cumulative statistic. Historical output and selected
evidence are retained by the existing host. The package does not search that
history or write changing state into TOML. A future cumulative/history-complete
statistic needs a durable cursor/state port and replayable input; the current
read-only worker contract supplies neither, so it must not claim that feature.

The package Skill explains how a Keeper can interpret and select these rows;
it does not require a new Keeper, mandatory review or game input. An unavailable
or faulty metric does not acquire the machine's input or lifecycle ownership.

The generic package-image CI discovers this Dockerfile with `addons/` as its
build context. Local verification uses the actual stdio protocol, including the
existing MSX observer, with explicit fixture captures:

```sh
python3 -m unittest discover -s addons/tests -p 'test_frame_progress.py' -v
```

These fixture tests prove protocol and calculation behavior. Real machine
capture, TOML installation, isolation, retained evidence and browser projection
require a separate running-host proof; passing these tests does not prove them.
