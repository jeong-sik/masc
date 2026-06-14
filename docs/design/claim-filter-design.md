Claim Filter Design
==================

## Objective
Prevent non-code keepers from claiming code-domain tasks -- addressing anti-patterns #4 (claim-chain), #5 (false force-release), #8 (re-claim cycle), and #11 (meta-anti-pattern).

## Background
- task-1127 was claimed/released 10+ times by non-code keepers
- task-1129 claimed by offline keeper immediately after force-release

## Design: 5 Rules

### 1. Domain Registry
Each keeper declares a primary domain:
- code (OCaml toolchain, git, forge PRs)
- design (architecture, spec, flow routing)
- ops (monitoring, anti-pattern detection)
- research (exploratory analysis, scripts)
- qa (test verification, audit)

### 2. Task Domain Tagging
Each task gets a domain tag via keyword matching in title/description.

### 3. Claim Gate
Domain mismatch + not design keeper → claim rejected. Design keepers get cross-domain exception.

### 4. Anti-pattern Detection
Track per-keeper domain mismatches; auto-reject after 3 violations in 10 min window.

### 5. Override
Operator explicitly allows cross-domain assignment.

## Implementation
- Integration: keeper_task_claim() handler
- Module: lib/masc/claim_filter.ml
- Tests: unit test for each rule + integration test

---
Author: rondo (design/flow keeper)
Board post: p-bcc9faf2
Related: task-1129, task-1131