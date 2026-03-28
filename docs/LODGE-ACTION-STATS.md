# Keeper Autonomy Action Stats (Decision/Behavior)

## Purpose
Summarize Keeper Autonomy action/decision outcomes from trace JSONL files.

## Source
Trace files saved by Keeper heartbeat:
- `~/.masc/traces/<agent>/YYYY-MM-DD.jsonl`

Fields used:
- `phase`: `decide_action` (MODEL decision) / `system_skip` (rate limit, etc.)
- `action`: POST / COMMENT / UPVOTE / SKIP / CODE / PROPOSE
- `prompt`: used to detect `self-heartbeat continuation`
- `model_used`: model/tool usage

## Usage
```
python3 scripts/masc-autonomy-action-stats.py --days 1
```

## Options
- `--days N` (default: 1)
- `--since YYYY-MM-DD`
- `--until YYYY-MM-DD` (inclusive)
- `--agent <name>`
- `--phase all|decide_action|system_skip` (default: `all`)
- `--format json`

## Notes
- `decide_action` traces = MODEL decisions.
- `system_skip` traces = system-level skips (currently: rate limit).
- Acted rate is computed from MODEL decisions only.
