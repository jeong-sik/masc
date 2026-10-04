import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { Inventory, RuntimeRow } from '../api/onboarding'
import type { Integration } from '../api/runtime-setup'
import { discoverSetupModels, selectSetupAccount, importAntigravityAccount, prepareSetupModel, saveSetupSelections, type Model, type Selection, type Source, type SaveOutcome } from '../api/runtime-setup'
import { SetupAccountLogin } from './setup-account-login'
import { resumeSavedModelSetup } from '../lib/model-setup-resume'
function ModelContextEntry({ model, onApply }: { model: Model; onApply: (context: number) => void }) {
  const [draft, setDraft] = useState('')
  const context = Number(draft)
  const valid = Number.isSafeInteger(context) && context > 0
  return html`<div class="setup-model-context">
    <p class="set-hint">공식 모델 문서에서 확인한 context 크기(tokens)를 입력하세요. 모델 응답과 도구 호출은 저장할 때 검증합니다.</p>
    <label>${model.label} context (tokens) <input type="number" min="1" step="1" value=${draft}
      onInput=${(event: Event) => setDraft((event.currentTarget as HTMLInputElement).value)} /></label>
    <button type="button" class="btn" disabled=${!valid} onClick=${() => { if (valid) onApply(context) }}>context 적용</button>
  </div>`
}
export function RuntimeSetupPicker({ inventory, onSaved, disabled = false, onBusyChange }: {
  inventory: Inventory; onSaved: () => void; disabled?: boolean; onBusyChange?: (busy: boolean) => void
}) {
  const activeRequest = useRef<AbortController | null>(null)
  const alive = useRef(true)
  const loginPending = useRef(false)
  useEffect(() => { alive.current = true; return () => { alive.current = false; activeRequest.current?.abort() } }, [])
  function beginRequest() { const controller = new AbortController(); activeRequest.current = controller; return controller }
  function currentRequest(controller: AbortController) { return alive.current && activeRequest.current === controller }
  function endRequest(controller: AbortController) {
    if (currentRequest(controller)) { activeRequest.current = null; setBusy(false) }
  }
  function loginActivity(value: boolean) { loginPending.current = value; setLoginBusy(value) }
  const [provider, setProvider] = useState('')
  const [endpoint, setEndpoint] = useState('')
  const [key, setKey] = useState('')
  const [selectedAccount, setSelectedAccount] = useState<Source | null>(null)
  const [source, setSource] = useState<Source | null>(null)
  const [discoveryRevision, setDiscoveryRevision] = useState<string | null>(null)
  const [models, setModels] = useState<Model[]>([])
  const [marked, setMarked] = useState<string[]>([])
  const [choices, setChoices] = useState<Selection[]>([])
  const [selectionRevision, setSelectionRevision] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [loginBusy, setLoginBusy] = useState(false)
  const [notice, setNotice] = useState('')
  useEffect(() => {
    onBusyChange?.(busy || loginBusy)
    return () => onBusyChange?.(false)
  }, [busy, loginBusy, onBusyChange])
  const integrations = inventory.integrations ?? []
  const selectable = (row: Integration) => row.enabled !== false && row.setup_support !== 'unsupported'
  const groupFor = (id: string) => inventory.account_groups?.find(group => group.integration_ids.includes(id))
  const visibleIntegrations = integrations.filter(row => {
    const group = groupFor(row.id)
    if (!group) return true
    const members = integrations.filter(member => group.integration_ids.includes(member.id))
    const representative = members.find(member => member.id === provider && selectable(member))
      ?? members.find(selectable) ?? members[0]
    return row.id === representative?.id
  })
  const accountLabel = (id: string, fallback: string, protocol: string | null) => {
    const group = groupFor(id)
    if (!group) return fallback
    const client = protocol === 'codex-app-server' ? 'Codex' : protocol === 'claude-code' ? 'Claude Code'
      : protocol === 'muse-serve' ? 'Muse Code' : protocol === 'antigravity-cli' ? 'Antigravity' : fallback
    return `${client} · ${group.id.slice(0, 8)} · 모델 설정 ${group.runtime_ids.length}개`
  }
  const runtimeLabel = (row: RuntimeRow) => `${accountLabel(row.provider_id, row.display_name, row.protocol)} · ${row.model}${row.max_context == null ? '' : ` · ${row.max_context.toLocaleString()} context`}`
  const integration = integrations.find(row => row.id === provider && selectable(row))
  const officialClient = integration && ['codex-app-server', 'claude-code', 'muse-serve', 'antigravity-cli'].includes(integration.protocol ?? '')
  const http = integration && ['openai-compatible-http', 'messages-http', 'ollama-http'].includes(integration.protocol ?? '')
  const documentedContext = integration?.protocol === 'codex-app-server' || integration?.protocol === 'claude-code'
  const client = integration && (['codex-app-server', 'claude-code', 'muse-serve'].includes(integration.protocol ?? '')
    || (integration.protocol === 'antigravity-cli' && (integration.credential_kind === 'file' || selectedAccount?.account_ref)))
  function invalidateDiscovery() { setModels([]); setMarked([]); setSource(null); setDiscoveryRevision(null) }
  function chooseProvider(id: string) { setSelectedAccount(null); setProvider(id); setEndpoint(''); setKey(''); invalidateDiscovery(); setNotice('') }
  function editEndpoint(value: string) { setEndpoint(value); invalidateDiscovery() }
  function editKey(value: string) { setKey(value); invalidateDiscovery() }
  async function importAccount() {
    if (disabled || busy || loginPending.current || activeRequest.current || integration?.protocol !== 'antigravity-cli') return
    const revision = inventory.setup_revision ?? null
    const controller = beginRequest()
    setBusy(true); invalidateDiscovery(); setNotice('이 MASC 서버의 로그인된 계정을 가져오고 있습니다.')
    try {
      const imported = await importAntigravityAccount(integration.id, { signal: controller.signal })
      if (!currentRequest(controller) || controller.signal.aborted) return
      setSelectedAccount(imported.source); setModels(imported.models); setSource(imported.source); setDiscoveryRevision(revision)
      setNotice(imported.models.length ? '계정을 가져왔습니다. 사용할 모델을 선택하세요. 응답·도구 검증은 저장할 때 진행합니다.' : '계정을 가져왔지만 모델 목록을 확인하지 못했습니다. CLI 로그인 상태를 확인한 뒤 다시 가져오세요.')
    } catch { if (currentRequest(controller)) setNotice(controller.signal.aborted ? '계정 가져오기 응답 대기를 취소했습니다. 계정 저장이 완료되었을 수 있으므로 상태를 다시 확인하세요.' : '계정을 가져오지 못했습니다. 이 MASC 서버의 터미널에서 masc setup으로 CLI 설치·로그인을 마친 뒤 다시 시도하세요.') }
    finally { endRequest(controller) }
  }
  async function discover() {
    if (disabled || busy || loginPending.current || activeRequest.current || !integration || (!http && !client)) return
    const controller = beginRequest()
    setBusy(true); setNotice('')
    const revision = inventory.setup_revision ?? null
    let selected: Source = { integration_id: integration.id, ...(http ? { endpoint: integration.endpoint ?? endpoint } : {}), ...(http && key ? { api_key: key } : {}) }
    try {
      if (selectedAccount?.integration_id === integration.id && selectedAccount.account_ref) selected = selectedAccount
      else if (integration.protocol !== 'antigravity-cli' && client) selected = await selectSetupAccount(integration.id, { signal: controller.signal })
      if (!currentRequest(controller) || controller.signal.aborted) return
      if (selected.account_ref) setSelectedAccount(selected)
      const discovered = await discoverSetupModels(selected, { signal: controller.signal })
      if (!currentRequest(controller) || controller.signal.aborted) return
      setModels(discovered); setSource(selected); setDiscoveryRevision(revision); setMarked([]) }
    catch { if (!currentRequest(controller)) return; invalidateDiscovery(); setNotice(controller.signal.aborted ? '모델 목록 응답 대기를 취소했습니다. 필요할 때 다시 확인하세요.' : http ? '모델 목록을 확인하지 못했습니다. 서버 주소와 계정 키를 확인한 뒤 다시 시도하세요.' : '설치된 CLI와 로그인 상태를 확인한 뒤 모델 목록을 새로고침하세요.') }
    finally { endRequest(controller) }
  }
  function replaceAccountChoices() {
    invalidateDiscovery(); setSelectedAccount(null); setNotice('')
    setChoices(current => current.filter(choice => choice.kind === 'new'
      ? choice.source.integration_id !== provider
      : !inventory.runtimes.some(row => row.id === choice.id && row.provider_id === provider)))
  }
  async function loggedIn(selected: Source) {
    if (!alive.current || activeRequest.current) return
    const revision = inventory.setup_revision ?? null
    const controller = beginRequest()
    setBusy(true); setSelectedAccount(selected); invalidateDiscovery()
    try {
      const discovered = await discoverSetupModels(selected, { signal: controller.signal })
      if (!currentRequest(controller) || controller.signal.aborted) return
      setSource(selected); setModels(discovered); setDiscoveryRevision(revision)
      setNotice('이 계정으로 모델 목록을 읽었습니다. 사용할 모델을 선택하세요.')
    } catch { if (currentRequest(controller)) setNotice('로그인 자료는 보존되었습니다. 이 계정의 모델 목록을 다시 확인하세요.') }
    finally { endRequest(controller) }
  }
  function addModels() {
    if (!source || !discoveryRevision) return
    if (choices.length && selectionRevision !== discoveryRevision) {
      setNotice('설정이 변경되었습니다. 기존 선택을 비우고 모델 목록을 새로 확인하세요.'); return
    }
    if (!choices.length) setSelectionRevision(discoveryRevision)
    const selected = models.filter(model => marked.includes(model.id) && model.context !== null && model.tools !== false)
    setChoices(current => [...current, ...selected.map(model => ({ kind: 'new' as const, source, model, label: `${integration?.display_name ?? provider} · ${model.label}` }))])
    setMarked([]); setKey(''); setSource(null); setModels([])
  }
  function toggleExisting(id: string, label: string) {
    if (!choices.length) setSelectionRevision(inventory.setup_revision ?? null)
    setChoices(current => current.some(choice => choice.kind === 'existing' && choice.id === id)
      ? current.filter(choice => choice.kind !== 'existing' || choice.id !== id) : [...current, { kind: 'existing', id, label }])
  }
  function move(index: number, to: number) {
    setChoices(current => { const result = [...current]; const [choice] = result.splice(index, 1); if (choice) result.splice(to, 0, choice); return result })
  }
  async function prepare(model: Model) {
    if (disabled || busy || loginPending.current || activeRequest.current || !source) return
    const controller = beginRequest()
    setBusy(true); setNotice('선택한 모델의 실행 환경을 확인하고 있습니다.')
    try {
      const prepared = await prepareSetupModel(source, model, integration?.protocol === 'ollama-http', { signal: controller.signal })
      if (!currentRequest(controller) || controller.signal.aborted) return
      setModels(current => current.map(row => row.id === prepared.id ? prepared : row)); setNotice('실행 context를 확인했습니다. 모델을 선택해 추가하세요.')
    } catch { if (currentRequest(controller)) setNotice(controller.signal.aborted ? '모델 준비 응답 대기를 취소했습니다. 모델이 로드되었을 수 있으므로 상태를 다시 확인하세요.' : '이 모델의 실행 context를 확인하지 못했습니다. 연결이나 모델 상태를 확인하고 목록을 새로고침하세요.') }
    finally { endRequest(controller) }
  }
  async function save() {
    if (disabled || busy || loginPending.current || activeRequest.current || !choices.length || !selectionRevision) return
    const controller = beginRequest()
    setBusy(true); setNotice('선택한 모델의 응답과 도구 호출을 검증하고 있습니다.')
    let outcome: SaveOutcome
    try { outcome = await saveSetupSelections(selectionRevision, choices, { signal: controller.signal }) }
    catch {
      if (!currentRequest(controller)) return
      setNotice('연결 저장 결과를 확인하지 못했습니다. 준비 상태와 모델 목록을 새로고침하고 확인하세요.'); endRequest(controller); return
    }
    if (!currentRequest(controller) || controller.signal.aborted) { endRequest(controller); return }
    setChoices([]); setSource(null); setKey(''); setModels([])
    // A save whose provider declined the check for the account's usage is
    // published unmeasured; every notice below says so instead of "verified".
    // A save that left selected runtimes uncalled says so too: they were kept
    // as they were, not verified again.
    const caveats = [
      ...outcome.durability === 'durable' ? [] : ['설정은 현재 적용됐지만 디스크 저장 내구성을 확인하지 못했습니다. 재저장하지 말고 저장소 상태를 확인하세요.'],
      ...outcome.lockReleaseUnconfirmed ? ['설정은 저장됐지만 설정 잠금 해제를 확인하지 못했습니다. 재저장하지 말고 서버의 잠금 상태를 확인하세요.'] : [],
      ...outcome.notRechecked.length === 0 ? [] : [`기존 연결은 이번에 다시 확인하지 않았습니다: ${outcome.notRechecked.join(', ')}.`],
      ...outcome.unverified.length === 0 ? [] : [`사용 한도에 걸려 응답·도구 검증은 못 했습니다: ${outcome.unverified.map(row => `${row.runtime_id} (${row.code})`).join(', ')}.`],
    ]
    const unmeasured = caveats.length === 0 ? null : `모델은 저장했습니다. ${caveats.join(' ')}`
    try {
      const activation = await resumeSavedModelSetup({ signal: controller.signal })
      if (!currentRequest(controller)) return
      if (controller.signal.aborted) {
        setNotice(`${unmeasured ?? '모델 저장과 검증은 완료했습니다.'} 설정 적용 응답 대기를 취소했습니다. 준비 상태를 확인하거나 설정을 재개하세요.`); return
      }
      setNotice(activation.kind === 'active'
        ? `${unmeasured ?? '선택한 모델의 응답·도구 호출을 확인하고 저장했습니다.'} sandbox 안의 imp 실행은 별도로 확인해야 합니다.`
        : `${unmeasured ?? '모델 저장과 응답·도구 검증은 완료했습니다.'} 서버 설정 재개가 필요합니다. 아래 설정 재개 버튼으로 다시 시도하세요.`)
      await onSaved()
    } catch { if (currentRequest(controller)) setNotice(`${unmeasured ?? '모델 저장과 응답·도구 검증은 완료했습니다.'} 서버 준비 상태를 새로 확인하고 설정을 재개하세요.`) }
    finally { endRequest(controller) }
  }
  return html`<section class="runtime-setup-picker" aria-label="모델 연결 선택">
    <h4>모델 연결 선택</h4><p class="set-hint">여러 모델을 선택하세요. 첫 모델을 imp 기본 모델로 사용하며, 다음 모델은 표시 순서대로 대체 연결이 됩니다.</p>
    <fieldset disabled=${disabled || busy || loginBusy}><legend>기존 연결</legend>${inventory.runtimes.map(row => html`<label key=${row.id} class="v2-mobile-operator-target"><input type="checkbox"
      checked=${choices.some(choice => choice.kind === 'existing' && choice.id === row.id)} onChange=${() => toggleExisting(row.id, runtimeLabel(row))} />${runtimeLabel(row)}</label>`)}</fieldset>
    <fieldset disabled=${disabled || busy || loginBusy}><legend>새 모델 추가</legend><label>공급자 <select value=${integration && visibleIntegrations.some(row => row.id === provider) ? provider : ''} onChange=${(event: Event) => chooseProvider((event.currentTarget as HTMLSelectElement).value)}>
      <option value="">공급자 선택</option>${visibleIntegrations.map(row => html`<option key=${row.id} value=${row.id} disabled=${!selectable(row)}>${accountLabel(row.id, row.display_name, row.protocol)}${row.enabled === false ? ' · 비활성' : row.setup_support === 'unsupported' ? ' · 준비 중' : ''}</option>`)}</select></label>
      ${http ? html`${!integration?.endpoint ? html`<label>서버 API 주소 <input type="url" value=${endpoint} onInput=${(event: Event) => editEndpoint((event.currentTarget as HTMLInputElement).value)} /></label>` : null}
        <label>새 연결 API 키 <input type="password" autoComplete="off" value=${key} onInput=${(event: Event) => editKey((event.currentTarget as HTMLInputElement).value)} /></label>
        <p class="set-hint">기존 인증을 사용하려면 키를 비워 두세요.</p><button type="button" class="btn" onClick=${discover} disabled=${!integration?.endpoint && !endpoint}>모델 목록 확인</button>`
        : client ? html`<p class="set-hint">${integration?.protocol === 'claude-code' ? 'MASC의 Claude 모델 카탈로그에서 선택합니다.' : '서버에 선언된 계정 또는 CLI 기본 계정을 선택하여 모델 목록을 확인합니다.'} 계정 응답과 도구 사용은 저장할 때 검증합니다.</p><button type="button" class="btn" onClick=${discover}>${selectedAccount?.account_ref ? '선택한 계정 모델 목록 새로고침' : '서버 계정 선택 후 모델 목록 확인'}</button>`
        : integration?.protocol === 'antigravity-cli' ? html`<p class="set-hint">아래에서 Antigravity 새 계정에 로그인하거나 서버에 이미 로그인된 계정을 가져오세요. 모델 선택과 검증은 이 화면에서 이어갑니다.</p>`
        : integration ? html`<p class="set-hint">이 CLI 계정은 터미널의 masc setup에서 로그인하고 모델을 선택하세요. 이미 선언한 연결은 위 목록에서 선택할 수 있습니다.</p>` : null}
      ${integration?.protocol === 'antigravity-cli' ? html`<p class="set-hint">브라우저 계정이 아니라 이 MASC 서버에 로그인된 Antigravity 계정을 사용합니다.</p><button type="button" class="btn" onClick=${importAccount}>서버의 로그인된 Antigravity 계정 사용</button>` : null}
      ${models.length ? html`<fieldset><legend>추가할 모델 · 여러 개 선택 가능</legend>${models.map(model => html`<div key=${model.id}><label class="v2-mobile-operator-target"><input type="checkbox"
        disabled=${model.context === null || model.tools === false} checked=${marked.includes(model.id)} onChange=${() => setMarked(current => current.includes(model.id) ? current.filter(id => id !== model.id) : [...current, model.id])} />
        ${model.label}${model.source?.startsWith('muse_') ? ` · ${model.source.slice(5)} 카탈로그 (응답 미검증)` : ''}${model.context === null ? ' · 실행 context 확인 필요' : ''}${model.tools === false ? ' · 도구 호출 미지원' : ''}</label>
        ${model.default_reasoning_effort !== undefined ? html`<p class="set-hint">추론 노력 · 기본: ${model.default_reasoning_effort} · 지원: ${model.supported_reasoning_efforts?.join(', ') || '보고된 선택지 없음'}</p>` : null}
        ${model.context === null && model.tools !== false ? documentedContext
          ? html`<${ModelContextEntry} model=${model} onApply=${(context: number) => {
              setModels(current => current.map(row => row.id === model.id ? { ...row, context } : row))
              setNotice(`${model.label} context를 ${context} tokens로 설정했습니다. 저장 시 모델 응답과 도구 호출을 검증합니다.`)
            }} />`
          : integration?.protocol === 'muse-serve'
            ? html`<p class="set-hint">Muse가 이 모델의 context를 보고하지 않았습니다. CLI 모델 카탈로그를 확인한 뒤 선택한 계정의 모델 목록을 새로고침하세요.</p>`
            : html`<button type="button" class="btn" onClick=${() => prepare(model)}>이 모델만 준비</button>`
          : null}</div>`)}
        <button type="button" class="btn" disabled=${!marked.length} onClick=${addModels}>선택한 모델 추가</button></fieldset>` : null}</fieldset>
    ${officialClient ? html`<${SetupAccountLogin} key=${integration.id} integrationId=${integration.id} selected=${selectedAccount} busy=${disabled || busy}
      onReplaceAccount=${replaceAccountChoices} onBusy=${loginActivity} onAccount=${setSelectedAccount} onComplete=${loggedIn} />` : null}
    ${choices.length ? html`<ol aria-label="기본 모델과 대체 순서">${choices.map((choice, index) => html`<li key=${index}><strong>${index === 0 ? '기본' : `대체 ${index}`}</strong> · ${choice.label}
      ${index > 0 ? html`<button type="button" disabled=${disabled || busy || loginBusy} onClick=${() => move(index, 0)}>기본으로 선택</button><button type="button" aria-label=${`${choice.label} 위로`} disabled=${disabled || busy || loginBusy} onClick=${() => move(index, index - 1)}>위로</button>` : null}
      <button type="button" disabled=${disabled || busy || loginBusy} onClick=${() => setChoices(current => current.filter((_, position) => position !== index))}>제거</button></li>`)}</ol>` : null}
    ${busy && activeRequest.current ? html`<button type="button" class="btn" onClick=${() => activeRequest.current?.abort()}>요청 대기 취소</button><p class="set-hint">대기를 취소해도 이미 저장된 설정은 유지될 수 있습니다. 결과를 새로 확인하세요.</p>` : null}
    <button type="button" class="btn" disabled=${disabled || busy || loginBusy || !choices.length || !inventory.setup_revision} onClick=${save}>검증 후 선택 저장</button>${notice ? html`<p role="status">${notice}</p>` : null}
  </section>`
}
