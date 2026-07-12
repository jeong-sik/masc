import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { useStoreSubscription } from './use-signal-value'
import type { FunctionComponent } from 'preact'
import { dispatchKeeperInterjectAction } from '../../keeper-actions'
import { activeKeeperName } from '../../keeper-state'
import {
  createInterjectStore,
  type InterjectActionState,
  type InterjectDispatchRequest,
} from './interject-store'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide-context-lens'
import { globalPresenceSnapshot, presenceEntries, type KeeperPresenceStatus } from './keeper-presence-store'
import { cursorOverlaySignal, getKeeperColor, type KeeperCursor } from './keeper-cursor-overlay'

// The input and button states flow through the same store/dispatch boundary
// that live active-keeper wiring uses. Send remains disabled until a concrete
// keeper resolves, preferring the route-scoped keeper over the global signal.

async function dispatchInterject(request: InterjectDispatchRequest): Promise<void> {
  await dispatchKeeperInterjectAction({
    kind: request.kind,
    keeperName: request.keeper_id,
    message: request.message,
  })
}

interface IdeInterjectProps {
  readonly keeperName?: string | null
  /** A terminal-first IDE keeps chat as a floating entry point until opened. */
  readonly compact?: boolean
}

function resolveActiveKeeper(keeperName?: string | null): string {
  const routeKeeper = keeperName?.trim()
  return routeKeeper || activeKeeperName.value
}

export const IdeInterject: FunctionComponent<IdeInterjectProps> = ({
  keeperName = null,
  compact = false,
}) => {
  const [expanded, setExpanded] = useState(false)
  const [interjectStore] = useState(() =>
    createInterjectStore({
      initialActiveKeeper: resolveActiveKeeper(keeperName),
      dispatch: dispatchInterject,
    }))
  useStoreSubscription(interjectStore.subscribe)

  useEffect(() => {
    const unsub = activeKeeperName.subscribe(name => {
      interjectStore.setActiveKeeper(keeperName?.trim() || name)
    })
    return () => unsub()
  }, [interjectStore, keeperName])
  useEffect(() => {
    const unsub = activeKeeperName.subscribe(name => {
      interjectStore.setActiveKeeper(keeperName?.trim() || name)
    })
    return () => unsub()
  }, [interjectStore, keeperName])
  useEffect(() => {
    interjectStore.setActiveKeeper(resolveActiveKeeper(keeperName))
  }, [interjectStore, keeperName])

  const [presence, setPresence] = useState(globalPresenceSnapshot.value)
  useEffect(() => {
    const unsub = globalPresenceSnapshot.subscribe(v => setPresence(v))
    return () => unsub()
  }, [])

  const [overlay, setOverlay] = useState(cursorOverlaySignal.value)
  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(v => setOverlay(v))
    return () => unsub()
  }, [])

  const snapshot = interjectStore.snapshot()
  const actions = interjectStore.actions()
  const keeperId = snapshot.active_keeper_id ?? ''
  // InterjectStore only .trim()s keeper IDs; route keeper names may differ
  // in casing. Compare on lowercase+trim so a presence entry from the route
  // matches the (cased) interject keeper id.
  const keeperIdNorm = keeperId.trim().toLowerCase()
  const presenceEntry = keeperIdNorm
    ? presenceEntries(presence).find(e => e.keeper_id.trim().toLowerCase() === keeperIdNorm) ?? null
    : null
  const cursor = keeperId
    ? resolveCursor(keeperId, overlay.cursors)
    : null
  const contextLinks = interjectContextRouteLinks(keeperId, cursor)

  if (compact && !expanded) {
    return html`
      <button
        type="button"
        class="ide-interject-fab"
        data-testid="ide-interject-fab"
        aria-label="Open keeper chat"
        onClick=${() => setExpanded(true)}
      >✦ Chat</button>
    `
  }

  return html`
    <div
      class=${`ide-interject-bar v2-ide-panel ${compact ? 'ide-interject-expanded' : ''}`}
      role="region"
      aria-label="INTERJECT (interject store active keeper wiring)"
      style=${{
        display: 'grid',
        gap: 'var(--sp-2)',
        padding: 'var(--sp-2) var(--sp-3)',
        background: 'var(--color-bg-elevated)',
        borderTop: '1px solid var(--color-border-default)',
        alignItems: 'center',
      }}
    >
      <div
        style=${{
          display: 'flex',
          flexDirection: 'column',
          gap: '2px',
          font: 'var(--type-eyebrow)',
          color: 'var(--color-fg-muted)',
          padding: '0 var(--sp-2)',
        }}
      >
        <span>INTERJECT</span>
        <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-1)' }}>
          <span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-secondary)' }}>
            ${keeperId || 'No active keeper'}
          </span>
          ${presenceEntry ? KeeperPresencePill(presenceEntry.status) : null}
        </div>
        ${cursor ? CursorLocation(cursor) : null}
        <${InterjectContextLinks} links=${contextLinks} />
      </div>
      <input
        class="ide-interject-input"
        type="text"
        placeholder="Send message to active keeper..."
        aria-label="Interject input"
        value=${snapshot.message}
        disabled=${snapshot.busy_action !== null}
        onInput=${(event: Event) =>
          interjectStore.setMessage((event.currentTarget as HTMLInputElement).value)}
        style=${{
          width: '100%',
          padding: 'var(--sp-2)',
          background: 'var(--color-bg-page)',
          color: 'var(--color-fg-secondary)',
          border: '1px solid var(--color-border-default)',
          borderRadius: 'var(--r-1)',
          font: 'var(--type-body)',
        }}
      />
      <div class="ide-interject-actions" style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
        ${actions.map(action => InterjectButton(action, () => {
          void interjectStore.submit(action.kind)
        }))}
      </div>
      ${snapshot.error
        ? html`<span
            role="status"
            style=${{
              gridColumn: '2 / 4',
              color: 'var(--color-status-warn)',
              fontSize: 'var(--fs-11)',
            }}
          >${snapshot.error}</span>`
        : null}
    </div>
  `
}

export function interjectContextRouteLinks(
  keeperId: string,
  cursor: KeeperCursor | null,
): ReadonlyArray<IdeContextRouteLink> {
  const keeper = keeperId.trim()
  if (!keeper) return []
  return routeLinksForContext({
    filePath: cursor?.file_path,
    line: cursor?.line,
    surface: 'Interject',
    label: cursor?.tool_name ?? cursor?.focus_mode ?? 'active keeper',
    sourceId: `interject:${keeper}`,
    keeperId: keeper,
    telemetry: true,
    telemetryQuery: interjectTelemetryQuery(keeper, cursor),
  })
}

function interjectTelemetryQuery(keeperId: string, cursor: KeeperCursor | null): string {
  return [
    'interject',
    `keeper:${keeperId}`,
    cursor?.focus_mode ? `mode:${cursor.focus_mode}` : null,
    cursor?.tool_name ? `tool:${cursor.tool_name}` : null,
  ].filter((value): value is string => value !== null).join(' ')
}

function InterjectContextLinks({
  links,
}: {
  readonly links: ReadonlyArray<IdeContextRouteLink>
}) {
  if (links.length === 0) return null
  return html`
    <div class="ide-interject-context-links" aria-label="Interject context links">
      <span
        class="ide-interject-context-count"
        title=${`${links.length} linked interject context routes`}
        aria-label=${`${links.length} linked interject context routes`}
      >
        CTX ${links.length}
      </span>
      ${links.map(link => html`
        <button
          key=${link.id}
          type="button"
          class="v2-ide-action"
          title=${link.evidence}
          aria-label=${`Open ${link.evidence}`}
          onClick=${() => openIdeContextRouteLink(link)}
        >${link.label}</button>
      `)}
    </div>
  `
}

function InterjectButton(action: InterjectActionState, onClick: () => void) {
  return html`
    <button
      type="button"
      class="v2-ide-action"
      disabled=${!action.enabled}
      aria-label=${action.disabled_reason
        ? `${action.label} (${action.disabled_reason})`
        : action.label}
      title=${action.disabled_reason ?? action.label}
      onClick=${onClick}
      style=${{
        padding: '6px 12px',
        background: action.primary ? 'var(--color-accent-fg)' : 'var(--color-bg-surface)',
        color: action.primary ? 'var(--color-bg-page)' : 'var(--color-fg-secondary)',
        border: action.primary ? 'none' : '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-1)',
        font: 'var(--type-body)',
        cursor: action.enabled ? 'pointer' : 'not-allowed',
        opacity: action.enabled ? 1 : 0.65,
      }}
    >${action.label}</button>
  `
}

const PRESENCE_STYLES: Record<KeeperPresenceStatus, { color: string; bg: string; label: string }> = {
  active: { color: 'var(--color-status-ok)', bg: 'rgb(var(--color-status-ok-glow) / 0.15)', label: 'ACTIVE' },
  blocked: { color: 'var(--color-status-err)', bg: 'rgb(var(--color-status-err-glow) / 0.15)', label: 'BLOCKED' },
  idle: { color: 'var(--color-fg-muted)', bg: 'var(--color-bg-surface)', label: 'IDLE' },
}

function KeeperPresencePill(status: KeeperPresenceStatus) {
  const style = PRESENCE_STYLES[status]
  return html`
    <span
      role="status"
      aria-label=${`Keeper status: ${style.label}`}
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: '3px',
        padding: '1px 5px',
        fontSize: 'var(--fs-10)',
        fontWeight: 600,
        letterSpacing: '0.04em',
        color: style.color,
        background: style.bg,
        borderRadius: 'var(--r-1)',
        lineHeight: 1,
      }}
    >
      <span
        aria-hidden="true"
        style=${{
          width: '5px',
          height: '5px',
          borderRadius: '50%',
          background: style.color,
          display: 'inline-block',
        }}
      />
      ${style.label}
    </span>
  `
}

function CursorLocation(cursor: {
  keeper_id: string
  file_path: string
  line: number
  focus_mode: string
  tool_name?: string
}) {
  const fileName = cursor.file_path.split('/').pop() ?? cursor.file_path
  const color = getKeeperColor(cursor.keeper_id)
  return html`
    <div
      style=${{
        display: 'flex',
        alignItems: 'center',
        gap: 'var(--sp-1)',
        fontSize: 'var(--fs-10)',
        fontFamily: 'var(--font-mono)',
        color: 'var(--color-fg-muted)',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      }}
      title=${cursor.file_path}
    >
      <span
        aria-hidden="true"
        style=${{
          width: '4px',
          height: '4px',
          borderRadius: '50%',
          background: color.cursor,
          display: 'inline-block',
          flexShrink: 0,
        }}
      />
      <span>${fileName}:${cursor.line}</span>
      ${cursor.tool_name
        ? html`<span style=${{ color: 'var(--color-fg-disabled)' }}>· ${cursor.tool_name}</span>`
        : null}
    </div>
  `
}

function resolveCursor(
  keeperId: string,
  cursors: Map<string, KeeperCursor>,
): KeeperCursor | null {
  const target = keeperId.toLowerCase().trim()
  for (const [id, cursor] of cursors) {
    if (id.toLowerCase() === target) return cursor
  }
  return null
}
