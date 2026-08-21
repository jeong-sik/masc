---
description: Review section — the evidence items the task contract requires
category: verification
template_variables: [evidence_items]
---

<required_evidence>
The task contract requires support for every item listed below. Judge each item
independently. Inspectable proof is available, non-truncated `[artifact:]`
content — and, when a `<live_lookup>` block appears in this prompt, whatever you
open yourself with the tools it describes. A URL, host path, commit, board
reference, command claim, or narrative note is not proof on its own: it names
something rather than showing it. Reject if the required support is missing,
unavailable, truncated, a placeholder, or unsubstantiated.
{{evidence_items}}
</required_evidence>
