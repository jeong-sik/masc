# RFC-0237 caller context

Companion evidence for RFC-0237 (write_meta ~force escape-hatch removal). Records
the call-site survey and the merge-strategy reasoning so a reviewer can verify the
classification without re-deriving it.

## Survey command

```
rg -n -U 'write_meta[^)]*?~force:true' lib/ --type ml
```

Result (exactly four; no `~force:false` explicit callers):

- `lib/keeper/keeper_tool_surface.ml:645`
- `lib/keeper/keeper_tool_surface_ops.ml:136`
- `lib/keeper/keeper_heartbeat_loop_presence.ml:82`
- `lib/keeper/keeper_keepalive.ml:311`

## Per-site read

1. `keeper_tool_surface.ml:645` — operator clear. Sets `continuity_summary=""`,
   `paused`, `runtime.last_continuity_update_ts=0.0`. No counter edit.
2. `keeper_tool_surface_ops.ml:136` — identity reseed on `agent_name` mismatch.
   Sets `agent_name`, `runtime.trace_id`, `trace_history`, `generation`.
3. `keeper_keepalive.ml:311` — `bootstrap_live_keeper_meta`. Sets
   `runtime.usage.last_turn_ts=bootstrap_ts`; optional identity repair. Server
   bootstrap, effectively single-writer.
4. `keeper_heartbeat_loop_presence.ml:82` — keepalive identity drift repair. Same
   identity fields as site 2, but on the heartbeat loop (concurrent with turns).

## Merge choice

`Keeper_meta_merge.monotonic_usage_counters` (`lib/keeper/keeper_meta_merge.ml:13`)
= caller base + `max(caller, latest)` on the five cumulative counters. Preserves
each site's continuity/identity edits while keeping counters monotonic. Correct
for all four.

## Force removal blast radius

`write_meta_with_merge` calls `write_meta config caller` with no force
(`keeper_meta_store.ml:339`). Initial write handled by CAS `Ok None`
(`keeper_meta_store.ml:311`). After converting the four sites, removing `?force`
breaks nothing else — verified by compiler.
