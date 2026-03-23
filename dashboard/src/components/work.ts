// MASC Dashboard — Work Tab
// Absorbs: memory(board) + governance + proof + planning into pill-switched sections.

import { html } from 'htm/preact'
import { route, navigate } from '../router'
import { Memory } from './memory'
import { Governance } from './governance'
import { Proof } from './proof'
import { Planning } from './goals'
import { Worktrees } from './worktrees'
import { ErrorBoundary } from './common/error-boundary'

type WorkSection = 'board' | 'governance' | 'evidence' | 'planning' | 'worktrees'

const SECTIONS: { id: WorkSection; label: string; tooltip: string }[] = [
  { id: 'board', label: '게시판', tooltip: '에이전트 간 소통과 지식 공유' },
  { id: 'governance', label: '거버넌스', tooltip: '의사결정 기록과 판결' },
  { id: 'evidence', label: '근거', tooltip: '작업 증거와 검증 결과' },
  { id: 'planning', label: '계획', tooltip: '장기 목표와 메트릭 루프' },
  { id: 'worktrees', label: '워크트리', tooltip: '활성화된 작업 공간 관리' },
]

function isWorkSection(v: string | undefined): v is WorkSection {
  return v === 'board' || v === 'governance' || v === 'evidence' || v === 'planning' || v === 'worktrees'
}

export function Work() {
  const current: WorkSection = isWorkSection(route.value.params.section)
    ? route.value.params.section
    : 'board'

  return html`
    <div class="flex flex-col gap-6">
      <div class="flex gap-1.5 p-1.5 bg-card/40 backdrop-blur-md border border-card-border rounded-xl w-fit shadow-sm shadow-black/10">
        ${SECTIONS.map(s => html`
          <button
            key=${s.id}
            class="px-4 py-2 rounded-lg text-[13px] font-semibold transition-all duration-200 cursor-pointer border border-transparent ${current === s.id ? 'bg-accent/10 text-accent border-accent/20 shadow-sm' : 'bg-transparent text-text-muted hover:bg-white/5 hover:text-text-body'}"
            title=${s.tooltip}
            onClick=${() => navigate('work', { section: s.id })}
          >
            ${s.label}
          </button>
        `)}
      </div>

      <div class="transition-opacity duration-300">
        <${ErrorBoundary} label=${current}>
          ${current === 'board' ? html`<${Memory} />`
            : current === 'governance' ? html`<${Governance} />`
            : current === 'evidence' ? html`<${Proof} />`
            : current === 'planning' ? html`<${Planning} />`
            : html`<${Worktrees} />`
          }
        </>
      </div>
    </div>
  `
}
