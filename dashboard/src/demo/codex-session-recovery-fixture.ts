import '../styles/ds-theme-tokens.css'
import '../styles/global.css'

import { html } from 'htm/preact'
import { render } from 'preact'
import { CodexSessionRecoveryPanel } from '../components/codex-session-recovery-panel'
import { keepers } from '../store'

keepers.value = [
  { name: 'sangsu', status: 'idle', runtime_id: 'codex.codex' },
]

function CodexSessionRecoveryFixture() {
  return html`
    <main class="min-h-screen px-5 py-6" style="background: var(--color-bg-page);">
      <section class="mx-auto max-w-[1180px]">
        <header class="mb-5">
          <div class="text-2xs uppercase tracking-[0.16em] text-[var(--color-accent-fg)]">
            MASC Runtime Control
          </div>
          <h1 class="mt-1 text-xl font-semibold text-[var(--color-fg-primary)]">
            Codex 공식 세션 복구
          </h1>
          <p class="mt-1 text-xs text-[var(--color-fg-muted)]">
            실제 claim phase와 recovery fence를 확인한 뒤 명시적으로 해소합니다.
          </p>
        </header>
        <${CodexSessionRecoveryPanel} />
      </section>
    </main>
  `
}

const root = document.getElementById('app')
if (root) render(html`<${CodexSessionRecoveryFixture} />`, root)
