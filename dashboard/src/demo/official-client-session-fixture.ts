import '../styles/ds-theme-tokens.css'
import '../styles/global.css'

import { html } from 'htm/preact'
import { render } from 'preact'
import { OfficialClientSessionPanel } from '../components/official-client-session-panel'
import { OfficialClientLoginProbe } from '../components/official-client-login-probe'
import { keepers } from '../store'

keepers.value = [
  { name: 'sangsu', status: 'idle', runtime_id: 'codex.codex' },
]

function OfficialClientSessionFixture() {
  return html`
    <main class="min-h-screen px-5 py-6" style="background: var(--color-bg-page);">
      <section class="mx-auto max-w-[1180px]">
        <header class="mb-5">
          <div class="text-2xs uppercase tracking-[0.16em] text-[var(--color-accent-fg)]">
            MASC Runtime Control
          </div>
          <h1 class="mt-1 text-xl font-semibold text-[var(--color-fg-primary)]">
            공식 클라이언트 세션 운영
          </h1>
          <p class="mt-1 text-xs text-[var(--color-fg-muted)]">
            실제 claim phase와 recovery fence를 확인한 뒤 명시적으로 해소합니다.
          </p>
        </header>
        <div class="flex flex-col gap-4">
          <article class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]/40 p-4">
            <div class="text-sm font-semibold text-[var(--color-fg-primary)]">codex.codex</div>
            <div class="text-xs text-[var(--color-fg-muted)]">Codex · gpt-5.3-codex-spark · 128k context</div>
            <${OfficialClientLoginProbe}
              runtimeId="codex.codex"
              configuredModel="gpt-5.3-codex-spark"
            />
          </article>
          <${OfficialClientSessionPanel} />
        </div>
      </section>
    </main>
  `
}

const root = document.getElementById('app')
if (root) render(html`<${OfficialClientSessionFixture} />`, root)
