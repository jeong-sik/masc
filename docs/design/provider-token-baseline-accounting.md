# Partial token accounting

The baseline CLI reports token and byte counts as observations, not estimates.
Each metric contains:

- `known`: nonnegative integer observations, including reported zero.
- `missing`: absent or null values.
- `invalid`: present values outside the count type, including boolean, negative,
  fractional and string values.
- `known_sum`: sum of known observations, or null when none exist.
- `complete_sum`: sum only when at least one observation exists and every
  decoded observation in that group has a valid count. Otherwise null.

Median and maximum use known observations only. Neither sum establishes coverage
of failed provider attempts absent from the ledger, nor raw wire-field presence
when adapters have already normalized missing fields to zero. Raw observations
and settled deltas remain separate groups; they must not be added together.
Malformed or non-object JSON rows remain listed separately and are outside metric
groups. `source_decode_complete=false` marks their presence; even a numeric
`complete_sum` then covers only its decoded group, not the damaged source.

An empty ledger yields an empty usage list and null interval endpoints. A missing
ledger file remains a read error: absence of a file is not an empty measurement.

Verification: `python3 scripts/analysis/test_provider_token_baseline.py` exercises
partial/missing/invalid usage, measured zero and an empty day through the real CLI.
Four synthetic scenarios passed; this is reporting correctness, not live token
savings evidence. No model call or local Dune build was performed.
