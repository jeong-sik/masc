---
description: Calibration few-shot block template
category: evaluation
operator_surface: primary
template_variables: [examples]
---
Here are examples of correct verdicts for calibration:

{{examples}}

### example (vars: index, task_title, notes_excerpt, correct_verdict)
Example {{index}}:
  Task: {{task_title}}
  Notes: {{notes_excerpt}}
  Correct verdict: {{correct_verdict}}

### rejected_label
REJECT: evaluator incorrectly approved
