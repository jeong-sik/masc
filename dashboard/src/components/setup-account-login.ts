import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { Source } from '../api/runtime-setup'
import { streamSetupLogin, sendLoginInput, cancelSetupLogin, fetchLoginReceipt, type LoginInput } from '../api/setup-login'

// Only the currently visible terminal tail is retained. No output or code is persisted.
const visibleTerminalCharacters = 65536
function terminalText(value: string): string {
  // An OSC ends at BEL or at ST (ESC \); an ESC inside one ends it, so a match
  // never runs on into the text after it to a later ST.
  return value.replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '').replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '')
}
function recoveryStorage(key: string, action: 'read' | 'write' | 'remove', value?: string): string | null {
  try {
    if (action === 'read') return sessionStorage.getItem(key)
    if (action === 'write' && value !== undefined) sessionStorage.setItem(key, value)
    else if (action === 'remove') sessionStorage.removeItem(key)
  } catch { /* Recovery remains available in memory when browser storage is denied. */ }
  return null
}
type Operation = { controller: AbortController; stream: AbortController }
export function SetupAccountLogin({ integrationId, selected, busy = false, onReplaceAccount, onBusy, onAccount, onComplete }: {
  integrationId: string; selected: Source | null; busy?: boolean; onReplaceAccount: () => void;
  onBusy: (busy: boolean) => void; onAccount: (source: Source) => void; onComplete: (source: Source) => Promise<void> | void;
}) {
  const active = useRef<Operation | null>(null)
  const alive = useRef(true)
  const session = useRef<string | null>(null)
  const inputPending = useRef(false)
  const inputVersion = useRef(0)
  const [loginId, setLoginId] = useState<string | null>(null)
  const [recovered, setRecovered] = useState<Source | null>(null)
  const [working, setWorking] = useState(false)
  const [running, setRunning] = useState(false)
  const [pending, setPending] = useState(false)
  const [code, setCode] = useState('')
  // A screen replaces the one before and holds at most one terminal's rows;
  // printed text is the tail of what the client wrote so far.
  const [output, setOutput] = useState<{ readonly text: string; readonly screen: boolean }>({ text: '', screen: false })
  const [notice, setNotice] = useState('')
  const storageKey = `masc.setup.login.${integrationId}`
  useEffect(() => {
    alive.current = true
    const previous = recoveryStorage(storageKey, 'read')
    if (previous && /^[a-f0-9]{64}$/.test(previous)) { session.current = previous; setLoginId(previous) }
    return () => { alive.current = false; active.current?.stream.abort(); active.current?.controller.abort() }
  }, [storageKey])
  function current(operation: Operation) { return alive.current && active.current === operation }
  function begin(): Operation | null {
    if (busy || active.current) return null
    const operation = { controller: new AbortController(), stream: new AbortController() }
    active.current = operation; setWorking(true); onBusy(true)
    return operation
  }
  function finish(operation: Operation) {
    if (!current(operation)) return
    active.current = null; inputPending.current = false
    setWorking(false); setRunning(false); setCode(''); setPending(false); onBusy(false)
  }
  function retain(source: Source) { setRecovered(source); onAccount(source) }
  // A login ended with `source` as its account, however the result arrived.
  // An account here is its account_ref. The server gives a native home the
  // same ref each time it logs in, and an Antigravity login a new one every
  // time. The models chosen under a ref stand while that ref logs in again,
  // and are dropped when another ref takes its place. Answers whether the
  // ref changed.
  function settle(source: Source): boolean {
    const changed = source.account_ref !== selected?.account_ref
    if (changed) onReplaceAccount()
    retain(source)
    return changed
  }
  async function readReceipt(operation: Operation, id: string, resumeLogin = false) {
    const receipt = await fetchLoginReceipt(id, integrationId, operation.controller.signal)
    if (!current(operation)) return
    if (receipt.account_ref) setRecovered({ integration_id: integrationId, account_ref: receipt.account_ref })
    if (receipt.status === 'complete' && (receipt.account_ref || receipt.account === 'keyring_host')) {
      const source: Source = receipt.account_ref
        ? { integration_id: integrationId, account_ref: receipt.account_ref }
        : { integration_id: integrationId }
      const changed = settle(source)
      setNotice('로그인 절차가 완료되었습니다. 모델의 응답과 도구 호출은 저장할 때 검증합니다.')
      // `onComplete` reads the account's models. Another account always
      // needs that. The same one needs it when a login just ran, and not when
      // its result is only read again.
      if (changed || resumeLogin) await onComplete(source)
    } else setNotice(receipt.status === 'running' ? '로그인 종료 여부를 아직 확인하지 못했습니다. 잠시 후 상태를 다시 확인하세요.'
      : '로그인이 중단되었습니다. 현재 모델 선택은 유지됩니다. 로그인 상태를 다시 확인하거나 다시 로그인하세요.')
  }
  async function recover() {
    const id = session.current
    if (!id) return
    const operation = begin()
    if (!operation) return
    try { await readReceipt(operation, id) }
    catch { if (current(operation)) setNotice('로그인 결과를 확인하지 못했습니다. 상태를 다시 확인하세요.') }
    finally { finish(operation) }
  }
  async function login(existing: Source | null) {
    const operation = begin()
    if (!operation) return
    setOutput({ text: '', screen: false }); setCode(''); setNotice('공식 클라이언트의 로그인 안내를 기다리고 있습니다.')
    setLoginId(null); setRunning(true); setPending(false)
    let startedId: string | null = null
    let completed: Source | null = null
    try {
      await streamSetupLogin(existing ?? { integration_id: integrationId }, event => {
        if (!current(operation)) return
        if (event.event === 'started') {
          startedId = event.login_id
          session.current = event.login_id; setLoginId(event.login_id)
          recoveryStorage(storageKey, 'write', event.login_id)
          setRecovered(event.account_ref ? { integration_id: integrationId, account_ref: event.account_ref } : null)
        } else if (event.event === 'output') setOutput(value => ({ text: (value.text + event.text).slice(-visibleTerminalCharacters), screen: false }))
        else if (event.event === 'screen') setOutput({ text: event.text, screen: true })
        else if (event.event === 'input_ready') { inputPending.current = false; setPending(false) }
        else if (event.event === 'complete') {
          completed = event.source; settle(event.source); setRunning(false)
          setNotice(event.authentication === 'authenticated'
            ? '계정 인증을 확인했습니다. 모델의 응답과 도구 호출은 저장할 때 검증합니다.'
            : '로그인 자료를 받았습니다. 모델의 응답과 도구 호출은 저장할 때 검증합니다.')
        } else {
          if (event.login_id) {
            startedId = event.login_id
            session.current = event.login_id; setLoginId(event.login_id)
            recoveryStorage(storageKey, 'write', event.login_id)
          } else if (!startedId) setLoginId(session.current)
          if (event.source) setRecovered(event.source)
          setRunning(false); setNotice('로그인 절차를 완료하지 못했습니다. 상태를 다시 확인하거나 재시도하세요.')
        }
      }, operation.stream.signal)
      if (current(operation) && completed) await onComplete(completed)
    } catch {
      if (current(operation)) {
        setRunning(false)
        try {
          if (startedId) await readReceipt(operation, startedId, true)
          else {
            setLoginId(session.current)
            setNotice('로그인을 시작하지 못했습니다. 설치와 서버 연결을 확인하고 다시 시도하세요.')
          }
        } catch { if (current(operation)) setNotice('로그인 결과를 확인하지 못했습니다. 상태를 다시 확인하세요.') }
      }
    } finally { finish(operation) }
  }
  async function input(value: LoginInput) {
    const operation = active.current
    const id = loginId
    if (!operation || !id || inputPending.current || !running) return
    const version = ++inputVersion.current
    inputPending.current = true; setPending(true); setCode('')
    try { await sendLoginInput(id, value, operation.controller.signal) }
    catch {
      if (current(operation) && version === inputVersion.current) { inputPending.current = false; setPending(false); setNotice('입력을 전달하지 못했습니다. 로그인 상태를 확인하세요.') }
    }
  }
  async function cancel() {
    const operation = active.current
    const id = loginId
    if (!operation) return
    operation.stream.abort()
    try { if (id) await cancelSetupLogin(id) }
    catch { if (current(operation)) setNotice('취소 결과를 확인하지 못했습니다. 로그인 상태를 다시 확인하세요.') }
  }
  const existing = selected ?? recovered
  const disabled = busy || working
  return html`<section class="setup-account-login" aria-label="공식 클라이언트 로그인">
    <div class="setup-login-actions"><button type="button" class="btn" disabled=${disabled} onClick=${() => login(null)}>새 계정 로그인</button>
      ${existing?.account_ref ? html`<button type="button" class="btn" disabled=${disabled} onClick=${() => login(existing)}>선택한 계정 다시 로그인</button>` : null}
      ${selected?.account_ref && recovered?.account_ref && selected.account_ref !== recovered.account_ref ? html`<button type="button" class="btn" disabled=${disabled} onClick=${() => login(recovered)}>중단된 계정 다시 로그인</button>` : null}
      ${loginId && !running ? html`<button type="button" class="btn" disabled=${disabled} onClick=${recover}>로그인 상태 다시 확인</button>` : null}</div>
    ${output.text ? html`<pre class=${output.screen ? 'setup-login-output setup-login-screen' : 'setup-login-output'} aria-label="로그인 안내">${terminalText(output.text)}</pre>` : null}
    ${running ? html`<p>안내된 주소에서 로그인하세요. 브라우저가 코드를 돌려주면 아래에 붙여 넣으세요.</p>
      <form onSubmit=${(event: Event) => { event.preventDefault(); void input({ kind: 'text', text: code }) }}>
        <label>로그인 코드 <input type="password" autoComplete="off" value=${code} disabled=${pending || !loginId}
          onInput=${(event: Event) => setCode((event.currentTarget as HTMLInputElement).value)} /></label>
        <button type="submit" class="btn" disabled=${pending || !loginId || !code}>코드 전달</button></form>
      <div class="setup-login-actions">${(['enter', 'up', 'down', 'tab', 'eof'] as const).map((key, index) => html`<button type="button" class="btn" disabled=${pending || !loginId}
        onClick=${() => input({ kind: 'key', key })}>${['Enter', '위', '아래', 'Tab', '입력 종료 (Ctrl-D)'][index]}</button>`)}
      <button type="button" class="btn" onClick=${cancel}>로그인 취소</button></div>` : null}
    ${notice ? html`<p role="status">${notice}</p>` : null}
  </section>`
}
