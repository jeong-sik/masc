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
split gives two half-length bars. A positive share below one cell uses one cell;
the count and percentage remain the exact readable context for that resolution.
Empty tracks are neutral, including failed=0. Large counts reserve their actual
digit width so the value does not overrun the pane.

Skill outcome counts cover the retained runs for the selected exact revision,
across Keepers. They are not lifetime coverage. Executor-duration means are a
separate chart and exclude deferred results; they do not measure model latency.
