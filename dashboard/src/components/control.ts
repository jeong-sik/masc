// MASC Dashboard — Operations Surface
// Conventional operator dashboard split: intervene + command + tools.

import { html } from 'htm/preact'
import { route, navigate } from '../router'
import { Ops } from './ops'
import { Tools } from './tools'
import { Command } from './command'

type OperationsSection = 'intervene' | 'command' | 'tools'

function currentSection(): OperationsSection {
  const section = route.value.params.section
  if (section === 'tools' || section === 'command') return section
  return 'intervene'
}

export function Operations() {
  const section = currentSection()

  return html`
    <div class="tab-unified grid gap-[var(--space-md,16px)]">
      <div class="tab-pill rounded-full-bar flex flex-wrap gap-1.5">
        <button
          class="tab-pill rounded-full ${section === 'intervene' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('operations', { section: 'intervene' })}
        >
          개입
        </button>
        <button
          class="tab-pill rounded-full ${section === 'command' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('operations', { section: 'command' })}
        >
          지휘
        </button>
        <button
          class="tab-pill rounded-full ${section === 'tools' ? 'tab-pill--active' : ''}"
          onClick=${() => navigate('operations', { section: 'tools' })}
        >
          도구
        </button>
      </div>

      ${section === 'tools'
        ? html`<${Tools} />`
        : section === 'command'
          ? html`<${Command} />`
          : html`<${Ops} />`}
    </div>
  `
}

export const Control = Operations
