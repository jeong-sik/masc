---
rfc: "0074"
title: "Sandbox Credential Auto-provision"
status: Retired
created: 2026-05-14
updated: 2026-06-02
author: vincent
supersedes: []
superseded_by: null
related: ["0005", "0006", "0070", "0073"]
implementation_prs: []
---

# Sandbox Credential Auto-provision

## 1. Retirement

Keeper execution no longer auto-provisions credentials from presets, tool
policy, repository identity, or sandbox mode. The deleted design attempted to
infer GitHub access from keeper policy. That inference is no longer part of the
system.

## 2. Replacement Contract

- Tool policy decides which tools are allowed.
- Keeper sandbox factories provide ordinary filesystem or shell containment.
- Repository access is controlled by keeper-repository mapping.
- Git authentication is ambient to the process environment and is not
  materialized by MASC.

This RFC remains only as the retired record of the deleted auto-provisioning
proposal.
