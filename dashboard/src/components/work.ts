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
    <div class="tab-unified grid gap-4">
      <div class="tab-pill-bar">
        ${SECTIONS.map(s => html`
          <button
            key=${s.id}
            class="tab-pill-btn ${current === s.id ? 'active' : ''}"
            title=${s.tooltip}
            onClick=${() => navigate('work', { section: s.id })}
          >
            ${s.label}
          </button>
        `)}
      </div>

      <${ErrorBoundary} label=${current}>
        ${current === 'board' ? html`<${Memory} />`
          : current === 'governance' ? html`<${Governance} />`
          : current === 'evidence' ? html`<${Proof} />`
          : current === 'planning' ? html`<${Planning} />`
          : html`<${Worktrees} />`
        }
      </>
    </div>
  `
}
