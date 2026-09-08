---
name: frontend-verify
description: Verify an implemented web UI change in Firefox or Zen using Browser Lane evidence. Use for before/after comparison, responsive or state regressions, and checking that a frontend change actually works.
---

# Verify what changed

Derive success conditions from the requested user action and the implementation.
Retain browser lane/client/tab, URL, viewport, state and source revision with each
observation. Capture before and after under matching conditions where comparison
matters. A mounted DOM node alone does not prove that new code has loaded; use the
observed source hash or another explicit behavior change.

Use scene text/geometry to locate targets and screenshots to assess the painted
result. After navigation, replacement or reload, reacquire references. Verify
click/fill outcomes by reading the result; issuing an action is not outcome proof.
For forms, treat text entry and submission as separate actions.

Choose relevant widths and states: normal/loading/empty/error/long text/keyboard
focus. Report measured clipping, overlap and behavior failures separately from
visual preferences. Automated accessibility results do not establish complete
accessibility. Image similarity alone does not establish usability.

Record source changes, observed result, failures and untested conditions. Label
scripted fixtures as scripted and autonomous Keeper trials as autonomous. For a
workflow improvement claim, compare matched tasks and model/settings with and
without the change; do not turn the proposed target into an achieved result.
