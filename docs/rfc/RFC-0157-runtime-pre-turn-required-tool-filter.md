---
rfc: "0157"
title: "Withdraw MASC pre-dispatch provider capability filtering"
status: Withdrawn
created: 2026-05-21
updated: 2026-07-13
author: agent-llm-a-opus
supersedes: []
superseded_by: null
related: ["0058"]
implementation_prs: []
---

# RFC-0157 — Withdraw MASC pre-dispatch provider capability filtering

The proposed filter inferred whether a provider could execute selected tool
names and rejected the call before OAS observed the real provider/model
behavior. It also fed a local denial into Keeper pause and routing policy. Both
are retired.

OAS owns provider/model call capability and returns an explicit result for the
actual attempt. MASC supplies the requested tool schemas unchanged, records the
result, and may continue with another configured runtime. It does not classify
tools, providers, or models into an authorization or eligibility hierarchy.

External effects are authorized only when their execution boundary is reached:
exact Always Allowed, LLM Auto Judge, then non-blocking HITL. Objective input,
path, and sandbox invariants remain independent of that judgment.

This document is historical only and provides no compatibility contract.
