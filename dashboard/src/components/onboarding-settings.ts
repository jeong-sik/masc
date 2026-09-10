import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchSetupStatus, fetchSetupInventory, saveSetupCredential, type Status, type Inventory } from '../api/onboarding'

const labels = { satisfied: '확인됨', needs_setup: '설정 필요', needs_verification: '검증 필요', invalid: '설정 확인 필요' }

export function OnboardingSettings() {
  const [status, setStatus] = useState<Status | null>(null)
  const [inventory, setInventory] = useState<Inventory | null>(null)
  const [provider, setProvider] = useState('')
  const [secret, setSecret] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  async function refresh() {
    try {
      const current = await fetchSetupStatus()
      if (current.schema !== 'masc.onboarding_status.v1') throw new Error('invalid status')
      setStatus(current)
    } catch { setNotice('소유자로 로그인한 뒤 준비 상태를 다시 확인하세요.') }
    try {
      const available = await fetchSetupInventory()
      setInventory(available)
    } catch { setInventory(null) }
  }
  useEffect(() => { void refresh() }, [])
  async function save(event: Event) {
    event.preventDefault()
    if (busy || !provider || !secret.trim() || !inventory) return
    setBusy(true)
    const entered = secret
    setSecret('')
    try {
      await saveSetupCredential(provider, entered, inventory.source_revision)
      await refresh()
      setNotice('API 키를 비공개 파일에 저장하고 연결 설정에 적용했습니다. 모델 응답과 도구 검증은 아직 필요합니다.')
    } catch { setNotice('API 키를 적용하지 못했습니다. 연결 설정과 비공개 저장소 권한을 확인하세요.') }
    finally { setBusy(false) }
  }
  const providers = [...new Map((inventory?.runtimes ?? []).filter(row => typeof row.endpoint === 'string' && row.endpoint.length > 0).map(row => [row.provider_id, row])).values()]
  return html`<section class="set-card" aria-label="첫 대화 준비">
    <h3>첫 대화 준비</h3>
    <button type="button" class="btn" disabled=${busy} onClick=${refresh}>준비 상태 새로고침</button>
    ${status ? html`<p class="set-hint">작업 공간: ${status.base_path ?? '선택 필요'}<br />모델: ${status.selected_model ?? '선택 필요'}</p>
      <ul>${status.checks.map(check => html`<li key=${check.id}><strong>${labels[check.condition]}</strong> · ${check.message}</li>`)}</ul>` : html`<p>준비 상태를 확인하고 있습니다.</p>`}
    <form onSubmit=${save}>
      <p class="set-hint">현재 작업 공간에 선언된 HTTP 연결에 API 키를 적용합니다. CLI 계정 인증과 새 공급자 추가는 별도 연결 설정에서 진행하세요.</p>
      <label>연결 <select value=${provider} disabled=${busy} onChange=${(event: Event) => setProvider((event.currentTarget as HTMLSelectElement).value)}>
        <option value="">연결 선택</option>${providers.map(row => html`<option key=${row.provider_id} value=${row.provider_id}>${row.display_name}</option>`)}
      </select></label>
      <label>API 키 <input type="password" autoComplete="off" value=${secret} disabled=${busy} onInput=${(event: Event) => setSecret((event.currentTarget as HTMLInputElement).value)} /></label>
      <button class="btn" type="submit" disabled=${busy || !provider || !secret.trim()}>비공개로 저장</button>
    </form>
    ${notice ? html`<p role="status">${notice}</p>` : null}
  </section>`
}
