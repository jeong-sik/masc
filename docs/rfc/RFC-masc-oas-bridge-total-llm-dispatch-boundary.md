---
rfc: "masc-oas-bridge-total-llm-dispatch-boundary"
title: "Withdraw budget-and-slot authority from the MASC OAS bridge"
status: Withdrawn
created: 2026-07-17
updated: 2026-07-17
author: vincent
supersedes: []
superseded_by: "0000"
related: ["0159", "0206", "0338"]
implementation_prs: []
---

# Withdraw budget-and-slot authority from the MASC OAS bridge

## Decision

MASC may keep a small typed projection adapter over OAS. It will not turn that
adapter into a mandatory product-lane registry, a global dispatch singleton, or
an execution policy authority. The former `run_bounded`, lane slot, budget,
and bypass-lint proposal is retired.

## Boundary

- MASC owns Keeper/Task/Goal/Board/Gate/Connector/Fusion/Memory/Scheduler
  operations. OAS owns generic provider/model calls and finite Agent/Tool
  execution; OAS never imports MASC vocabulary.
- Product adapters pass immutable typed Runtime/model/request values into the
  ordinary OAS API. They do not expose raw transport callbacks as caller
  authority.
- Provider/account concurrency is declared explicitly and enforced once by OAS.
  MASC does not add lane/global cardinality caps.
- LLM judgment belongs to the configured model prompt boundary. A deterministic
  bridge may project facts and typed failures, but may not decide product
  semantics.
- A waiting external operation parks durably and wakes its exact Keeper owner.
  Independent work and peer Keepers remain runnable.
- Deadlines are explicit operation inputs. There is no implicit bridge timeout,
  turn budget, retry budget, idle cap, or compatibility fallback.
- OAS journal/events are causal observations. MASC dashboard projections do not
  become a second execution writer.

## Retired implementation shapes

- a closed `caller` hierarchy enumerating product subsystems in one bridge;
- mandatory `run_bounded ~budget_s ~admission` for every LLM call;
- `Skip_if_full`, fleet/lane slots, or a shared MASC admission pool;
- string/path lints as proof that all dispatch crossed a policy facade;
- dual direct/bounded paths or release-long compatibility flags;
- a single failed judge/adapter pausing a Keeper or the fleet.

## Surviving work

Deduplicate genuinely mechanical MASC-to-OAS projection where it simplifies the
public call site. Keep product operation state owner-local, use OAS typed
provider/runtime facts, and expose ordered progress/failure/terminal receipts.
RFC-0000 is the governing architecture.
