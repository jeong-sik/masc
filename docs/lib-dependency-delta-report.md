# Lib Dependency Delta Report

Use the dependency graph report to make extraction progress measurable before and after a PR.

## Regenerate The Graph

```sh
python3 scripts/analyze_lib_deps.py --json
```

This writes `reports/lib-dependency-graph.json`.

CI uses the same analyzer and summary generator through:

```sh
bash scripts/lib_dep_delta_ci.sh
```

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

## CI Report

The `Lib Dependency Delta` CI job runs automatically when PRs touch `lib/`,
the dependency-report scripts, or core build metadata. It writes the Markdown
summary to the GitHub Actions step summary and uploads:

- `reports/lib-dependency-graph.json`
- `reports/lib-dependency-graph.baseline.json`
- `reports/lib-dependency-summary.md`
- `reports/lib-dependency-summary.json`

On pull requests, the baseline graph is generated from the base branch so SCC
count, largest SCC size, room/coordination dependents, and extraction candidate
deltas are visible without a manual local compare.
