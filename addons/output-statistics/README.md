# Latest completed output statistics

This optional layer consumes generic `lane_output` snapshots from other
installations in the same run. Each supplied producer output contributes a value
row with `observed_row_count` and `observed_by_kind` (`event`, `value`, `relation`).
These count the rows supplied in that output, not total world events or game
progress. Reading the same producer cursor again does not accumulate a total.

`input_complete` and coverage remain separate from the known row count. Partial
input still has a factual supplied-row count. Missing or unrecognized input
produces incomplete coverage and no count row; an explicitly supplied empty
output has zero observed rows. The package retains the producer's installation,
instance, run, configuration/package revisions and observation sequence, plus
upstream row IDs, clocks, actors, status, coverage, and evidence references. It
neither chooses a shared clock nor asserts causal connections: `clock` is null
and `related_ids` is empty. The complete input remains in the host's retained
output blob.

Use [the TOML example](../../docs/examples/lane-addons/output-statistics.toml),
adjusting the manifest path when placing it in another configuration directory.
There is no MSX, Browser, Keeper, or provider-specific branch in this package.

The image is declared separately as `masc-lane-output-statistics:0.1.0`. Build it
in CI with `docker build -f addons/output-statistics/Dockerfile -t
masc-lane-output-statistics:0.1.0 addons`. Declaring the image is not evidence that
it has been built, installed, or qualified in a running host.

Run real stdio package tests without a local OCaml or Docker build:

```sh
python3 -m unittest discover -s addons/tests -p 'test_output_statistics.py' -v
```

These tests exercise the package protocol and supplied fixture data. They do not
establish live source acquisition, Docker isolation, or Keeper behavior.
