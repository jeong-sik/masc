// MASC collab web viewer — guest surface for share links (RFC-0471 §2.6).
//
// Mounted standalone from main.ts when location.hash carries a share link,
// bypassing the operator shell: guests are not dashboard operators, and the
// link secret must never enter route state, telemetry, or a query string.
// Same-origin dial only; the room id in the path is public, the key stays in
// the fragment and in memory.

import { html } from 'htm/preact'
import { render } from 'preact'
import { useEffect, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  collabGuestResource,
  isParsedCollabLink,
  parseCollabLink,
  type ParsedCollabLink,
} from '../collab-link'
import { importCollabKey } from '../collab-crypto'
import {
  collabSocketUrl,
  encodeWriteTokenForHello,
  openCollabSession,
  type CollabSession,
  type CollabSessionStatus,
} from '../collab-session'
import type { CollabJoinEvent } from '../collab-join'
import {
  renderCollabEvent,
  renderCollabSnapshotRow,
  type CollabLine,
} from '../collab-events'

const MAX_VIEWER_LINES = 5000
const FETCH_BYTES = 65536

interface ViewerHeader {
  keeper: string
  operation: string
}

function statusText(status: CollabSessionStatus): string {
  switch (status.kind) {
    case 'connecting':
      return 'Connecting…'
    case 'open':
      return 'Live'
    case 'closed':
      return `Closed — ${status.text}`
    case 'error':
      return status.text
    case 'warning':
      return status.text
  }
}

function lineClass(line: CollabLine): string {
  switch (line.kind) {
    case 'run':
      return 'collab-line collab-line-run'
    case 'role-user':
      return 'collab-line collab-line-role-user'
    case 'role-assistant':
      return 'collab-line collab-line-role-assistant'
    case 'tool':
      return 'collab-line collab-line-tool'
    case 'approval':
      return 'collab-line collab-line-approval'
    case 'status':
      return 'collab-line collab-line-status'
    case 'media':
      return 'collab-line collab-line-media'
    case 'error':
      return 'collab-line collab-line-error'
    case 'meta':
    case 'text':
      return 'collab-line'
  }
}

export function CollabViewer({ link }: { link: ParsedCollabLink }) {
  const status = useSignal<CollabSessionStatus>({ kind: 'connecting' })
  const header = useSignal<ViewerHeader | null>(null)
  const liveActive = useSignal(false)
  const liveGuests = useSignal(0)
  const readOnly = useSignal(link.capability === 'view')
  const lines = useSignal<CollabLine[]>([])
  const transcript = useSignal<string | null>(null)
  const promptDraft = useSignal('')
  const label = useSignal('web')
  const started = useSignal(false)
  const sessionRef = useRef<CollabSession | null>(null)
  const scrollRef = useRef<HTMLDivElement | null>(null)

  const appendLines = (fresh: CollabLine[]) => {
    if (fresh.length === 0) return
    const next = [...lines.value, ...fresh]
    lines.value = next.length > MAX_VIEWER_LINES
      ? [{ kind: 'meta', text: '(older lines trimmed)' }, ...next.slice(-MAX_VIEWER_LINES)]
      : next
    const pane = scrollRef.current
    if (pane && pane.scrollHeight - pane.scrollTop - pane.clientHeight < 120) {
      requestAnimationFrame(() => {
        pane.scrollTop = pane.scrollHeight
      })
    }
  }

  const handleEvent = (event: CollabJoinEvent) => {
    switch (event.kind) {
      case 'snapshot-row':
        appendLines(renderCollabSnapshotRow(event.row))
        break
      case 'live-entry':
        appendLines(renderCollabEvent(event.entry.event))
        break
      case 'state':
        liveActive.value = event.state.active
        liveGuests.value = event.state.guests
        if (event.welcome) {
          header.value = { keeper: event.welcome.keeper, operation: event.welcome.operation }
          readOnly.value = event.welcome.readOnly
        }
        break
      case 'transcript':
        transcript.value = event.transcript.error !== null
          ? `(transcript error: ${event.transcript.error})`
          : event.transcript.text
        break
      case 'bye':
        appendLines([{ kind: 'status', text: `── session ended: ${event.reason} ──` }])
        break
      case 'error-frame':
        appendLines([{ kind: 'error', text: `host error: ${event.message}` }])
        break
    }
  }

  useEffect(() => {
    let cancelled = false
    let session: CollabSession | null = null
    const start = async () => {
      const socketUrl = collabSocketUrl(collabGuestResource(link.roomId))
      if (!socketUrl) {
        if (!cancelled) status.value = { kind: 'error', text: 'This page must be served over http(s) to dial the relay.' }
        return
      }
      let key: CryptoKey
      try {
        key = await importCollabKey(link.key)
      } catch (err) {
        if (!cancelled) status.value = { kind: 'error', text: `Cannot use the room key: ${String(err)}` }
        return
      }
      if (cancelled) return
      session = openCollabSession({
        url: socketUrl,
        key,
        writeToken: encodeWriteTokenForHello(link.writeToken),
        label: label.value.trim() === '' ? null : label.value.trim(),
        canSteer: link.capability === 'control',
        onEvent: handleEvent,
        onStatus: next => {
          if (cancelled) return
          status.value = next
          if (next.kind === 'warning' || next.kind === 'error') {
            appendLines([{ kind: next.kind === 'error' ? 'error' : 'meta', text: next.text }])
          }
          if (next.kind === 'closed') {
            appendLines([{ kind: 'status', text: `── ${next.text} ──` }])
          }
        },
      })
      sessionRef.current = session
      started.value = true
    }
    void start()
    return () => {
      cancelled = true
      session?.close()
      sessionRef.current = null
    }
    // Mount-only: the link never changes under a viewer instance.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const sendPrompt = () => {
    const session = sessionRef.current
    const text = promptDraft.value.trim()
    if (!session || text === '') return
    if (!session.sendPrompt(promptDraft.value)) {
      appendLines([{ kind: 'meta', text: '(view links cannot steer; ask the host for a control link.)' }])
      return
    }
    promptDraft.value = ''
  }

  const sendAbort = () => {
    const session = sessionRef.current
    if (!session) return
    if (!session.sendAbort()) {
      appendLines([{ kind: 'meta', text: '(view links cannot steer; ask the host for a control link.)' }])
    }
  }

  const fetchTranscript = () => {
    const session = sessionRef.current
    if (!session) return
    if (!session.fetchTranscript(FETCH_BYTES)) {
      appendLines([{ kind: 'meta', text: '(view links cannot fetch transcripts.)' }])
    }
  }

  const control = link.capability === 'control' && !readOnly.value
  const statusKind = status.value.kind

  return html`
    <div class="collab-viewer">
      <header class="collab-header">
        <div class="collab-title">
          <span class="collab-badge ${link.capability === 'control' ? 'collab-badge-control' : 'collab-badge-view'}">
            ${link.capability === 'control' ? 'control' : 'view'}
          </span>
          <strong>${header.value ? `${header.value.keeper} — ${header.value.operation}` : 'Shared session'}</strong>
        </div>
        <div class="collab-meta">
          <span class="collab-status collab-status-${statusKind}">${statusText(status.value)}</span>
          <span class="collab-live">${liveActive.value ? '● active' : '○ idle'} · ${liveGuests.value} watching</span>
          <label class="collab-label">as
            <input
              type="text"
              value=${label.value}
              maxLength=${32}
              disabled=${started.value}
              onInput=${(e: Event) => { label.value = (e.target as HTMLInputElement).value }}
            />
          </label>
        </div>
      </header>
      <div class="collab-transcript" ref=${scrollRef} role="log" aria-live="polite">
        ${lines.value.map((line, index) => html`<div key=${index} class=${lineClass(line)}>${line.text === '' ? '\u00a0' : line.text}</div>`)}
      </div>
      ${transcript.value !== null && html`<pre class="collab-fetched">${transcript.value}</pre>`}
      <footer class="collab-compose">
        ${control
          ? html`
            <textarea
              rows=${2}
              placeholder="Steer the session… (Enter to send, Shift+Enter for newline)"
              value=${promptDraft.value}
              onInput=${(e: Event) => { promptDraft.value = (e.target as HTMLTextAreaElement).value }}
              onKeyDown=${(e: KeyboardEvent) => {
                if (e.key === 'Enter' && !e.shiftKey) {
                  e.preventDefault()
                  sendPrompt()
                }
              }}
            />
            <div class="collab-actions">
              <button type="button" onClick=${sendPrompt} disabled=${statusKind !== 'open'}>Send</button>
              <button type="button" onClick=${sendAbort} disabled=${statusKind !== 'open'}>Abort turn</button>
              <button type="button" onClick=${fetchTranscript} disabled=${statusKind !== 'open'}>Fetch transcript</button>
            </div>`
          : html`<div class="collab-readonly">View-only link — you are watching. Steering needs a control link from the host.</div>`}
      </footer>
    </div>
  `
}

/**
 * Mount the standalone viewer when `hash` carries a share link. Returns true
 * when it mounted (caller skips the operator shell), false otherwise. The
 * fragment is parsed in place and never written anywhere else.
 */
export function mountCollabViewer(root: Element, hash: string): boolean {
  const body = hash.startsWith('#') ? hash.slice(1) : hash
  if (body === '') return false
  const parsed = parseCollabLink(body)
  if (!isParsedCollabLink(parsed)) return false
  document.title = 'Shared session — MASC'
  render(html`<${CollabViewer} link=${parsed} />`, root)
  return true
}
