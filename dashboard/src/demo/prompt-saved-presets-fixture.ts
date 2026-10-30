import { html } from 'htm/preact'
import { render } from 'preact'
import { PromptSavedPresetsPanel } from '../components/tools/prompt-saved-presets-panel'
import { hydrateExecutionSnapshot } from '../store'
import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/tokens.css'

// This page uses the real API module. Point Vite at an isolated candidate
// server through MASC_DASHBOARD_PROXY_TARGET; it does not mock write effects.
// The isolated preset adapter has no execution endpoint. This explicit fixture
// authority is only a client ownership scope, not live workspace verification.
hydrateExecutionSnapshot({ execution_publication_epoch: 'copied-presets-fixture', execution_publication_generation: 1,
  status: { workspace_root: '/fixture/copied-presets' } })
render(html`<main class="mx-auto max-w-4xl p-6">
  <h1 class="mb-2 text-lg font-semibold">저장 프리셋 · 후보 API 실측</h1>
  <p class="mb-4 text-xs">실측용 별도 화면입니다. 연결한 서버의 실제 저장본을 읽고 설정을 변경합니다.</p>
  <${PromptSavedPresetsPanel} />
</main>`, document.getElementById('app')!)
