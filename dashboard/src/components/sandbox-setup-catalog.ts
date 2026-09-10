import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchSandboxCatalog, prepareSandbox, sandboxNames, type SandboxBackend, type NetworkMode, type SandboxCatalog, type SandboxCandidate } from '../api/sandbox-setup'

import { resumeSavedModelSetup } from '../lib/model-setup-resume'
import { bootKeeper } from '../api/keeper-lifecycle'

const networks: Record<NetworkMode, string> = { inherit: '인터넷 허용', none: '네트워크 차단', policy: '지정한 네트워크 정책' }

export function SandboxSetupCatalog() {
  const [catalog, setCatalog] = useState<SandboxCatalog | null>(null)
  const [advanced, setAdvanced] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [selected, setSelected] = useState<SandboxBackend | null>(null)
  const [network, setNetwork] = useState<NetworkMode>('inherit')
  const [notice, setNotice] = useState('')
  async function refresh() {
    setBusy(true); setError(''); setSelected(null)
    try { setCatalog(await fetchSandboxCatalog()) }
    catch { setCatalog(null); setError('sandbox 상태를 확인하지 못했습니다. 서버 연결과 sandbox 실행 도구의 상태를 확인한 뒤 다시 시도하세요.') }
    finally { setBusy(false) }
  }
  function chooseSandbox(row: SandboxCandidate) {
    const configured = catalog?.configured?.network
    const network = configured && row.networkModes.includes(configured)
      ? configured
      : row.networkModes.includes('inherit') ? 'inherit' : row.networkModes[0] ?? 'none'
    setSelected(row.id)
    setNetwork(network)
  }
  async function startImp() {
    if (busy || !catalog || !selected) return
    setBusy(true); setError(''); setNotice('선택한 sandbox 이미지를 다운로드·준비하고 설정을 저장합니다.')
    try { await prepareSandbox(catalog, selected, network) }
    catch { setNotice('sandbox 준비 결과를 확인하지 못했습니다. 상태를 새로고침하세요. 실행 중인 imp의 sandbox를 바꾸려면 먼저 imp를 중지해야 합니다. 사용자 지정 이미지는 선택한 실행 도구에 미리 준비해야 합니다.'); setBusy(false); return }
    setNotice('sandbox 이미지와 설정 준비를 완료했습니다. 모델 설정을 적용하고 imp를 시작합니다.')
    try {
      const resumed = await resumeSavedModelSetup()
      if (resumed.kind !== 'active') { setNotice('sandbox 준비·저장은 완료했습니다. 먼저 모델을 선택하고 계정 로그인·검증을 마친 뒤 다시 시작하세요.'); return }
      const boot = await bootKeeper('imp')
      setNotice(boot.ok
        ? `${boot.already_live === true ? '기존 imp가 계속 실행 중입니다.' : 'imp를 시작했습니다.'} 채팅에서 대화, Board·Task 작성, sandbox 파일 조회와 WebFetch를 확인하세요. 이 준비 단계는 모델·guest 도구 검증을 대신하지 않습니다.`
        : 'sandbox 준비·저장은 완료했지만 imp 시작을 확인하지 못했습니다. imp 상태와 모델·로그인을 확인한 뒤 다시 시작하세요.')
    } catch { setNotice('sandbox 준비·저장은 완료했습니다. 모델 설정과 imp 상태를 확인한 뒤 다시 시작하세요.') }
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
      ${row.state === 'service_ready' ? html`<button type="button" class="btn" disabled=${busy} onClick=${() => chooseSandbox(row)}>${sandboxNames[row.id]} 선택</button>` : null}
      ${row.networkModes.length ? html`<p class="set-hint">지원하는 guest 네트워크: ${row.networkModes.map(mode => networks[mode]).join(', ')}</p>` : null}</li>`)}</ul>
    ${selected ? html`<label>선택한 sandbox 네트워크 <select disabled=${busy} value=${network} onChange=${(event: Event) => setNetwork((event.currentTarget as HTMLSelectElement).value as NetworkMode)}>
      ${(catalog?.candidates.find(row => row.id === selected)?.networkModes ?? []).map(mode => html`<option value=${mode}>${networks[mode]}</option>`)}</select></label>
      <p>${sandboxNames[selected]} 이미지 준비에는 다운로드와 디스크 공간이 필요합니다.</p>
      <button type="button" class="btn" disabled=${busy || !catalog?.revision} onClick=${startImp}>sandbox 준비 후 imp 시작</button>` : null}
    ${notice ? html`<p role="status">${notice}</p>` : null}
    <p class="set-hint">guest 네트워크는 sandbox 명령에 적용됩니다. 모델 연결과 WebFetch는 별도의 서버 설정을 사용합니다. 서비스 설치가 필요하면 이 서버의 터미널에서 <code>masc setup</code>을 열어 위 선택지를 고르세요.</p>
  </section>`
}
