---
description: Calibration few-shot block template
category: evaluation
operator_surface: fragment
template_variables: [examples]
---
These historical examples illustrate verdicts, not evidence for the current submission.
Apply the current task contract to evidence available in this run; do not infer a
verdict from similarity of wording or reuse an example's claimed observations.

{{examples}}

### example (vars: index, task_title, notes_excerpt, correct_verdict)
Example {{index}}:
  Task: {{task_title}}
  Notes: {{notes_excerpt}}
  Correct verdict: {{correct_verdict}}

### rejected_label
REJECT: evaluator incorrectly approved
