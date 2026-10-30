# Cross-Keeper historical channel audit

All runtime data was read-only. Findings are joined by exact turn_ref and content
hash, not inferred from a Keeper's current runtime. Search phrases only selected
review candidates; no such phrase becomes a production classifier.

- MiniMax: 14 selected rows reviewed in full. Seven contain public metacognitive
  narration; seven are ordinary reports/references. Six journals survive across
  the MiniMax/GLM set, including two with 548 separate thinking events in total.
- GLM: one search-selected row was an ordinary report. This limited sample is
  not proof of absence. The separate installed GLM stream test remains a single
  passing baseline, not historical regression coverage.
- DeepSeek: 13 selected rows investigated. taskmaster line 533 contains 227,832
  characters with one closing think tag and no opening tag; the identical body
  is retained as assistant Text in a checkpoint. Exact trace/turn cost joins
  identify deepseek-v4-flash:0731; the historical runtime ID remains unknown.
- Attribution correction: polisher line 2284, cited as GLM in #34896's original
  description, joins to DeepSeek flash in its exact turn record.
- Kimi: 789 September turn records matched Kimi runtime names, but only one
  surviving public assistant row joined in the inspected chat logs. It was an
  ordinary image description. No new Kimi request was made; rate-limit pause
  remains in force. This sparse public sample cannot certify Kimi.

The broader September scan read 34,469 turn records, but these counts are not
unique HTTP requests or a statistically sampled defect rate. The initial phrase
scan selected 95 rows, including normal replies. All selected historical raw
provider responses are unavailable. A stored typed event proves the post-parser
channel, not the provider's original HTTP field.

Confirmed distinct fault classes:
1. Agent Core source-level parsing/order/block-identity faults, addressed in
   #34905 fixture sources and awaiting behavioral/runtime acceptance.
2. Public text narration plus a separate explicit surface-post answer; retained
   journals establish the product symptom but not whether the provider authored
   narration as content or a parser moved it there.
3. Orphan-close malformed text carried into later model history. Native/inline
   parsing does not authorize invented recovery for unframed content.

Next causal evidence must capture one original provider response alongside its
parsed event sequence, public Gate output and final storage. Replaying historical
voice/GitHub effects is unnecessary. Support decisions must be version/runtime
specific. Missing evidence remains unknown, not a pass or a synthetic zero.
