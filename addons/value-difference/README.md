# Observed value changes

This package reads a selected numeric value and publishes its signed change
between two supplied observations. Its direction is `up`, `down` or `unchanged`,
determined by arithmetic without a threshold or model. This is a sampled change
and direction, not a long-term trend prediction, causal claim or event total.

Install the [DOS producer](../dos-world/install.toml),
[value difference](../../docs/examples/lane-addons/dos-value-difference.toml),
and [statistics consumer](../../docs/examples/lane-addons/dos-value-statistics.toml)
in the resolved configuration directory, adjusting each manifest path. All use
the same run. The metric selects the DOS `guest` output; statistics selects the
metric's public `difference` output. Images must be prepared separately. The
host, dispatcher, TUI and Dashboard need no package-specific changes.

`binding.field` selects one exact key in the supplied value row's `fields`;
`binding.unit` names its unit. Neither is inferred from a title, substring or
clock. Nested selectors, implicit unit conversion and string-to-number coercion
are not supported. Each configured source needs exactly one supplied value row.
Multiple sources have independent baselines and output Lanes. Boolean, null,
string and nonfinite values are unknown input. Integers keep exact subtraction;
floating-point operands retain their normal floating-point arithmetic.

The package validates source and producer cursors, instance, run, installation,
configuration/package revision, original row identity, and explicit coverage.
Additional producer coordinates, including named output selection, are retained.
Both original rows, actors, clocks, evidence, source coverage and producer status
appear under `fields.previous` and `fields.current`. The derived actor is null;
the existing host records this worker's own execution and package revision.

| State | Value and direction |
| --- | --- |
| `baseline` | `null`, `null`: one complete input is available; no difference is known. `input_complete=true` does not mean two samples exist. |
| `measured` | Current minus previous; positive/up, negative/down, zero/unchanged. A decrease is valid numeric change. |
| `unknown` | `null`, `null`: input is currently incomplete, its cursor is inconsistent, or its difference cannot be represented as a finite number. No new endpoint is accepted. |

Missing, malformed, ambiguous or nonnumeric data in a valid source envelope
returns incomplete coverage and no metric row; that source's baseline clears.
Removing a source also clears it. The next complete sample is a new baseline.
An entirely validated, identity-consistent incomplete sample instead preserves
the last complete endpoint while reporting unknown. Its cursor and immutable
payload are tracked separately, so a subsequent older complete cursor is still
rejected. Live source availability/detail and producer status can change while
the committed payload at the same cursor stays unchanged.

The next complete sample can measure a signed net change between the two
complete endpoints, without adopting an incomplete intermediate value. Its
`intervening_input_gap` flag and `last_input_gap` retain the latest incomplete
input's coordinates, coverage and evidence. This describes an acquisition
coverage gap between accepted reads, independent of the source's world clock.
`last_input_gap.acquired_at` preserves the wrapper acquisition time separately
from the original row's `observed_at`. This is not an exhaustive gap log or a
claim of complete interval coverage. Recovery at the same accepted endpoint
returns the original row unchanged; the gap remains pending for the next new
endpoint. It does not revise the old interval or invent zero.

Producer/selection or metric configuration changes start a new baseline.
A new sequence with a different subject, Lane, clock domain or upstream
source/incarnation set starts a new baseline too. This also detects a recorded
source epoch change when the row has no clock. Duplicate coverage source IDs
are ambiguous input. A changed row at the same producer cursor is inconsistent input,
even if only its subject or clock changed, and is `unknown`.

Repeated reads of the same completed cursor return the previous interval, not
a new accumulated total. A new cursor with the same value measures zero. The
host can coalesce outputs or observe a guest twice after one action: do not
assume an action implies exactly one producer sample or that the latest delta
must equal its effect. Read the two original values and cursors together.
Finite operands can overflow their difference; `difference_not_finite` clears
the baseline and publishes no numeric result instead of emitting infinity.

Baselines live only in worker memory. Restart/replacement starts a new pair;
historical host evidence is not read back into a cumulative statistic. Protocol
or binding errors rejected before a valid observation are not new samples.
Removing this package or its statistics consumer does not own, stop or restrict
the DOS machine, another package, Keeper tools or the Keeper's next action.

The bundled [Skill](skills/value-difference/SKILL.md) explains interpretation and
evidence selection. Reading it does not force a review or execute a helper.
The package's actual implementation is `server.py`, launched through the common
stdio protocol and the environment declared in `lane.toml`.

```sh
python3 -m unittest discover -s addons/tests -p 'test_value_difference.py' -v
```

These tests run actual stdio metric/statistics processes with controlled source
envelopes. They do not execute DOS, install containers, qualify a Dashboard/TUI,
or prove production behavior. The existing image workflow discovers this
package and its tests automatically. Actual frozen-host DOS→metric→statistics
qualification remains a separate execution with retained evidence.

The [OpenTelemetry metrics data model](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#gauge)
distinguishes sampled gauges from additive sums. That is a reference for the
semantic distinction here, not proof of this package's gap or reset policy.
