import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { invokeAddonOperator, readAddonOperator, type AddonOperatorView, type AddonOperatorAction } from '../api/lane-addon-operator'
import type { LaneAddonInstance } from '../api/lane-addons'
import { executionWorkspaceAuthority, shellAuthSummary, type ExecutionWorkspaceAuthority } from '../store'
import { currentStoredTokenRevision, subscribeStoredTokenChanges } from '../api/core'

const buttonClass = 'border border-[var(--border)] rounded px-2 py-1 cursor-pointer disabled:opacity-50'

/** Private UI state belongs to one mounted workspace/worker. It is never
 * published to the shared dashboard store, Ask, tool traces or URL. */
export function LaneAddonOperator({ instance, authority }: {
  instance: LaneAddonInstance; authority: ExecutionWorkspaceAuthority | null;
}) {
  const [opened, setOpened] = useState(false)
  const [view, setView] = useState<AddonOperatorView | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [inputs, setInputs] = useState<Record<string, string>>({})
  const [returnHeld, setReturnHeld] = useState(false)
  const current = useRef(true)
  const inFlight = useRef(false)
  const popup = useRef<Window | null>(null)
  const popupNavigated = useRef(false)
  const callback = useRef<AddonOperatorView['callback']>(undefined)
  const boundAuthority = useRef(authority)
  const pendingReturn = useRef<{ action: AddonOperatorAction; url: string; field: string; credentialRevision: number;
    source: Window | null; state: string; connectionId: string; receiptKind: 'captured' | 'declined';
    delivery: 'queued' | 'awaiting' | 'retry' | 'captured' } | null>(null)
  const owner = { instance_id: instance.instance_id, expected_incarnation: instance.incarnation }
  const available = authority !== null && executionWorkspaceAuthority.value === authority
    && instance.runtime_presence === 'live' && ['attached', 'observing'].includes(instance.phase.kind)
  const availableNow = useRef(available)
  availableNow.current = available
  const active = (credentialRevision = currentStoredTokenRevision()) => current.current && availableNow.current
    && boundAuthority.current === authority && executionWorkspaceAuthority.peek() === authority
    && credentialRevision === currentStoredTokenRevision()

  useEffect(() => {
    current.current = true
    return () => {
      current.current = false
      callback.current = undefined
      pendingReturn.current = null
      if (!popupNavigated.current) popup.current?.close()
      popup.current = null
      // A returned key stays in its original page until backend capture is
      // acknowledged. Unmount does not turn an uncertain handoff into loss.
    }
  }, [])
  useEffect(() => subscribeStoredTokenChanges(() => {
    callback.current = undefined
    pendingReturn.current = null
    if (!popupNavigated.current) popup.current?.close()
    popup.current = null
    setReturnHeld(false)
    setView(null); setInputs({}); setOpened(false); setError(null)
  }), [])

  function finish(success: boolean) {
    inFlight.current = false
    if (current.current) setBusy(false)
    const queued = pendingReturn.current
    if (!success || queued === null || queued.delivery !== 'queued' || !active(queued.credentialRevision)) return
    deliverReturn()
  }
  function sendCaptureAck() {
    const held = pendingReturn.current
    if (held === null || held.source === null || held.delivery !== 'captured' || !active(held.credentialRevision)) return
    try {
      held.source.postMessage({ kind: 'masc-addon-oauth-pending', state: held.state,
        connection_id: held.connectionId }, window.location.origin)
      held.source.postMessage({ kind: 'masc-addon-oauth-captured', state: held.state,
        connection_id: held.connectionId, receipt_kind: held.receiptKind }, window.location.origin)
    } catch {
      // The backend receipt remains true if the original page closed. Its
      // history/clear state is unobserved; no provider action is replayed.
    }
  }
  function acknowledgeCapture(result: AddonOperatorView | null) {
    const held = pendingReturn.current
    if (held === null || !active(held.credentialRevision)
      || result?.callback_receipt?.connection_id !== held.connectionId
      || result.callback_receipt.kind !== held.receiptKind) return false
    held.delivery = 'captured'
    setReturnHeld(false)
    if (held.source === null) {
      pendingReturn.current = null; callback.current = undefined; setInputs({})
    } else sendCaptureAck()
    return true
  }
  function deliverReturn() {
    const held = pendingReturn.current
    if (held === null || inFlight.current || !active(held.credentialRevision)) return
    if (held.delivery === 'captured') { sendCaptureAck(); return }
    held.delivery = 'awaiting'
    void invoke(held.action, { [held.field]: held.url }, held.url)
  }
  function submit(action: AddonOperatorAction, values: Record<string, string>) {
    const pending = callback.current
    if (pending !== undefined && action.id === pending.action
      && typeof values[pending.field] === 'string') {
      if (action.arguments.state !== pending.arguments.state
        || action.arguments.connection_id !== pending.arguments.connection_id) {
        setError('The connection form does not match the original pending attempt.'); return
      }
      if (pendingReturn.current !== null) { deliverReturn(); return }
      let returned: URL
      try { returned = new URL(values[pending.field]!) } catch {
        setError('The connection return is invalid. Keep the original return and inspect this attempt.'); return
      }
      if (returned.origin !== window.location.origin || returned.pathname !== '/addons/oauth/callback'
        || returned.searchParams.getAll('state').length !== 1 || returned.searchParams.get('state') !== pending.state
        || !pending.arguments.connection_id) {
        setError('The connection return does not match this original attempt.'); return
      }
      pendingReturn.current = { action, url: values[pending.field]!, field: pending.field,
        credentialRevision: currentStoredTokenRevision(), source: null, state: pending.state,
        connectionId: pending.arguments.connection_id, delivery: 'queued',
        receiptKind: returned.searchParams.get('error') === 'access_denied' ? 'declined' : 'captured' }
      setReturnHeld(true)
      deliverReturn()
    } else void invoke(action, values)
  }

  async function read() {
    if (!active() || inFlight.current) return
    const credentialRevision = currentStoredTokenRevision()
    inFlight.current = true; setBusy(true); setError(null)
    let success = false
    try {
      const result = await readAddonOperator(owner)
      if (active(credentialRevision)) {
        setView(result); callback.current = result?.callback; setOpened(true)
        if (!acknowledgeCapture(result)) {
          const held = pendingReturn.current
          if (held !== null && (result?.callback?.state !== held.state
            || result.callback.arguments.connection_id !== held.connectionId)) {
            held.delivery = 'retry'
            setError('The original connection return is still unconfirmed. Its window keeps the original return; it cannot be applied to another attempt.')
          }
        }
      }
      success = true
    } catch {
      if (active(credentialRevision)) setError('Private controls unavailable. Inspect this connection before another attempt.')
    } finally { finish(success) }
  }
  async function invoke(action: AddonOperatorAction, values: Record<string, string>, returnedUrl?: string) {
    if (!active() || inFlight.current) return
    if (returnedUrl === undefined && action.opens_window === true && pendingReturn.current !== null) {
      if (pendingReturn.current.delivery !== 'captured') {
        setError('Keep the original connection return open until its capture is confirmed.')
        return
      }
      // Confirmed storage releases the original return's dispatch ownership.
      // A missing page-cleared notification cannot block a later operation.
      pendingReturn.current = null
    }
    const credentialRevision = currentStoredTokenRevision()
    inFlight.current = true; setBusy(true); setError(null)
    if (returnedUrl === undefined) setInputs({})
    let success = false
    // Open synchronously with the operator gesture. Reuse this exact window
    // for the OAuth return, rather than trusting arbitrary same-origin messages.
    const nextPopup = returnedUrl === undefined && action.opens_window === true
      ? window.open('about:blank', '_blank', 'popup') : null
    if (nextPopup !== null) {
      if (!popupNavigated.current) popup.current?.close()
      popup.current = nextPopup
      popupNavigated.current = false
    }
    try {
      const result = await invokeAddonOperator(owner, action.id, { ...action.arguments, ...values })
      if (!active(credentialRevision)) { nextPopup?.close(); return }
      setView(result); callback.current = result.callback
      const acknowledged = acknowledgeCapture(result)
      if (returnedUrl !== undefined && !acknowledged) {
        if (pendingReturn.current !== null) pendingReturn.current.delivery = 'retry'
        setError('The connection return is not confirmed. Keep its window open, inspect the connection, or retry this same return.')
      } else if (!acknowledged) {
        const held = pendingReturn.current
        if (held !== null && held.delivery === 'queued' && (result.callback?.state !== held.state
          || result.callback.arguments.connection_id !== held.connectionId)) {
          held.delivery = 'retry'
          setError('The original connection return is still unconfirmed. Its window keeps the original return; it cannot be applied to another attempt.')
        }
      }
      if (result.open_url !== undefined && nextPopup !== null) {
        nextPopup.location.replace(result.open_url)
        popupNavigated.current = true
      } else nextPopup?.close()
      success = true
    } catch {
      nextPopup?.close()
      if (active(credentialRevision)) {
        if (returnedUrl !== undefined && pendingReturn.current !== null) {
          pendingReturn.current.delivery = 'retry'
          setError('The connection return is not confirmed. Keep its window open, inspect the connection, or retry this same return.')
        } else {
          callback.current = undefined
          setView(null)
          setError('The operation outcome is unavailable. Inspect this connection before sending another request.')
        }
      }
    } finally { finish(success) }
  }
  useEffect(() => {
    const receive = (event: MessageEvent) => {
      const pending = callback.current
      if (!active() || event.origin !== window.location.origin || event.source !== popup.current) return
      const data: unknown = event.data
      if (typeof data !== 'object' || data === null || !('kind' in data) || !('url' in data)
        || typeof data.url !== 'string') return
      const held = pendingReturn.current
      if (held !== null) {
        if (data.kind === 'masc-addon-oauth-cleared' && data.url === held.url && held.delivery === 'captured'
          && 'connection_id' in data && data.connection_id === held.connectionId) {
          pendingReturn.current = null; callback.current = undefined; popup.current = null
        } else if (data.kind === 'masc-addon-oauth-callback' && data.url === held.url
          && held.delivery !== 'awaiting') deliverReturn()
        return
      }
      if (data.kind !== 'masc-addon-oauth-callback' || pending === undefined) return
      let returned: URL
      try { returned = new URL(data.url) } catch { return }
      if (returned.origin !== window.location.origin
        || returned.pathname !== '/addons/oauth/callback'
        || returned.searchParams.getAll('state').length !== 1
        || returned.searchParams.get('state') !== pending.state) return
      const action = { id: pending.action, label: '', arguments: pending.arguments, fields: [] }
      const connectionId = pending.arguments.connection_id
      if (typeof connectionId !== 'string' || connectionId === '') return
      pendingReturn.current = { action, url: data.url, field: pending.field,
        credentialRevision: currentStoredTokenRevision(), source: event.source as Window,
        state: pending.state, connectionId, delivery: 'queued',
        receiptKind: returned.searchParams.get('error') === 'access_denied' ? 'declined' : 'captured' }
      setReturnHeld(true)
      ;(event.source as Window).postMessage({ kind: 'masc-addon-oauth-pending', state: pending.state,
        connection_id: connectionId }, window.location.origin)
      if (!inFlight.current) finish(true)
    }
    window.addEventListener('message', receive)
    return () => window.removeEventListener('message', receive)
  })

  if (shellAuthSummary.value?.effective_role !== 'admin' || !available || boundAuthority.current !== authority) return null
  return html`<section class="space-y-2" aria-label=${`Private controls for ${instance.title}`}>
    <button class=${buttonClass} disabled=${busy} type="button" onClick=${() => void read()}>${opened ? 'Inspect connection' : 'Connection settings'}</button>
    ${busy && html`<p role="status">Waiting for the connection…</p>`}
    ${error && html`<p role="alert">${error}</p>`}
    ${returnHeld && html`<button class=${buttonClass} disabled=${busy} type="button" onClick=${deliverReturn}>Retry original connection return</button>`}
    ${opened && !busy && view === null && !error && html`<p>No private controls are available for this Add-on.</p>`}
    ${view && html`<div class="space-y-2"><p>${view.message}</p>
      ${view.open_url !== undefined && html`<p>${view.callback !== undefined
        ? 'Complete the connection in the window that opened. If it did not open, cancel this attempt and allow popups before trying again.'
        : 'Continue in the requested app. If it did not open, allow popups and use the open action again. Confirm that you opened the app only after it appears.'}</p>`}
      ${view.actions.map(action => html`<form key=${`${action.id}:${action.arguments.operation_id ?? ''}`} class="space-y-2" onSubmit=${(event: Event) => {
        event.preventDefault()
        const values: Record<string, string> = {}
        for (const field of action.fields) values[field.name] = inputs[`${action.id}:${field.name}`] ?? ''
        submit(action, values)
      }}>
        ${action.fields.map(field => html`<label key=${field.name} class="block">${field.label}
          <input type=${field.secret ? 'password' : 'text'} autocomplete="off" spellcheck="false" required
            value=${inputs[`${action.id}:${field.name}`] ?? ''}
            onInput=${(event: Event) => setInputs({ ...inputs, [`${action.id}:${field.name}`]: (event.target as HTMLInputElement).value })} />
        </label>`)}
        <button type="submit" class=${buttonClass} disabled=${busy}>${action.label}</button>
      </form>`)}
    </div>`}
  </section>`
}
