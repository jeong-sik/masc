---
title: "Withdraw product-specific GitHub execution policy"
status: Withdrawn
created: 2026-07-06
updated: 2026-07-13
author: codex
supersedes: []
superseded_by: null
related: ["0309"]
implementation_prs: []
---

# Withdraw product-specific GitHub execution policy

The Keeper, Gate, Shell IR, and OAS boundaries must not contain GitHub-specific
repository, Discussion, credential, or command policy. GitHub is one Connector
or registered Tool implementation supplied through configuration.

Objective execution invariants such as typed input, `BasePath` containment,
sandbox confinement, and explicit remote errors remain at their owning
boundaries. Any configured semantic decision uses the ordinary Gate mode and
the configured LLM, without product-specific risk classes, command matching, or
privileged floors.

The previous GitHub command matrix and credential branches are historical and
must not be restored.
