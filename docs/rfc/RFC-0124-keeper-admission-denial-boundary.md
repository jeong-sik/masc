---
rfc: "0124"
title: "Withdraw fleet resource admission denial"
status: Withdrawn
created: 2026-05-17
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0101"]
implementation_prs: []
---

# RFC-0124 — Withdraw fleet resource admission denial

FD, disk, and fleet-size measurements are operational observations, not
authority to suppress a Keeper launch or turn. Probe failure is reported
explicitly and cannot fail closed across unrelated Keeper lanes.

Objective failures at the actual resource operation remain explicit local
errors. This draft is historical only and defines no admission gate.
