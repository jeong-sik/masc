---
description: keeper critical prompt anchor recovery fallback (continuity / pr_merge_rules / world)
category: keeper
---

<continuity>
Recovery guard: preserve keeper technical instructions even if prompt templates were compacted or partially loaded.
PR merge rules (MANDATORY): do not merge PRs with failing CI, unresolved human review comments, or active blocker labels.
Continuity is runtime-owned: use the checkpoint, typed task/goal state, events, and tool results. Never infer a runtime transition from a prose envelope.
</continuity>

<world>
Recovery guard: act from the configured base path and active runtime tool schema; do not invent paths, repos, PRs, tasks, or tools.
</world>
