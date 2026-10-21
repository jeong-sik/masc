# Reading measured charts

Charts should answer what changed, how large it is, and which observation
supports the value. A colour or an unlabelled shape is not enough.

## Research and decisions

| Source | Applied decision |
| --- | --- |
| [Government Analysis Function: charts](https://analysisfunction.civilservice.gov.uk/policy-store/data-visualisation-charts/) | Start magnitude bars at zero, label axes and units, keep text horizontal, and remove decoration that competes with values. |
| [W3C WAI: complex images](https://www.w3.org/WAI/tutorials/images/complex/) | Give charts a short description and make their essential values available as readable text or a table. |
| [Grafana: time series](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/time-series/) | Place observations by their timestamps; make missing-value connections an explicit choice rather than inventing continuous observations. |

These references guide presentation. MASC's producers and decoders determine
what was actually measured; a chart must not broaden their authority.

## TUI distributions

The filled length and percentage label use the same denominator: the sum of
the supplied nonnegative counts. Every row has a common 0–100% axis. A 50/50
split gives two half-length bars. Each percentage and cell share is rounded
down independently, so the displayed percentages can sum to less than 100%.
The calculation uses exact integers even when the total or scaled numerator
exceeds a machine integer. A positive share below one cell uses one cell;
the count and percentage remain the exact readable context for that resolution.
Empty tracks are neutral, including failed=0. Large counts reserve their actual
digit width so the value does not overrun the pane.

Skill outcome counts cover the retained runs for the selected exact revision,
across Keepers. They are not lifetime coverage. Executor-duration means are a
separate chart and exclude deferred results; they do not measure model latency.

## Retained Keeper time series

Turn latency, per-observation cost, token usage, prompt bytes and inference
telemetry use producer timestamps on the horizontal axis. A missing reading
breaks the line; an isolated observed reading remains a point. Irregular
observation intervals retain their actual elapsed spacing. No periodic sampling
cadence or missing intermediate observations are invented.

The vertical axis starts at zero and uses the actual largest positive observed
value, including sub-dollar costs. An all-zero series stays at zero. Each chart
states units, retained coverage, latest/minimum/maximum and its time range.
The expandable source table preserves every supplied numeric value and missing
reading; its rows are created on demand. Token input/output use solid/dashed
lines as well as colours, with one common magnitude scale.

Costs are an observed subtotal of this loaded window, with partial coverage
explicit. They are not lifetime spending. Token usage comes from the canonical
usage counters rather than hardware prompt/decode timing counters. The input to
output ratio uses only paired observations; zero output and unobserved output
are distinct, and no synthetic denominator or health threshold is introduced.

## Loading selected observations

The lightweight fleet execution snapshot does not include Keeper metrics series.
The status tab reads the selected Keeper's dated metrics store once, and offers an
explicit refresh. Leaving the tab aborts that read. It does not request full fleet
history or heavyweight Keeper status, and adds no polling loop.

The visible receipt states when it was read, the requested physical-row window,
rows examined, projected executions and skipped malformed or unsupported rows.
Heartbeat rows contribute to the scan count without becoming turn observations.
Read errors are distinct from a successfully read empty store. These charts describe
the loaded window; a completed refresh is not a claim of continuous live sampling.
