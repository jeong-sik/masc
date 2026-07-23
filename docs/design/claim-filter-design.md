---
status: withdrawn
updated: 2026-07-13
---

# Withdrawn claim-filter design

Keeper profiles, Task kinds, repository kinds, prior release counts, actor
roles, and confidence labels do not grant or deny a claim. `claim_next` exposes
typed candidates to the configured LLM, then performs an exact id/version
claim. Existing work is never auto-released.
