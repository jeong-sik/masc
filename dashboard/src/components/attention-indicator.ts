// AttentionIndicator — the top-bar "주의 N" attention center (keeper-v2 design).
//
// Replaces the flat "Attention N → overview" badge with the design's
// categorized chip + dropdown: a count chip that opens a menu listing the
// non-empty attention categories, each navigating to the surface where the
// operator can act on it, plus a "✓ 정상" zero-state.
//
// DATA GROUNDING (why the buckets differ from the prototype's four):
// The keeper-v2 prototype mocked four fixed buckets (승인 대기 / 주의 keeper /
// 죽음·넘침 / stale 게이트). The real `attention_queue` only carries
// `target_type ∈ { "workspace", "keeper" }` and `severity ∈ { "critical",
// "bad", "warn" }` (lib/operator/operator_digest.ml,
// lib/dashboard/operator_digest_types.ml) — there is no gate/stale taxonomy
// and no kind that distinguishes "죽음·넘침" from other keeper attention.
// Inventing those from a `keeper_*` kind prefix would be a fragile substring
// classifier (the RFC-0042 anti-pattern). So we categorize by the REAL,
// closed vocabulary and route unmatched items to an explicit `other` bucket
// — no item is silently dropped, and dead/overflow keepers still surface
// under `keepers` with a `bad` tone. When the backend tags dead/stale in the
// queue, add buckets here.

import { html } from 'htm/preact'
import { useState, useEffect } from 'preact/hooks'
import { navigate } from '../router'
import { missionSnapshot } from '../mission-signals'
import type { TabId } from '../types'
import type { DashboardMissionAttentionQueueItem } from '../types/dashboard-mission'

// Server attention vocabulary — matched by exact equality, never substring.
const APPROVAL_KIND = 'pending_confirm_waiting' // operator_digest.ml:77 (target_type=workspace)
const KEEPER_TARGET_TYPE = 'keeper' //               operator_digest.ml:186,245
// severity enum — operator_digest_types.ml:5-7. critical/bad → bad tone, warn → warn.
const BAD_SEVERITIES: ReadonlySet<string> = new Set(['critical', 'bad'])

export type AttentionBucketKey = 'approvals' | 'keepers' | 'other'
export type AttentionTone = 'bad' | 'warn'

interface AttentionBucketMeta {
  /** Korean category label shown in the dropdown row. */
  label: string
  /** Surface the row navigates to so the operator can resolve this category. */
  tab: TabId
}

// Fixed display order + per-bucket label and nav target. `keepers` routes to
// the keeper roster (the dashboard's actionable keeper surface) rather than
// the prototype's generic `monitor`; `other` falls back to the overview
// triage surface (where the old flat badge pointed).
export const BUCKET_META: Record<AttentionBucketKey, AttentionBucketMeta> = {
  approvals: { label: '승인 대기', tab: 'approvals' },
  keepers: { label: '주의 keeper', tab: 'keepers' },
  other: { label: '기타', tab: 'overview' },
}
const BUCKET_ORDER: readonly AttentionBucketKey[] = ['approvals', 'keepers', 'other']

/** Which design bucket an attention item belongs to, by the real server
 *  vocabulary. Approvals are identified by `kind`; keeper items by the
 *  closed `target_type`; everything else is an explicit `other` so the
 *  bucket counts always sum to the total (no silent drop). */
export function attentionItemBucket(
  item: Pick<DashboardMissionAttentionQueueItem, 'kind' | 'target_type'>,
): AttentionBucketKey {
  if (item.kind === APPROVAL_KIND) return 'approvals'
  if (item.target_type === KEEPER_TARGET_TYPE) return 'keepers'
  return 'other'
}

export interface AttentionBucket {
  key: AttentionBucketKey
  count: number
  /** Worst severity among the bucket's items. */
  tone: AttentionTone
}

export interface AttentionSummary {
  total: number
  /** Worst severity overall — drives the chip tone. */
  tone: AttentionTone
  /** Non-empty buckets in fixed display order. */
  buckets: AttentionBucket[]
}

/** Pure: partition the attention queue into the categorized summary the
 *  indicator renders. `total` equals the queue length (consistent with the
 *  former flat badge); tone is `bad` if any item is critical/bad. */
export function summarizeAttention(
  items: ReadonlyArray<DashboardMissionAttentionQueueItem>,
): AttentionSummary {
  const counts = new Map<AttentionBucketKey, { count: number; bad: boolean }>()
  let anyBad = false
  for (const item of items) {
    const key = attentionItemBucket(item)
    const isBad = BAD_SEVERITIES.has(item.severity)
    anyBad = anyBad || isBad
    const prev = counts.get(key) ?? { count: 0, bad: false }
    counts.set(key, { count: prev.count + 1, bad: prev.bad || isBad })
  }
  const buckets: AttentionBucket[] = []
  for (const key of BUCKET_ORDER) {
    const c = counts.get(key)
    if (c !== undefined && c.count > 0) {
      buckets.push({ key, count: c.count, tone: c.bad ? 'bad' : 'warn' })
    }
  }
  return { total: items.length, tone: anyBad ? 'bad' : 'warn', buckets }
}

const MENU_TITLE = '지금 나를 필요로 하는 것'

/** The categorized top-bar attention center. Reads the live mission snapshot,
 *  renders the "⚑ 주의 N" chip (or "✓ 정상" zero-state), and on click opens a
 *  dropdown of the non-empty categories that navigate to their surface. */
export function AttentionIndicator() {
  const [open, setOpen] = useState(false)
  // Close on any outside click while open (the chip's own clicks are stopped
  // below so they don't immediately re-close the menu).
  useEffect(() => {
    if (!open) return
    const close = () => setOpen(false)
    window.addEventListener('click', close)
    return () => window.removeEventListener('click', close)
  }, [open])

  const snap = missionSnapshot.value
  const summary = summarizeAttention(snap?.attention_queue ?? [])

  if (summary.total === 0) {
    return html`<span
      class="v2-statchip live"
      data-attention-indicator
      data-attention-total="0"
      title="처리할 항목 없음"
    >${'✓'} 정상</span>`
  }

  return html`<div
    class="attn-wrap relative inline-flex"
    data-attention-indicator
    data-attention-total=${summary.total}
    onClick=${(e: Event) => e.stopPropagation()}
  >
    <button
      type="button"
      class=${`v2-statchip attn ${summary.tone}`}
      aria-haspopup="true"
      aria-expanded=${open ? 'true' : 'false'}
      title=${MENU_TITLE}
      onClick=${() => setOpen((o) => !o)}
    >${'⚑'} 주의 <b>${summary.total}</b></button>
    ${open
      ? html`<div
          class="attn-menu absolute right-0 top-[calc(100%+6px)] z-50 min-w-[208px] rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-1 shadow-[0_8px_24px_rgb(0_0_0/0.28)]"
          role="menu"
        >
          <div class="px-2 py-1 text-2xs uppercase tracking-[0.05em] text-[var(--color-fg-muted)]">${MENU_TITLE}</div>
          ${summary.buckets.map((b) => {
            const meta = BUCKET_META[b.key]
            const dotColor = b.tone === 'bad' ? 'var(--color-status-err)' : 'var(--color-status-warn)'
            return html`<button
              type="button"
              key=${b.key}
              class="attn-row flex w-full items-center gap-2 rounded-[var(--r-0)] px-2 py-1.5 text-left text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-surface)]"
              role="menuitem"
              data-attention-bucket=${b.key}
              onClick=${() => {
                setOpen(false)
                navigate(meta.tab)
              }}
            >
              <span class="size-1.5 shrink-0 rounded-full" style=${`background:${dotColor}`}></span>
              <span class="flex-1">${meta.label}</span>
              <span class="font-mono tabular-nums text-[var(--color-fg-muted)]">${b.count}</span>
            </button>`
          })}
        </div>`
      : null}
  </div>`
}
