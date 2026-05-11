import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { FunctionComponent } from 'preact'
import { dispatchKeeperInterjectAction } from '../../keeper-actions'
import { activeKeeperName } from '../../keeper-state'
import {
  createInterjectStore,
  type InterjectActionState,
  type InterjectDispatchRequest,
} from './interject-store'
import { globalPresenceSnapshot, type KeeperPresenceEntry, type KeeperPresenceStatus } from './keeper-presence-store'
import { cursorOverlaySignal } from './keeper-cursor-overlay'

const PRESENCE_DOT: Record<KeeperPresenceStatus, { color: string; label: string }> = {
  active: { color: 'var(--color-status-ok)', label: 'ACTIVE' },
  blocked: { color: 'var(--color-status-err)', label: 'BLOCKED' },
  idle: { color: 'var(--color-fg-muted)', label: 'IDLE' },
}

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

interface IdeInterjectMockProps {
  readonly keeperName?: string | null
}

function resolveActiveKeeper(keeperName?: string | null): string {
  const routeKeeper = keeperName?.trim()
  return routeKeeper || activeKeeperName.value
}

export const IdeInterjectMock: FunctionComponent<IdeInterjectMockProps> = ({ keeperName = null }) => {
  const [interjectStore] = useState(() =>
    createInterjectStore({
      initialActiveKeeper: resolveActiveKeeper(keeperName),
      dispatch: dispatchInterject,
    }))
  const [, forceRender] = useState(0)

  useEffect(() => {
    const unsub = interjectStore.subscribe(() => forceRender((t: number) => t + 1))
    return () => unsub()
  }, [interjectStore])
  useEffect(() => {
    const unsub = globalPresenceSnapshot.subscribe(() => forceRender((t: number) => t + 1))
    return () => unsub()
  }, [])
  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(() => forceRender((t: number) => t + 1))
    return () => unsub()
  }, [])
  useEffect(() => {
    const unsub = activeKeeperName.subscribe(name => {
      interjectStore.setActiveKeeper(keeperName?.trim() || name)
    })
    return () => unsub()
  }, [interjectStore, keeperName])
  useEffect(() => {
    interjectStore.setActiveKeeper(resolveActiveKeeper(keeperName))
  }, [interjectStore, keeperName])

  const snapshot = interjectStore.snapshot()
  const actions = interjectStore.actions()

  const presence = globalPresenceSnapshot.value
  const entries: ReadonlyArray<KeeperPresenceEntry> = presence?.entries ?? []
  const keeperId = snapshot.active_keeper_id
  const entry = keeperId ? entries.find(e => e.keeper_id === keeperId) : null
  const statusDot = entry ? PRESENCE_DOT[entry.status] : null
  const cursor = keeperId ? cursorOverlaySignal.value.cursors.get(keeperId) : undefined
  const focusLabel = cursor && cursor.file_path && cursor.line >= 1
    ? `${cursor.file_path.split('/').pop()}:${cursor.line}`
    : null

  return html`
    <div
      class="ide-interject-bar"
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
        <span style=${{ fontSize: 'var(--fs-11)', display: 'flex', alignItems: 'center', gap: '4px' }}>
          ${snapshot.active_keeper_id ?? 'No active keeper'}
          ${statusDot ? html`
            <span
              role="status"
              aria-label=${`Keeper status: ${statusDot.label}`}
              style=${{
                display: 'inline-flex',
                alignItems: 'center',
                gap: '2px',
                fontSize: 'var(--fs-10)',
                fontWeight: 600,
                letterSpacing: '0.04em',
                color: statusDot.color,
              }}
            >
              <span style=${{
                width: '4px',
                height: '4px',
                borderRadius: '50%',
                background: statusDot.color,
                display: 'inline-block',
              }} />
              ${statusDot.label}
            </span>
          ` : null}
          ${focusLabel ? html`
            <span style=${{
              fontSize: 'var(--fs-10)',
              fontFamily: 'var(--font-mono)',
              color: 'var(--color-accent-fg)',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
              maxWidth: '120px',
            }}
            title=${cursor?.file_path}
            >↗ ${focusLabel}</span>
          ` : null}
        </span>
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

function InterjectButton(action: InterjectActionState, onClick: () => void) {
  return html`
    <button
      type="button"
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
