import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { Inventory } from '../api/onboarding'
import { discoverSetupModels, prepareSetupModel, saveSetupSelections, type Model, type Selection, type Source } from '../api/runtime-setup'
import { resumeSavedModelSetup } from '../lib/model-setup-resume'
export function RuntimeSetupPicker({ inventory, onSaved }: { inventory: Inventory; onSaved: () => void }) {
  const [provider, setProvider] = useState('')
  const [endpoint, setEndpoint] = useState('')
  const [key, setKey] = useState('')
  const [source, setSource] = useState<Source | null>(null)
  const [discoveryRevision, setDiscoveryRevision] = useState<string | null>(null)
  const [models, setModels] = useState<Model[]>([])
  const [marked, setMarked] = useState<string[]>([])
  const [choices, setChoices] = useState<Selection[]>([])
  const [selectionRevision, setSelectionRevision] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const integrations = inventory.integrations ?? []
  const integration = integrations.find(row => row.id === provider)
  const http = integration && ['openai-compatible-http', 'messages-http', 'ollama-http'].includes(integration.protocol ?? '')
  const client = integration && (['codex-app-server', 'claude-code'].includes(integration.protocol ?? '')
    || (integration.protocol === 'antigravity-cli' && integration.credential_kind === 'file'))
  function invalidateDiscovery() { setModels([]); setMarked([]); setSource(null); setDiscoveryRevision(null) }
  function chooseProvider(id: string) { setProvider(id); setEndpoint(''); setKey(''); invalidateDiscovery(); setNotice('') }
  function editEndpoint(value: string) { setEndpoint(value); invalidateDiscovery() }
  function editKey(value: string) { setKey(value); invalidateDiscovery() }
  async function discover() {
    if (busy || !integration || (!http && !client)) return
    setBusy(true); setNotice('')
    const revision = inventory.setup_revision ?? null
    const selected: Source = { integration_id: integration.id, ...(http ? { endpoint: integration.endpoint ?? endpoint } : {}), ...(http && key ? { api_key: key } : {}) }
    try { setModels(await discoverSetupModels(selected)); setSource(selected); setDiscoveryRevision(revision); setMarked([]) }
    catch { setModels([]); setSource(null); setNotice(http ? '모델 목록을 확인하지 못했습니다. 서버 주소와 계정 키를 확인한 뒤 다시 시도하세요.' : '설치된 CLI와 로그인 상태를 확인한 뒤 모델 목록을 새로고침하세요.') }
    finally { setBusy(false) }
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
    if (busy || !source) return
    setBusy(true); setNotice('선택한 모델의 실행 환경을 확인하고 있습니다.')
    try {
      const prepared = await prepareSetupModel(source, model, integration?.protocol === 'ollama-http')
      setModels(current => current.map(row => row.id === prepared.id ? prepared : row)); setNotice('실행 context를 확인했습니다. 모델을 선택해 추가하세요.')
    } catch { setNotice('이 모델의 실행 context를 확인하지 못했습니다. 연결이나 모델 상태를 확인하고 목록을 새로고침하세요.') }
    finally { setBusy(false) }
  }
  async function save() {
    if (busy || !choices.length || !selectionRevision) return
    setBusy(true); setNotice('선택한 모델의 응답과 도구 호출을 검증하고 있습니다.')
    try { await saveSetupSelections(selectionRevision, choices) }
    catch {
      setNotice('연결 저장 결과를 확인하지 못했습니다. 준비 상태와 모델 목록을 새로고침하고 확인하세요.'); setBusy(false); return
    }
    setChoices([]); setSource(null); setKey(''); setModels([])
    try {
      const activation = await resumeSavedModelSetup()
      setNotice(activation.kind === 'active'
        ? '선택한 모델의 응답·도구 호출을 확인하고 저장했습니다. sandbox 안의 imp 실행은 별도로 확인해야 합니다.'
        : '모델 저장과 응답·도구 검증은 완료했습니다. 서버 설정 재개가 필요합니다. 아래 설정 재개 버튼으로 다시 시도하세요.')
      await onSaved()
    } catch { setNotice('모델 저장과 응답·도구 검증은 완료했습니다. 서버 준비 상태를 새로 확인하고 설정을 재개하세요.') }
    finally { setBusy(false) }
  }
  return html`<section class="runtime-setup-picker" aria-label="모델 연결 선택">
    <h4>모델 연결 선택</h4><p class="set-hint">여러 모델을 선택하세요. 첫 모델을 imp 기본 모델로 사용하며, 다음 모델은 표시 순서대로 대체 연결이 됩니다.</p>
    <fieldset disabled=${busy}><legend>기존 연결</legend>${inventory.runtimes.map(row => html`<label key=${row.id}><input type="checkbox"
      checked=${choices.some(choice => choice.kind === 'existing' && choice.id === row.id)} onChange=${() => toggleExisting(row.id, `${row.display_name} · ${row.model}`)} />${row.display_name} · ${row.model}</label>`)}</fieldset>
    <fieldset disabled=${busy}><legend>새 모델 추가</legend><label>공급자 <select value=${provider} onChange=${(event: Event) => chooseProvider((event.currentTarget as HTMLSelectElement).value)}>
      <option value="">공급자 선택</option>${integrations.map(row => html`<option key=${row.id} value=${row.id} disabled=${row.setup_support === 'unsupported'}>${row.display_name}${row.setup_support === 'unsupported' ? ' · 준비 중' : ''}</option>`)}</select></label>
      ${http ? html`${!integration?.endpoint ? html`<label>서버 API 주소 <input type="url" value=${endpoint} onInput=${(event: Event) => editEndpoint((event.currentTarget as HTMLInputElement).value)} /></label>` : null}
        <label>새 연결 API 키 <input type="password" autoComplete="off" value=${key} onInput=${(event: Event) => editKey((event.currentTarget as HTMLInputElement).value)} /></label>
        <p class="set-hint">기존 인증을 사용하려면 키를 비워 두세요.</p><button type="button" class="btn" onClick=${discover} disabled=${!integration?.endpoint && !endpoint}>모델 목록 확인</button>`
        : client ? html`<p class="set-hint">${integration?.protocol === 'claude-code' ? 'MASC의 Claude 모델 카탈로그에서 선택합니다.' : '선택한 CLI 계정의 모델 목록을 확인합니다.'} 계정 응답과 도구 사용은 저장할 때 검증합니다.</p><button type="button" class="btn" onClick=${discover}>모델 목록 확인</button>`
        : integration ? html`<p class="set-hint">이 CLI 계정은 터미널의 masc setup에서 로그인하고 모델을 선택하세요. 이미 선언한 연결은 위 목록에서 선택할 수 있습니다.</p>` : null}
      ${models.length ? html`<fieldset><legend>추가할 모델 · 여러 개 선택 가능</legend>${models.map(model => html`<div key=${model.id}><label><input type="checkbox"
        disabled=${model.context === null || model.tools === false} checked=${marked.includes(model.id)} onChange=${() => setMarked(current => current.includes(model.id) ? current.filter(id => id !== model.id) : [...current, model.id])} />
        ${model.label}${model.context === null ? ' · 실행 context 확인 필요' : ''}${model.tools === false ? ' · 도구 호출 미지원' : ''}</label>
        ${model.context === null && model.tools !== false ? html`<button type="button" class="btn" onClick=${() => prepare(model)}>이 모델만 준비</button>` : null}</div>`)}
        <button type="button" class="btn" disabled=${!marked.length} onClick=${addModels}>선택한 모델 추가</button></fieldset>` : null}</fieldset>
    ${choices.length ? html`<ol aria-label="기본 모델과 대체 순서">${choices.map((choice, index) => html`<li key=${index}><strong>${index === 0 ? '기본' : `대체 ${index}`}</strong> · ${choice.label}
      ${index > 0 ? html`<button type="button" disabled=${busy} onClick=${() => move(index, 0)}>기본으로 선택</button><button type="button" aria-label=${`${choice.label} 위로`} disabled=${busy} onClick=${() => move(index, index - 1)}>위로</button>` : null}
      <button type="button" disabled=${busy} onClick=${() => setChoices(current => current.filter((_, position) => position !== index))}>제거</button></li>`)}</ol>` : null}
    <button type="button" class="btn" disabled=${busy || !choices.length || !inventory.setup_revision} onClick=${save}>검증 후 선택 저장</button>${notice ? html`<p role="status">${notice}</p>` : null}
  </section>`
}
