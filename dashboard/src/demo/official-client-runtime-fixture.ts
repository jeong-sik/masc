import '../styles/ds-theme-tokens.css'
import '../styles/global.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { RuntimeMonitor } from '../components/runtime-monitor'

function OfficialClientRuntimeFixture() {
  return html`
    <main
      class="min-h-screen px-5 py-6"
      style="background: var(--color-bg-page);"
      data-official-client-runtime-fixture
    >
      <section class="mx-auto max-w-[1180px]">
        <header class="mb-5">
          <div class="text-2xs uppercase tracking-[0.16em] text-[var(--color-accent-fg)]">
            MASC Runtime Control
          </div>
          <h1 class="mt-1 text-xl font-semibold text-[var(--color-fg-primary)]">
            공식 구독 CLI 실측 증거
          </h1>
          <p class="mt-1 text-xs text-[var(--color-fg-muted)]">
            설정 상태와 이 서버 프로세스에서 관측된 실행 결과를 분리합니다.
          </p>
        </header>
        <${RuntimeMonitor} />
      </section>
    </main>
  `
}

const root = document.getElementById('app')
if (root) render(html`<${OfficialClientRuntimeFixture} />`, root)
