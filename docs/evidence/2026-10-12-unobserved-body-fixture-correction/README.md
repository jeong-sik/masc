# Observed response authority fixture correction

Independent review of #42554 at 3930bcd15a8aebc95bec06c66c6b2e4c6c89a009 returned SOURCE HOLD: two inherited expectations still granted authority to unobserved text scopes. The original artifact remains `/tmp/masc-tui-unobserved-body-metadata-independent-review-20261012/review.json`; this child does not retroactively approve that standalone head.

Corrected the stop/details expectations and two related owned-text expectations in `test/test_tui_model_content_activity.ml`:

- Unobserved text retains the observed owner, so a matching response stop ends its activity.
- Matching details may update counters, and a later observed scope may advance the response.
- Unobserved same-scope text retains the known generation.
- An unobserved later scope cannot block subsequent explicitly owned text, header or content events.

Body retention, stale generation rejection, stopped-owner rejection, terminal-state preservation and initial unowned response behavior remain covered by their existing state checks. No new wording/layout/row-order test was added. A further scan of `Unobserved_scope` uses in both model-content and transcript fixtures found these related expectation conflicts; this is a source audit, not an executed test-suite result.

The changed fixture passed syntax-only parsing; git diff --check passed. No fixture execution, full typecheck, build, CI, provider/runtime/installation/UI/screenshot or formal approval is established. Corrected composite review is required before claiming source acceptance.
