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
    <div class="flex flex-col gap-6">
      <div class="flex gap-1.5 p-1.5 bg-card/40 backdrop-blur-md border border-card-border rounded-xl w-fit shadow-sm shadow-black/10">
        <button
          class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${section === 'intervene' ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
          onClick=${() => navigate('operations', { section: 'intervene' })}
        >
          시스템 개입
        </button>
        <button
          class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${section === 'command' ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
          onClick=${() => navigate('operations', { section: 'command' })}
        >
          지휘 센터
        </button>
        <button
          class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${section === 'tools' ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
          onClick=${() => navigate('operations', { section: 'tools' })}
        >
          도구 및 레지스트리
        </button>
      </div>

      <div class="transition-opacity duration-300">
        ${section === 'tools'
          ? html`<${Tools} />`
          : section === 'command'
            ? html`<${Command} />`
            : html`<${Ops} />`}
      </div>
    </div>
  `
}

export const Control = Operations
