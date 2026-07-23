---
rfc: "0022"
title: "Withdraw MASC attempt budgets and provider demotion"
status: Withdrawn
updated: 2026-07-13
---

# RFC-0022: Withdraw MASC attempt budgets and provider demotion

- Status: Withdrawn
- Withdrawn: 2026-07-13

TTFT, idle duration, token rate, and elapsed time remain OAS call observations.
MASC does not calculate trust scores, demote providers, consume a turn budget,
or pause a Keeper from those values. OAS returns the actual typed call result;
the Keeper may continue with configured fallback or other work.
