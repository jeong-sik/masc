import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchSandboxCatalog, sandboxNames, type NetworkMode, type SandboxCatalog } from '../api/sandbox-setup'

const networks: Record<NetworkMode, string> = { inherit: '인터넷 허용', none: '네트워크 차단', policy: '지정한 네트워크 정책' }

export function SandboxSetupCatalog() {
  const [catalog, setCatalog] = useState<SandboxCatalog | null>(null)
  const [advanced, setAdvanced] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function refresh() {
    setBusy(true); setError('')
    try { setCatalog(await fetchSandboxCatalog()) }
    catch { setCatalog(null); setError('sandbox 상태를 확인하지 못했습니다. 서버 연결과 sandbox 실행 도구의 상태를 확인한 뒤 다시 시도하세요.') }
    finally { setBusy(false) }
  }
  useEffect(() => { void refresh() }, [])
  const candidates = (catalog?.candidates ?? []).filter(row => advanced || !row.advanced || row.configured)
    .sort((a, b) => Number(b.recommended) - Number(a.recommended))
  return html`<section aria-label="imp sandbox 선택지">
    <h4>imp sandbox</h4>
    <p class="set-hint">imp가 명령을 실행하고 파일을 살펴볼 공간입니다. 서비스가 감지되어도 실제 guest 실행은 별도 확인이 필요합니다.</p>
    ${catalog?.configured ? html`<p>현재 설정: <strong>${sandboxNames[catalog.configured.backend]}</strong> · ${networks[catalog.configured.network]}</p>` : null}
    ${catalog?.configurationError ? html`<p role="status">${catalog.configurationError}</p>` : null}
    <button type="button" class="btn" disabled=${busy} onClick=${refresh}>sandbox 상태 새로고침</button>
    <button type="button" class="btn" aria-expanded=${advanced} onClick=${() => setAdvanced(value => !value)}>${advanced ? '일반 선택지 보기' : '고급 선택지 보기'}</button>
    ${busy ? html`<p role="status">이 서버에서 사용할 수 있는 sandbox를 확인하고 있습니다.</p>` : null}
    ${error ? html`<p role="status">${error}</p>` : null}
    <ul>${candidates.map(row => html`<li key=${row.id}><strong>${sandboxNames[row.id]}</strong>${row.configured ? ' · 현재 설정' : ''}${row.recommended ? ' · 추천' : ''}
      <p>${row.state === 'service_ready' ? '서비스 감지됨 · guest 준비와 실행 확인 필요' : row.reason}</p>
      ${row.networkModes.length ? html`<p class="set-hint">지원하는 guest 네트워크: ${row.networkModes.map(mode => networks[mode]).join(', ')}</p>` : null}</li>`)}</ul>
    <p class="set-hint">guest 네트워크는 sandbox 명령에 적용됩니다. 모델 연결과 WebFetch는 별도의 서버 설정을 사용합니다. 설치나 첫 실행을 준비하려면 이 서버의 터미널에서 <code>masc setup</code>을 열어 위 선택지를 고르세요.</p>
  </section>`
}
