import { computed } from '@preact/signals'
import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { activeKeeperName } from '../../keeper-state'
import { bridgeBdiSnapshotsToTrace } from './bdi-snapshot-trace-bridge'
import { asBoolean, asNumber, asString, isRecord, toIsoTimestamp } from '../common/normalize'
import { clearPins, headPinnedKeeper, pinKeeper } from './multi-keeper-pin-store'
import { cursorOverlaySignal } from './keeper-cursor-overlay'
// Imported from `./ide-state` rather than `./ide-shell` to avoid the
// circular dependency `ide-shell -> inspector-keeper-bdi -> ide-shell`
// (which also drags `router` and other window-touching side effects
// into this module's tests).
import { activeIdeFile } from './ide-state'
import { OverlayKeeperTrace } from './overlay-keeper-trace'

export interface KeeperBdiTokenSpend {
  readonly ts_unix: number | null
  readonly ts: string | null
  readonly channel: string | null
  readonly model: string | null
  readonly input_tokens: number | null
  readonly output_tokens: number | null
  readonly total_tokens: number | null
}

export interface KeeperBdiToolCall {
  readonly ts_unix: number | null
  readonly tool: string | null
  readonly success: boolean | null
  readonly semantic_outcome: string | null
  readonly duration_ms: number | null
}

export interface KeeperBdiSnapshot {
  readonly keeper: string
  readonly generated_at: string | null
  readonly poll_interval_ms: number
  readonly belief: string | null
  readonly desire: string | null
  readonly intention: string | null
  readonly need: string | null
  readonly profile_will: string | null
  readonly profile_needs: string | null
  readonly profile_desires: string | null
  readonly recent_token_spend: ReadonlyArray<KeeperBdiTokenSpend>
  readonly last_tool_call: KeeperBdiToolCall | null
  readonly source: string | null
}

interface InspectorKeeperPin {
  readonly keeperName: string
  readonly line: number | null
}

/**
 * RFC-0027 PR-α backward-compat: legacy single-pin signal is now a derived
 * projection over the head of `pinnedKeepers` (max-4 LRU store). Reads stay
 * identical; mutators move to `pinKeeper` / `clearPins` from
 * `multi-keeper-pin-store.ts`.
 */
export const inspectorKeeperPin = computed<InspectorKeeperPin | null>(() => {
  const head = headPinnedKeeper.value
  return head ? { keeperName: head.keeperName, line: head.line } : null
})

export function pinInspectorKeeper(keeperName: string, line: number | null): void {
  const trimmed = keeperName.trim()
  if (trimmed) {
    pinKeeper(trimmed, line)
  } else {
    clearPins()
  }
}

function normalizeTokenSpend(raw: unknown): KeeperBdiTokenSpend | null {
  if (!isRecord(raw)) return null
  return {
    ts_unix: asNumber(raw.ts_unix) ?? null,
    ts: toIsoTimestamp(raw.ts_unix) ?? asString(raw.ts) ?? null,
    channel: asString(raw.channel) ?? null,
    model: asString(raw.model) ?? null,
    input_tokens: asNumber(raw.input_tokens) ?? null,
    output_tokens: asNumber(raw.output_tokens) ?? null,
    total_tokens: asNumber(raw.total_tokens) ?? null,
  }
}

function normalizeLastToolCall(raw: unknown): KeeperBdiToolCall | null {
  if (!isRecord(raw)) return null
  const tool = asString(raw.tool) ?? null
  if (!tool) return null
  return {
    ts_unix: asNumber(raw.ts_unix) ?? null,
    tool,
    success: asBoolean(raw.success) ?? null,
    semantic_outcome: asString(raw.semantic_outcome) ?? null,
    duration_ms: asNumber(raw.duration_ms) ?? null,
  }
}

export function normalizeKeeperBdiSnapshot(raw: unknown): KeeperBdiSnapshot | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  if (!keeper) return null
  return {
    keeper,
    generated_at: asString(raw.generated_at) ?? null,
    poll_interval_ms: asNumber(raw.poll_interval_ms) ?? 5000,
    belief: asString(raw.belief) ?? null,
    desire: asString(raw.desire) ?? null,
    intention: asString(raw.intention) ?? null,
    need: asString(raw.need) ?? null,
    profile_will: asString(raw.profile_will) ?? null,
    profile_needs: asString(raw.profile_needs) ?? null,
    profile_desires: asString(raw.profile_desires) ?? null,
    recent_token_spend: Array.isArray(raw.recent_token_spend)
      ? raw.recent_token_spend.map(normalizeTokenSpend).filter((item): item is KeeperBdiTokenSpend => item !== null)
      : [],
    last_tool_call: normalizeLastToolCall(raw.last_tool_call),
    source: asString(raw.source) ?? null,
  }
}

async function fetchKeeperBdiSnapshot(keeperName: string, signal: AbortSignal): Promise<KeeperBdiSnapshot | null> {
  const res = await fetch(`/api/v1/keepers/${encodeURIComponent(keeperName)}/bdi-snapshot`, { signal })
  if (!res.ok) return null
  return normalizeKeeperBdiSnapshot(await res.json())
}

function useInspectorKeeperPin(): InspectorKeeperPin | null {
  const [pin, setPin] = useState(inspectorKeeperPin.value)
  useEffect(() => inspectorKeeperPin.subscribe(value => setPin(value)), [])
  return pin
}

function useActiveKeeperName(): string {
  const [name, setName] = useState(activeKeeperName.value)
  useEffect(() => activeKeeperName.subscribe(value => setName(value)), [])
  return name
}

function useReducedMotion(): boolean {
  const [reduced, setReduced] = useState(false)

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return
    const media = window.matchMedia('(prefers-reduced-motion: reduce)')
    setReduced(media.matches)
    const listener = () => setReduced(media.matches)
    media.addEventListener?.('change', listener)
    return () => media.removeEventListener?.('change', listener)
  }, [])

  return reduced
}

function formatTokens(value: number | null): string {
  return value === null ? '—' : value.toLocaleString()
}

function formatAge(value: string | null): string {
  if (!value) return '—'
  return value.slice(11, 19)
}

function BdiRow({ label, value }: { readonly label: string, readonly value: string | null }) {
  return html`
    <div style=${{ display: 'grid', gap: '2px' }}>
      <span style=${{ font: 'var(--type-eyebrow)', color: 'var(--color-fg-muted)' }}>${label}</span>
      <span style=${{ color: value ? 'var(--color-fg-secondary)' : 'var(--color-fg-disabled)', lineHeight: 1.35 }}>
        ${value ?? '—'}
      </span>
    </div>
  `
}

export function InspectorKeeperBDI({
  pollMs = 5000,
  traceActive = false,
}: {
  readonly pollMs?: number
  readonly traceActive?: boolean
}) {
  const pin = useInspectorKeeperPin()
  const activeKeeper = useActiveKeeperName()
  const reducedMotion = useReducedMotion()
  // Single trim point: fetch URL, header display, and OverlayKeeperTrace's
  // keeperFilter all share the same string. Untrimmed sources (e.g. an
  // activeKeeperName signal set without trimming) would otherwise let polling
  // succeed for "scholar" while the overlay filter "  scholar  " misses the
  // events the producer pushed under the trimmed keeper name.
  const keeperName = (pin?.keeperName ?? activeKeeper).trim()
  const [snapshot, setSnapshot] = useState<KeeperBdiSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!keeperName) {
      setSnapshot(null)
      setError(null)
      return
    }

    const controller = new AbortController()
    let timer: number | null = null
    const refresh = async () => {
      try {
        const next = await fetchKeeperBdiSnapshot(keeperName, controller.signal)
        if (controller.signal.aborted) return
        setSnapshot(next)
        setError(next ? null : 'snapshot unavailable')
      } catch {
        if (!controller.signal.aborted) setError('snapshot unavailable')
      }
    }

    void refresh()
    timer = window.setInterval(refresh, Math.max(1000, pollMs))
    return () => {
      controller.abort()
      if (timer !== null) window.clearInterval(timer)
    }
  }, [keeperName, pollMs])

  // RFC-0028 PR-δ-4 bdi-snapshot producer: each fresh poll result becomes
  // a keeper-trace event. Dedup key is `bdi:${keeper}:${generated_at}` so
  // a polling tick that returns the same snapshot does not re-emit; a
  // server publish of a fresh BDI tick advances `generated_at` and emits
  // a new event.
  const knownBdiKeys = useRef<ReadonlySet<string>>(new Set())
  useEffect(() => {
    if (snapshot === null) return
    knownBdiKeys.current = bridgeBdiSnapshotsToTrace([snapshot], knownBdiKeys.current)
  }, [snapshot])

  const cursor = cursorOverlaySignal.value.cursors.get(keeperName)
  // The SSE adapter defaults a missing `line` to 0 (see
  // `keeper-cursor-overlay.ts::connectKeeperCursorStream` —
  // `line: entry.line || 0`), so requiring a 1-based line here avoids
  // labels like `foo.ts:0` and prevents click-to-navigate firing for
  // placeholder cursors.
  const hasValidFocus = !!cursor?.file_path && typeof cursor.line === 'number' && cursor.line >= 1
  const focusLabel = hasValidFocus
    ? `${cursor!.file_path.split('/').pop()}:${cursor!.line}`
    : null
  const tokenRows = snapshot?.recent_token_spend ?? []
  const lastTool = snapshot?.last_tool_call ?? null

  const navigateToFocus = (): void => {
    if (hasValidFocus && cursor) activeIdeFile.value = cursor.file_path
  }

  return html`
    <section
      aria-label="Keeper BDI inspector"
      data-reduced-motion=${reducedMotion ? 'true' : 'false'}
      style=${{
        display: 'grid',
        gap: 'var(--sp-3)',
        padding: 'var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        background: 'var(--color-bg-surface)',
        minHeight: '180px',
      }}
    >
      <header style=${{ display: 'flex', alignItems: 'baseline', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
        <h3 style=${{ margin: 0, font: 'var(--type-eyebrow)', color: 'var(--color-fg-primary)' }}>
          Keeper BDI
        </h3>
        <span style=${{ color: 'var(--color-accent-fg)', fontSize: 'var(--fs-12)' }}>
          ${keeperName || '—'}
        </span>
        ${focusLabel ? html`
          <button
            type="button"
            data-testid="bdi-focus-label"
            onClick=${navigateToFocus}
            title=${cursor?.file_path ?? ''}
            style=${{
              color: 'var(--color-accent-fg)',
              fontSize: 'var(--fs-11)',
              maxWidth: '160px',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
              cursor: 'pointer',
              borderRadius: 'var(--r-0)',
              padding: '0 var(--sp-1)',
              transition: 'background 0.15s',
              background: 'transparent',
              border: 'none',
              font: 'inherit',
              lineHeight: 'inherit',
              textAlign: 'left',
            }}
          >${focusLabel}</button>
        ` : null}
        ${pin?.line
          ? html`<span style=${{ marginLeft: 'auto', color: 'var(--color-fg-muted)', fontSize: 'var(--fs-11)' }}>L${pin.line}</span>`
          : null}
      </header>

      ${error
        ? html`<div role="status" style=${{ color: 'var(--color-status-warn)', fontSize: 'var(--fs-12)' }}>${error}</div>`
        : null}

      <div style=${{ display: 'grid', gridTemplateColumns: '1fr', gap: 'var(--sp-2)', fontSize: 'var(--fs-12)' }}>
        <${BdiRow} label="Belief" value=${snapshot?.belief ?? null} />
        <${BdiRow} label="Desire" value=${snapshot?.desire ?? null} />
        <${BdiRow} label="Intention" value=${snapshot?.intention ?? null} />
        ${snapshot?.need ? html`<${BdiRow} label="Need" value=${snapshot.need} />` : null}
      </div>

      <div style=${{ display: 'grid', gap: 'var(--sp-1)' }}>
        <div style=${{ font: 'var(--type-eyebrow)', color: 'var(--color-fg-muted)' }}>Recent Tokens</div>
        <div style=${{ display: 'grid', gap: '2px', fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-11)' }}>
          ${tokenRows.length === 0
            ? html`<span style=${{ color: 'var(--color-fg-disabled)' }}>—</span>`
            : tokenRows.map(row => html`
                <div
                  key=${`${row.ts_unix ?? 0}-${row.total_tokens ?? 0}`}
                  style=${{ display: 'grid', gridTemplateColumns: '54px 1fr auto', gap: 'var(--sp-2)', color: 'var(--color-fg-secondary)' }}
                >
                  <span style=${{ color: 'var(--color-fg-muted)' }}>${formatAge(row.ts)}</span>
                  <span>${row.model ?? row.channel ?? 'turn'}</span>
                  <span>${formatTokens(row.total_tokens)} tok</span>
                </div>
              `)}
        </div>
      </div>

      <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
        <span style=${{ font: 'var(--type-eyebrow)' }}>Last Tool</span>
        <span style=${{ color: lastTool?.tool ? 'var(--color-fg-secondary)' : 'var(--color-fg-disabled)' }}>
          ${lastTool?.tool ?? '—'}
        </span>
        ${lastTool?.semantic_outcome
          ? html`<span style=${{ color: lastTool.success === false ? 'var(--color-status-warn)' : 'var(--color-status-ok)' }}>${lastTool.semantic_outcome}</span>`
          : null}
      </div>

      ${keeperName
        ? html`<${OverlayKeeperTrace} active=${traceActive} keeperFilter=${keeperName} />`
        : null}
    </section>
  `
}
