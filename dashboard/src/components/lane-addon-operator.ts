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
  const current = useRef(true)
  const inFlight = useRef(false)
  const popup = useRef<Window | null>(null)
  const callback = useRef<AddonOperatorView['callback']>(undefined)
  const boundAuthority = useRef(authority)
  const pendingReturn = useRef<{ action: AddonOperatorAction; url: string; field: string; credentialRevision: number } | null>(null)
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
      popup.current?.close()
    }
  }, [])
  useEffect(() => subscribeStoredTokenChanges(() => {
    callback.current = undefined
    pendingReturn.current = null
    popup.current?.close(); popup.current = null
    setView(null); setInputs({}); setOpened(false); setError(null)
  }), [])

  function finish(success: boolean) {
    inFlight.current = false
    if (current.current) setBusy(false)
    const queued = pendingReturn.current
    if (!success || queued === null || !active(queued.credentialRevision)) return
    pendingReturn.current = null
    callback.current = undefined
    void invoke(queued.action, { [queued.field]: queued.url }, queued.url)
  }

  async function read() {
    if (!active() || inFlight.current) return
    const credentialRevision = currentStoredTokenRevision()
    inFlight.current = true; setBusy(true); setError(null)
    let success = false
    try {
      const result = await readAddonOperator(owner)
      if (active(credentialRevision)) { setView(result); callback.current = result?.callback; setOpened(true) }
      success = true
    } catch {
      if (active(credentialRevision)) setError('Private controls unavailable. Inspect this connection before another attempt.')
    } finally { finish(success) }
  }
  async function invoke(action: AddonOperatorAction, values: Record<string, string>, returnedUrl?: string) {
    if (!active() || inFlight.current) return
    const credentialRevision = currentStoredTokenRevision()
    inFlight.current = true; setBusy(true); setError(null); setInputs({})
    let success = false
    // Open synchronously with the operator gesture. Reuse this exact window
    // for the OAuth return, rather than trusting arbitrary same-origin messages.
    const nextPopup = returnedUrl === undefined && action.opens_window === true
      ? window.open('about:blank', '_blank', 'popup') : null
    if (nextPopup !== null) {
      popup.current?.close()
      popup.current = nextPopup
    }
    try {
      const result = await invokeAddonOperator(owner, action.id, { ...action.arguments, ...values })
      if (!active(credentialRevision)) { nextPopup?.close(); return }
      setView(result); callback.current = result.callback
      if (result.open_url !== undefined && nextPopup !== null) {
        nextPopup.location.replace(result.open_url)
      } else nextPopup?.close()
      success = true
    } catch {
      nextPopup?.close()
      if (active(credentialRevision)) {
        callback.current = undefined
        setView(null)
        setError('The operation outcome is unavailable. Inspect this connection before sending another request.')
      }
    } finally { finish(success) }
  }
  useEffect(() => {
    const receive = (event: MessageEvent) => {
      const pending = callback.current
      if (!active() || event.origin !== window.location.origin
        || event.source !== popup.current || pending === undefined) return
      const data: unknown = event.data
      if (typeof data !== 'object' || data === null || !('kind' in data) || !('url' in data)
        || data.kind !== 'masc-addon-oauth-callback' || typeof data.url !== 'string') return
      let returned: URL
      try { returned = new URL(data.url) } catch { return }
      if (returned.origin !== window.location.origin
        || returned.pathname !== '/addons/oauth/callback'
        || returned.searchParams.getAll('state').length !== 1
        || returned.searchParams.get('state') !== pending.state) return
      callback.current = undefined
      const action = { id: pending.action, label: '', arguments: pending.arguments, fields: [] }
      // The return page clears/closes immediately. Preserve an admitted return
      // in this original component's memory if Inspect is still in flight.
      pendingReturn.current = { action, url: data.url, field: pending.field,
        credentialRevision: currentStoredTokenRevision() }
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
    ${opened && !busy && view === null && !error && html`<p>No private controls are available for this Add-on.</p>`}
    ${view && html`<div class="space-y-2"><p>${view.message}</p>
      ${view.open_url !== undefined && html`<p>Complete the connection in the window that opened. If it did not open, cancel this attempt and allow popups before trying again.</p>`}
      ${view.actions.map(action => html`<form key=${action.id} class="space-y-2" onSubmit=${(event: Event) => {
        event.preventDefault()
        const values: Record<string, string> = {}
        for (const field of action.fields) values[field.name] = inputs[`${action.id}:${field.name}`] ?? ''
        void invoke(action, values)
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
