---
rfc: "0164"
title: "Withdraw voice exceptions to provider capability filtering"
status: Withdrawn
created: 2026-05-23
updated: 2026-07-13
author: agent-llm-a-opus
supersedes: []
superseded_by: null
related: ["0157"]
implementation_prs: []
---

# RFC-0164 — Withdraw voice exceptions to provider capability filtering

The useful observation in this draft was that Voice is a normal tool/effect
boundary, not a special provider authorization class. The proposed repair,
however, preserved both a deleted tool-policy SSOT and the withdrawn RFC-0157
pre-dispatch filter by adding product-specific exceptions.

All registered tool descriptors are supplied to the Keeper model. Voice,
Image, Audio, Text, Connector, and other effects use their real handlers; any
external effect reaches the same generic Keeper Gate. OAS alone reports actual
provider/model modality and tool support. No Voice-specific compatibility
exception remains.

This document is historical only and defines no active behavior.
