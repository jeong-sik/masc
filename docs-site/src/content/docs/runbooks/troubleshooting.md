---
title: Troubleshooting
description: Diagnosing and resolving common runtime issues in MASC.
---

## Port Conflicts (8935)

If port 8935 is already held by a previous instance:

```bash
lsof -i :8935
kill -9 <PID>
```

## Workspace State Recovery

If `.masc/` state exhibits anomalies:

```bash
scripts/verify-workspace-integrity.sh
```

## Model Rate Limits

MASC automatically fails over across registered alternative model providers without dropping the active Keeper task.
