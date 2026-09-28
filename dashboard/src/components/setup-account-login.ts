import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { Source } from '../api/runtime-setup'
import { streamSetupLogin, sendLoginInput, cancelSetupLogin, fetchLoginReceipt, type LoginInput } from '../api/setup-login'

// Only the currently visible terminal tail is retained. No output or code is persisted.
const visibleTerminalCharacters = 65536
function terminalText(value: string): string {
  return value.replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, '').replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
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
export function SetupAccountLogin({ integrationId, selected, busy = false, onStart, onBusy, onAccount, onComplete }: {
  integrationId: string; selected: Source | null; busy?: boolean; onStart: () => void;
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
  const [output, setOutput] = useState('')
  const [notice, setNotice] = useState('')
  const storageKey = `masc.setup.login.${integrationId}`
  useEffect(() => {
    alive.current = true
    const previous = recoveryStorage(storageKey, 'read')
    if (previous && /^[a-f0-9]{64}$/.test(previous)) { session.current = previous; setLoginId(previous) }
    return () => { alive.current = false; active.current?.stream.abort(); active.current?.controller.abort() }
  }, [storageKey])
  function current(operation: Operation) { return alive.current && active.current === operation }
  function begin(invalidate: boolean): Operation | null {
    if (busy || active.current) return null
    const operation = { controller: new AbortController(), stream: new AbortController() }
    active.current = operation; setWorking(true); onBusy(true); if (invalidate) onStart()
    return operation
  }
  function finish(operation: Operation) {
    if (!current(operation)) return
    active.current = null; inputPending.current = false
    setWorking(false); setRunning(false); setCode(''); setPending(false); onBusy(false)
  }
  function retain(source: Source) { setRecovered(source); onAccount(source) }
  async function readReceipt(operation: Operation, id: string, resumeLogin = false) {
    const receipt = await fetchLoginReceipt(id, integrationId, operation.controller.signal)
    if (!current(operation)) return
    const changed = receipt.account_ref !== undefined && receipt.account_ref !== (selected ?? recovered)?.account_ref
    if (changed && !resumeLogin) onStart()
    if (receipt.account_ref) retain({ integration_id: integrationId, account_ref: receipt.account_ref })
    if (receipt.status === 'complete' && receipt.account_ref) {
      setNotice('로그인 절차가 완료되었습니다. 모델의 응답과 도구 호출은 저장할 때 검증합니다.')
      if (changed || resumeLogin) await onComplete({ integration_id: integrationId, account_ref: receipt.account_ref })
    } else setNotice(receipt.status === 'running' ? '로그인 종료 여부를 아직 확인하지 못했습니다. 잠시 후 상태를 다시 확인하세요.'
      : '로그인이 중단되었습니다. 저장된 계정이 있으면 이 계정으로 다시 로그인하거나 모델 목록을 확인할 수 있습니다.')
  }
  async function recover() {
    const id = session.current
    if (!id) return
    const operation = begin(false)
    if (!operation) return
    try { await readReceipt(operation, id) }
    catch { if (current(operation)) setNotice('로그인 결과를 확인하지 못했습니다. 상태를 다시 확인하세요.') }
    finally { finish(operation) }
  }
  async function login(existing: Source | null) {
    const operation = begin(true)
    if (!operation) return
    setOutput(''); setCode(''); setNotice('공식 클라이언트의 로그인 안내를 기다리고 있습니다.')
    setLoginId(null); session.current = null; setRecovered(null); setRunning(true); setPending(false)
    recoveryStorage(storageKey, 'remove')
    let completed: Source | null = null
    try {
      await streamSetupLogin(existing ?? { integration_id: integrationId }, event => {
        if (!current(operation)) return
        if (event.event === 'started') {
          session.current = event.login_id; setLoginId(event.login_id)
          recoveryStorage(storageKey, 'write', event.login_id)
          if (event.account_ref) retain({ integration_id: integrationId, account_ref: event.account_ref })
        } else if (event.event === 'output') setOutput(value => (value + event.text).slice(-visibleTerminalCharacters))
        else if (event.event === 'input_ready') { inputPending.current = false; setPending(false) }
        else if (event.event === 'complete') {
          completed = event.source; retain(event.source); setRunning(false)
          setNotice(event.authentication === 'authenticated'
            ? '계정 인증을 확인했습니다. 모델의 응답과 도구 호출은 저장할 때 검증합니다.'
            : '로그인 자료를 받았습니다. 모델의 응답과 도구 호출은 저장할 때 검증합니다.')
        } else {
          if (event.login_id) {
            session.current = event.login_id; setLoginId(event.login_id)
            recoveryStorage(storageKey, 'write', event.login_id)
          }
          if (event.source) retain(event.source)
          setRunning(false); setNotice('로그인 절차를 완료하지 못했습니다. 상태를 다시 확인하거나 재시도하세요.')
        }
      }, operation.stream.signal)
      if (current(operation) && completed) await onComplete(completed)
    } catch {
      if (current(operation)) {
        setRunning(false)
        const id = session.current
        try {
          if (id) await readReceipt(operation, id, true)
          else setNotice('로그인을 시작하지 못했습니다. 설치와 서버 연결을 확인하고 다시 시도하세요.')
        } catch { if (current(operation)) setNotice('로그인 결과를 확인하지 못했습니다. 상태를 다시 확인하세요.') }
      }
    } finally { finish(operation) }
  }
  async function input(value: LoginInput) {
    const operation = active.current
    const id = session.current
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
    const id = session.current
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
      ${loginId && !running ? html`<button type="button" class="btn" disabled=${disabled} onClick=${recover}>로그인 상태 다시 확인</button>` : null}</div>
    ${output ? html`<pre class="setup-login-output" aria-label="로그인 안내">${terminalText(output)}</pre>` : null}
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
