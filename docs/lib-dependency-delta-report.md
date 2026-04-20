# Lib Dependency Delta Report

Use the dependency graph report to make extraction progress measurable before and after a PR.

## Regenerate The Graph

```sh
python3 scripts/analyze_lib_deps.py --json
```

This writes `reports/lib-dependency-graph.json`.

## Generate The Summary

```sh
python3 scripts/lib_dep_report.py \
  --graph reports/lib-dependency-graph.json \
  --output reports/lib-dependency-summary.md
```

The summary includes:

- SCC count and largest SCC size
- SCC count delta and added/removed SCC member sets when a baseline is provided
- Room/coordination dependent counts
- Top hub modules by dependent count
- Heaviest importers by dependency count
- Batch 2 extraction candidates from prefix clusters

## Compare Before And After

Save the previous graph, then pass it as a baseline:

```sh
cp reports/lib-dependency-graph.json reports/lib-dependency-graph.baseline.json
python3 scripts/analyze_lib_deps.py --json
python3 scripts/lib_dep_report.py \
  --graph reports/lib-dependency-graph.json \
  --baseline reports/lib-dependency-graph.baseline.json \
  --output reports/lib-dependency-summary.md
```

For automation, emit JSON:

```sh
python3 scripts/lib_dep_report.py \
  --graph reports/lib-dependency-graph.json \
  --baseline reports/lib-dependency-graph.baseline.json \
  --format json \
  --output reports/lib-dependency-summary.json
```

The JSON shape is stable enough for CI checks to read `scc_count_delta`,
`largest_scc_size`, `largest_scc_delta`, `scc_delta`,
`room_coordination_dependents`, and `batch2_candidate_delta`.
