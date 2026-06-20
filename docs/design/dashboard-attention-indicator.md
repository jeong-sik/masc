# Dashboard AttentionIndicator (keeper-v2 top-bar attention center)

Status: implemented (PR — Unit 3 of the keeper-v2 dashboard port)
Date: 2026-06-20
Scope: `dashboard/src/components/attention-indicator.ts` + top-bar wiring (`app.ts`, `dashboard-shell.ts`, `styles/app-shell-v2.css`)
Design source: keeper-v2 `shell.jsx` → `AttentionIndicator` / `TopBar`
Related: `docs/design/dashboard-pill-convergence.md` (Unit 0), keeper-v2 gap analysis (2026-06-20)

## What

The keeper-v2 design replaces the dashboard's flat `Attention N → overview` badge with a
**categorized attention center**: a `⚑ 주의 N` chip that opens a dropdown listing the non-empty
attention categories — each navigating to the surface where the operator can act on it — and a
`✓ 정상` zero-state. This ports that component into the real dashboard (preact/TS), reading the live
mission snapshot.

- New `AttentionIndicator` in the top-bar header actions (`app.ts`).
- The flat `Attention N` badge is removed from `ConnectionStatus` (`dashboard-shell.ts`) — the
  attention count now lives in the dedicated indicator, and `ConnectionStatus` is purely about the
  transport again.
- `.v2-statchip.bad` tone + `.v2-statchip.attn` (button) added to `app-shell-v2.css`; the dropdown
  uses inline Tailwind tokens (the dashboard idiom).

## Data grounding — why the buckets differ from the prototype's four

The prototype mocked four fixed buckets: **승인 대기 / 주의 keeper / 죽음·넘침 / stale 게이트**, fed by a
pre-aggregated `attention = { total, approvals, keepers, dead, stale }` object. The real
`attention_queue` (`DashboardMissionResponse.attention_queue`, built in
`lib/operator/operator_digest.ml`) does not carry that taxonomy:

| Field | Real vocabulary (ground truth) | Source |
|---|---|---|
| `target_type` | `workspace`, `keeper` — only these two | operator_digest.ml:52,82,186,245 |
| `severity` | `critical`, `bad`, `warn` (closed enum) | operator_digest_types.ml:5-7 |
| `kind` | `pending_confirm_waiting`, `keeper_<reason>` (runtime), tool-host failures | operator_digest.ml:77,107-108,141-142 |

There is **no gate/stale signal** and **no kind that distinguishes 죽음·넘침 from other keeper
attention**. Splitting keeper items into 주의 vs 죽음 by a `keeper_*` kind prefix would be a fragile
substring classifier (the RFC-0042 anti-pattern); fabricating a `stale` count with no backing data
would be inventing signal. Both are rejected.

So the indicator categorizes by the **real, closed vocabulary**, with an explicit catch-all so no
queued item is ever silently dropped:

| Bucket | Rule | Label | Navigates to |
|---|---|---|---|
| `approvals` | `kind === 'pending_confirm_waiting'` | 승인 대기 | `approvals` |
| `keepers` | `target_type === 'keeper'` | 주의 keeper | `keepers` |
| `other` | everything else | 기타 | `overview` |

- `total === attention_queue.length` (consistent with the former flat badge); bucket counts always
  sum to the total.
- Per-bucket tone is the worst severity in the bucket (`critical`/`bad` → `bad`, else `warn`), so a
  dead/overflow keeper still surfaces under 주의 keeper with a `bad` tone rather than being lost.
- The keeper bucket routes to the `keepers` roster (the dashboard's actionable keeper surface)
  rather than the prototype's generic `monitor`.

## Follow-ups

- If the backend later tags dead/overflow and stale-gate attention in `attention_queue` (distinct
  `kind`/`target_type`), add the corresponding buckets here — the partition is the only thing that
  changes.
- Per-item drill-down: items carry `target_id`; a future enhancement could route a single keeper
  item straight to that keeper. The current port follows the design's category-level navigation.

## Verification

- `pnpm --dir dashboard exec vitest run --config vitest.config.ts src/components/attention-indicator.test.ts --no-file-parallelism --maxWorkers=1`
  covers the pure `attentionItemBucket` / `summarizeAttention` partition (bucket rules, total
  invariant, tone, order, empty), `BUCKET_META` nav targets, and the component (zero-state, chip
  tone/total, dropdown open + per-row navigate, outside-click close, Escape close).
- Broader dashboard type/lint/build validation is left to PR CI and the normal release gate.
