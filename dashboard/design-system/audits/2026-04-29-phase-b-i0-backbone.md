# Phase B · I0 IDE Backbone — partial implementation note (2026-04-29)

The original plan ("Phase B — I0 IDE Backbone") proposed three
cross-cutting components from `cb-group-i.jsx`:

- I0-A · Branch selector (header bar + branch list)
- I0-B · Keeper multi-select (chip filter)
- I0-C · Operator nudge log + compose

This note records what was actually shippable in Phase F scope and what
is gated on backend work.

## I0-B Keeper Multi-Select — shipped

`dashboard/src/store.ts`:
- `selectedKeeperFilter: signal<Set<string>>` (empty = "all keepers")
- `toggleKeeperInFilter(name)` / `clearKeeperFilter()` /
  `setKeeperFilterToAll(allNames)` mutations

`dashboard/src/components/keeper-multi-select.ts`:
- `KeeperMultiSelect({ label?, hint? })` chip group consumed by any
  zone willing to honor `selectedKeeperFilter`.

First use-site: `KeeperTokenStats` (cross-keeper aggregate, originally
shipped in #11532). The token stats panel now filters by the cross-zone
selection — empty selection still means "all keepers" so the default
view is unchanged.

## I0-A Branch Selector — backend-blocked

Spec data shape (`cb-group-i.jsx:14-85`):
```
branches[]: { name, tag, status, ahead, behind, head, keepers[] }
```

Production:
- No `/api/v1/branches` endpoint
- No `git`-aware backend service exposed to the dashboard
- Closest reference: build artifacts know the branch via env vars at
  CI time, but there is no live "what branches exist on this repo"
  feed for the operator surface.

A backend endpoint that walks `git for-each-ref refs/heads` and joins
keeper assignments would be required. Not in Phase F scope.

## I0-C Operator Nudge Log + Compose — partial backend-blocked

Spec data shape (`cb-group-i.jsx:143-194`):
```
nudges[]: { id, at, channel, to[], body, ack }
```
Plus a compose form for new nudges with channel = hint / approve /
reject / redirect.

Production:
- **Compose path exists** — `callMcpTool('masc_broadcast', ...)` in
  `dashboard/src/api/actions.ts:24` can send broadcast/DM payloads.
- **Log path missing** — no `nudges.jsonl` API; broadcast events live
  in transport logs but aren't surfaced as a nudge log.

Could ship compose-only as a stub, but without the log half it would
not match spec intent. Defer until backend exposes a nudge log feed.

## Phase B status

| Component | Shipped | Reason |
|-----------|---------|--------|
| I0-B Keeper Multi-Select | ✅ this PR | data already in `keepers` signal |
| I0-A Branch Selector | ❌ deferred | no branches API |
| I0-C Nudge Log + Compose | ⏸ partial | compose works via `masc_broadcast`, log API absent |

Phase B is the last frontend-implementable Phase 2 zone (per the
remaining-zones audit #11557). With I0-B shipped here, the cross-zone
filter pattern is in place and any future zone can opt into the
`selectedKeeperFilter` signal without touching this PR.
