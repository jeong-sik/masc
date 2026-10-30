---
rfc: "virtual-project-missions"
title: "Virtual-project missions: RW24-RW30 from planned rows to judged runs"
status: Draft
created: 2026-08-29
updated: 2026-08-29
author: vincent
supersedes: []
superseded_by: null
related: ["goal-verifier-gate (RFC-0387)", "verification-authority (RFC-0361)"]
---

# Virtual-project missions: RW24-RW30 from planned rows to judged runs

## 1. Problem

The operator's question on 2026-08-29 was direct: what does this system do
for a person's productivity in the real world, and how well does it carry a
virtual project end to end? The repository already contains the operator's
own answer in planning form — `scripts/progress/scenario-missions.json` maps
twelve product-scenario rows to missions, and eight of them are the
human-productivity rows:

| row | mission | state |
|---|---|---|
| PoC | RW20 | cataloged, NOT RUN |
| QA 100% coverage | RW22 | cataloged, NOT RUN |
| 동작 증명 팀 | RW23 | cataloged, NOT RUN |
| 연작 소설 | RW24 | **name only** |
| 정부 지침 반론 | RW25 | **name only** |
| 논문·개념 실측 | RW26 | **name only** |
| 새 연구주제 발견 | RW27 | **name only** |
| 과학·수학·CS 난제 | RW28 | **name only** |
| 웹 연구 | RW29 | **name only** |
| 기고문 작성 | RW30 | **name only** |

Everything the campaign has actually judged (r4 6/19 → r6 15/19 → r7 11/19)
lives in the collaboration-mechanics band RW01-RW18: keepers coordinating
with each other. That proves the machinery moves; it does not measure whether
the machinery produces anything a person would otherwise have had to make.
The renderer already marks the absent ids as `planned` instead of pretending
they run — this RFC is the plan for making them run.

## 2. What already exists (reuse, do not reinvent)

- **Mission catalog schema** (`masc.keeper_multi_collaboration_missions.v1`):
  `id / phase / name / actors / capabilities / user_story (Korean) /
  assertions / evidence`, validated by
  `keeper_multi_collaboration_acceptance.py --validate-catalog` (passes today,
  22 missions / 47 assertions).
- **Runner**: the same acceptance runner's `--preflight` / `--run
  --allow-mutation --expected-base-path` modes, receipt schema
  `masc.keeper_e0_campaign_receipt.v1` with binary SHA pinning.
- **Completion judgment**: Task completion already flows through
  `completion_authority_agent` (measured 46% rejection rate — a live gate,
  not a rubber stamp), and Goal completion through `Goal_phase.Verifying`
  plus the `goal_verifications.json` ledger (RFC-0387). Virtual-project
  missions assert against these, not against fresh bespoke judges.
- **Turn-level instrumentation**: canary corpus (30+ model/effort baselines,
  restart/failover injection, cross-family LLM judge), tool-call quality case
  schema (`success_checks` as JSONPath + typed comparators), denial-streak
  counter.

## 3. Decision (proposed)

### 3.1 Pilot two missions, chosen by judgeability

Author RW26 and RW29 first, because their completion criteria are the most
deterministic of the eight — the harness principle is that a mission whose
grading is itself a judgment call measures the judge, not the system.

- **RW26 논문·개념 실측** (`paper_claim_reproduction`): the mission input is
  one paper claim with a published constant (fixture-pinned, offline copy).
  Keepers must build the measurement, run it in the sandbox, and file the
  Goal with evidence. Completion assertion is mechanical: the reproduction
  script exists, its execution log is durable, and the measured value falls
  inside the fixture-declared tolerance band. Human-productivity claim being
  tested: "a person states a claim; the system returns a run I can read."
- **RW29 웹 연구** (`web_research_with_verifiable_sources`): the mission
  input is a research question whose gold facts are fixture-pinned. Output
  must be a Board-posted brief where every load-bearing claim carries a
  source reference; assertions check that cited sources exist in the durable
  fetch log (no invented URLs), that the gold facts are covered, and that
  the brief passed adversarial review by a second keeper (RW21 machinery).

Both reuse existing actors/capabilities vocabulary; neither adds a runner
mode. Each mission is one catalog entry plus one fixture directory plus its
assertion implementations in the acceptance runner.

### 3.2 Variance is part of the score

The campaign history oscillates (15/19 then 11/19 on the same catalog), and
memory records that single-run scores on this surface are sample noise. A
virtual-project row is therefore reported only as **k-of-3 runs completed**,
with the receipt schema's existing binary-SHA pinning; a one-run success is
recorded as evidence but never quoted as the row's state.

### 3.3 Deliberately out of scope

- RW24 (연작 소설), RW25 (반론), RW30 (기고문): grading is rubric-heavy;
  they follow once the pilot pair proves the fixture-and-assertions shape
  survives contact.
- Restoring a hosted/CI execution lane for the campaign (the
  `run-keeper-realworld-acceptance.sh` wrapper and its CI job are gone from
  the tree; #31546's review set the policy that blocking CI does not grow).
  Manual dispatch stays the execution path; an operator-run cadence is an
  operational decision, not a catalog one.
- Operations-flavored scenarios (CS triage, repo maintenance, monitoring)
  raised on 2026-08-29: real candidates, but they are **new rows**, not the
  completion of planned ones — proposed separately after the pilots, so the
  planned surface does not silently widen.

## 4. Costs and risks

- Fixture honesty is the hard part: RW26 needs an offline paper claim whose
  reproduction is genuinely runnable in the sandbox; RW29 needs a fetch log
  contract so "source exists" is checkable without live-web flakiness.
  A fixture that quietly requires the live web makes the mission judge the
  network, not the system.
- The acceptance runner is 3,869 lines; each mission adds assertion code to
  it. The pilot deliberately adds only mechanical assertions (file exists,
  log contains value in band, cited id present in fetch log) to keep that
  growth auditable.
- Rate limits distorted earlier rounds; k-of-3 reporting absorbs but does
  not eliminate that. Runs should record the lane/provider actually used
  (the receipt already pins runtimes per role).

## 5. Verification

- `--validate-catalog` stays green with the two new missions.
- Each pilot mission ships with one deliberately broken fixture variant
  (wrong constant / fabricated source) that the assertions must fail —
  the mission's own bug-model, so a green assertion is evidence, not vibes.
- First scored report: RW26 and RW29 each run 3 times on the pinned binary,
  reported as k-of-3 with receipts under `docs/evidence/`.
