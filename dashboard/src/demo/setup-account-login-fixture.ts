import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import { html } from 'htm/preact'
import { render } from 'preact'
import { useState } from 'preact/hooks'
import { RuntimeSetupPicker } from '../components/runtime-setup-picker'
const inventory = { source_revision: 'fixture-source', setup_revision: 'fixture-revision', runtimes: [], integrations: [
  { id: 'codex', display_name: 'Codex', protocol: 'codex-app-server', setup_support: 'new_connection' },
  { id: 'claude', display_name: 'Claude', protocol: 'claude-code', setup_support: 'new_connection' },
  { id: 'antigravity', display_name: 'Antigravity', protocol: 'antigravity-cli', setup_support: 'new_connection' },
  { id: 'muse', display_name: 'Muse', protocol: 'muse-serve', setup_support: 'new_connection' },
] }
function Fixture() {
  const [saved, setSaved] = useState(false)
  return html`<main style="max-width: 960px; margin: auto; padding: 20px;">
    <h1>공식 클라이언트 로그인</h1><p>브라우저 상호작용 테스트 · 모의 인증 서버</p>
    <${RuntimeSetupPicker} inventory=${inventory} onSaved=${() => setSaved(true)} />
    ${saved ? html`<p role="status">테스트 설정 저장 확인</p>` : null}
  </main>`
}
const root = document.getElementById('app')
if (root) render(html`<${Fixture} />`, root)
