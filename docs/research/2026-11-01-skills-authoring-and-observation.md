# Skills authoring, composition and observation

The requested outcome spans Skill creation and composition, retained execution
evidence and statistics, and the TUI and Dashboard experiences. This document
preserves that full scope. A statistics patch alone does not complete it.

Baseline inspected: `6182e8a5dc822c3ccdd9b8bdda89665d27d0536e`.
Official sources below were read on 2026-11-01, approximately 01:49 UTC.
Source confidence is High for the documented behavior; the proposed MASC
applications are design conclusions, not evidence that they already work.

## Prior art and applications

| System and primary source | Useful design | Apply to MASC |
| --- | --- | --- |
| [Agent Skills specification](https://agentskills.io/specification) | Metadata supports discovery, the body describes the procedure, and optional resources load on demand. Frontmatter and directory identity have explicit validation rules. | Preserve the existing parser and package identity. Creation should expose purpose, instructions and resources clearly, with parser-backed preview before publication. Keep discovery size distinct from activated body size. |
| [n8n execution views](https://docs.n8n.io/build/understand-workflows/understand-executions/view-all-executions.md) | Executions can be filtered by workflow, outcome and time. The original execution and a revised workflow are distinct choices. Retried operations can still repeat external effects. | Show exact immutable Skill revision and original run identity. Add useful execution filters and input/output inspection. Never turn an observation into an automatic retry or infer that a completed tool means the user's objective was verified. |
| [Temporal Web UI](https://docs.temporal.io/web-ui) | Definition and execution are separate. Execution history, parent/child relationships, pending work and results are inspectable together. Raw history remains available. | Reuse MASC's existing named-run, nested composition and executor settlement identities. Present parent and child work and failure reasons without requiring operators to reconstruct them from raw JSON. Do not build another executor. |
| [Langfuse metrics](https://langfuse.com/docs/metrics/overview), [dashboards](https://langfuse.com/docs/metrics/features/custom-dashboards), [metrics API](https://langfuse.com/docs/metrics/features/metrics-api) | Observations feed metrics with explicit dimensions, including releases and versions. Quality, volume and latency are different measurements. | Calculate from authoritative retained observations, with exact revision, population, sample counts and coverage. Preserve unavailable evidence and provenance. Executor outcome is distinct from verified business success. |
| [OpenTelemetry metrics data model](https://opentelemetry.io/docs/specs/otel/metrics/data-model/) | Metric meaning includes identity, unit, population, time interval and aggregation semantics. A mean alone does not describe a duration population. | Label milliseconds and measured stages; show duration distributions, sample sizes and timestamp meaning. MASC already retains the individual results, so exact sample percentiles can be computed without another persisted aggregate authority. This is not a claim of OTLP histogram export. |

## Verified baseline gaps

- Composition evidence scans a reference's retained runs, but coverage reports
  only whether a latest record exists (0/1). The scope says `latest_completed`
  even when the latest disposition is failed or deferred. Both clients enforce
  the misleading contract.
- The obsolete pre-append single-file reader can make valid current run
  partitions unavailable when that old file is malformed. No current writer
  produces that layout.
- Catalog usage omits retained asynchronous deliveries/actions. The canonical
  activation summary already counts them.
- Both interfaces can hide a top-level failed result's message when its data
  is null, including failures after node execution during result publication.
- Dashboard Create publishes a fixed `keeper_lane_status` example, then sends
  the user to raw editing. TUI creation uses an external editor and chooses the
  first writable source. These are substantial remaining authoring gaps.
- Producer publication gaps are recorded separately from the exact-reference
  retained evidence reader. A retained-only result cannot prove complete
  execution coverage.

Source entrypoints: `lib/keeper/keeper_skill_composition_evidence.ml`,
`lib/server/server_skill_evidence.ml`,
`lib/server/server_routes_http_routes_activity.ml`,
`lib/keeper/keeper_skill_activation_summary.ml`,
`lib/keeper/keeper_tool_composition_surface.ml`,
`dashboard/src/components/skills-panel.ts`,
`lib/tui_decode_skill_evidence.ml`, `bin/masc_tui_render_tools.ml`,
`bin/masc_tui.ml`. Baseline findings were independently counter-read before
the first implementation unit.

## Completion requirements and proof

| Requirement | Required evidence | Current state |
| --- | --- | --- |
| Explain applicable prior art and concrete adaptations | Official-source comparison linked to actual changes | Comparison above; adaptations described below and in the stacked PRs |
| Create instruction Skills and compositions through clear, validated flows | Real create/preview/publish/readback with source choice, diagnostics and publication outcomes | Guided Dashboard and TUI candidates implemented; server preview/create/publish checks passed; missing-source discovery repair and actual screen proof pending |
| Compose existing capabilities with explicit inputs, dependencies and outputs | Parser/executor-backed preparation and execution; inspectable flow and resulting records | Guided canonical-plan authoring and parser-backed preview implemented; focused server checks passed; candidate screen proof pending |
| Count original runs and asynchronous use honestly | Producer-to-store-to-read-model tests, exact revision and coverage consistency | Candidates #47036/#47041: focused retained-run and async usage checks passed; installed/runtime proof pending |
| Make statistics interpretable | Sample sizes, populations, units, recorded-time bounds, empty/unavailable distinction, duration distributions | First candidate implemented and tested; rendered/runtime proof pending |
| Explain actual failures and nested execution | Failure reasons, parent/child/node identities and outcomes visible in both clients | Top-level failure/effect and node evidence visible; exact-run history and parent/request identities implemented; final OCaml and screen proof pending |
| Remove obsolete UI and compatibility paths | Call-site inventory and replacement behavior; no parallel authorities | Obsolete single-file evidence reader, fixed executable starter and silent first-source choice removed; v9 has no prior-version reader |
| Verify TUI and Dashboard behavior | Candidate source checks, focused behavioral tests, actual rendered captures and runtime observations with provenance | Incomplete |
| Deliver independently reviewed changes | Current-head review, checks, PR integration; installed/runtime evidence separately | Incomplete |

## First implementation unit

Replace the misleading coverage contract with fresh `masc.skill-evidence/v8`:
`exact_reference_retained_runs` and `composition_runs_observed`. Deduplicate
original run IDs before calculating counts, recorded-result timestamp bounds,
and completed/failed duration distributions. Deferred results remain separate.
P50 and P95 use the nearest-rank method on each outcome's samples. Missing
measurements stay null; observed zero durations stay zero. Do not claim that
recorded-result bounds are execution start/end bounds or complete history.

Replace the mean-only comparison in both clients with sample counts, mean,
P50/P95 and min/max. Preserve `coverage_complete=false`. Remove the obsolete
single-file candidate reader without deleting runtime files or inventing a
migration. No statistics, ledger facts or UI diagnostics become execution gates.

The remaining requirements above continue after this unit; their completion
must be established independently rather than inferred from a passing test.

## Discovery and first-package creation

Writable source discovery now includes declared read-write roots that are
missing. Enumeration remains read-only; the existing create authority validates
the candidate before initializing the root. Read-only, non-directory, unavailable
and unresolved roots remain excluded. This makes the existing first-package
writer reachable from either interface without exposing host paths.

Dashboard filters combine source identity, parser-derived kind and text in the
name, description or source. Counts describe matching versus all published
Skills, and zero matches differs from an empty snapshot. Filtering hides an
expanded editor while retaining its exact-reference owner and unsaved bytes;
clearing the filter restores that draft without a write.

## Retained execution history

Fresh `masc.skill-evidence/v9` adds payload-free run metadata and an explicit
latest-retained or exact-original-ID selection. The owner reads and deduplicates
one exact-reference partition, orders it by recorded-result time and original
ID, and derives history, selected detail and all-retained statistics together.
The outcome projection reuses `Tool_result.disposition`. There is no additional
store, executor, retry or admission gate.

An unknown ID, including an ID stored under another revision, has no selected
body. It never substitutes the latest result and does not erase other retained
runs or their statistics. Unavailable storage remains different from an empty
successful read. Each run's latest retained result can replace an earlier
deferred result; this view does not promise every transition.

Dashboard filters run metadata by outcome, Keeper and original ID. Selection
exposes the chosen result, node inputs/outputs and parent/request identity;
filters do not change the statistics population. TUI moves between original
runs with `[`/`]` and returns to latest with Enter. Both bind replies to the
requested reference and selector. Dashboard generations reject late replies;
TUI's existing request owner does so and continuous navigation follows its
pending target rather than stale displayed detail. Latest independent Skill
activation remains separately labelled from the selected composition run.
