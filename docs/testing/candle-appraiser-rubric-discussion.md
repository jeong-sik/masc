# Candle Grade rubric discussion

Status: assistant proposal, not a human reference grade or an adopted acceptance
rule. The separate 20-Goal proposal remains available; completing that sheet is
not requested here. RFC human calibration remains unmet.

## One boundary to decide

The current Grade prompt calls `small` one bounded change and `medium` a complete
feature with several connected parts. A bounded new feature can fit both
descriptions. The isolated evaluation includes these two descriptions of the
same outcome, with identical metric and target:

- Short: “Add CSV export for the filtered expense report”.
- Expanded: “Implement a CSV export capability for the expense report so that
  the exported rows are exactly those selected by the existing filters”.
- Metric: “CSV export acceptance tests passing”; target: `24`.

Neither description adds a new independent capability. In the completed GLM
baseline, the short description returned `small` 16 times and `medium` 4 times;
the expanded description returned `medium` 19 times and `small` once. A grade
change can change the total payment when the configured grade amounts differ;
this evaluation does not assign monetary amounts.

## Assistant-proposed scope rubric

| Grade | Proposed meaning |
|---|---|
| `trivial` | A local presentation or wording adjustment with the same supported behavior. |
| `small` | A bounded correction or a single bounded capability, whether existing or new. |
| `medium` | Several connected, explicitly promised outcomes within a feature. |
| `large` | Substantial coordinated work across existing feature boundaries or multiple capabilities. |
| `epic` | A broad product or system outcome containing several feature families. |

Under this proposal, both CSV descriptions would be `small`: each explicitly
promises the same bounded export capability. That is the assistant's proposed
interpretation, not a human label. The useful operator decision is whether this
single-capability versus coordinated-outcomes distinction expresses the intended
Grade scale.

For any chosen rubric, equivalent short and expanded descriptions should receive
the same grade. Additional words, stronger verbs, restated implied behavior,
asserted importance and requested grades do not add scope. Use the outcome
explicitly promised by the title, metric and target. Do not invent unmentioned
features or use Task count, priority, provider cost or test count as a scope
shortcut. Do not expand a stated outcome into assumed engineering
subtasks and then use those imagined parts to raise its grade.

## What that decision would establish

A decision on this boundary would guide a prompt revision and a new separately
frozen comparison run. It would not turn the existing synthetic measurements
into human calibration, approve the RFC's numerical thresholds, or establish
accuracy on the remaining Goal scope boundaries.

The original 240-call baseline, prompts and input hashes remain unchanged.

The same measurements also show contribution-weight variance under ordering,
renaming and Task splitting. A Grade prompt change cannot establish fair
allocation or resolve those observations. The complete measurements and limits
are in [the baseline evidence](../evidence/2026-09-30-candle-appraiser/README.md).
