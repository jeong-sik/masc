// MASC Dashboard — Work Tab
// Absorbs: memory(board) + governance + proof + planning into pill-switched sections.

import { html } from 'htm/preact'
import { route } from '../router'
import { Memory } from './memory'
import { Proof } from './proof'
import { Planning } from './goals'
import { Worktrees } from './worktrees'
import { ErrorBoundary } from './common/error-boundary'
import { TaskCreateForm } from './task-manage/task-create-form'

type WorkSection = 'board' | 'evidence' | 'planning' | 'worktrees'

function isWorkSection(v: string | undefined): v is WorkSection {
  return v === 'board' || v === 'evidence' || v === 'planning' || v === 'worktrees'
}

export function Work() {
  const current: WorkSection = isWorkSection(route.value.params.section)
    ? route.value.params.section
    : 'board'

  return html`
    <div class="flex flex-col gap-4">
      <div class="transition-opacity duration-300">
        <${ErrorBoundary} label=${current}>
          ${current === 'board' ? html`<${TaskCreateForm} /><${Memory} />`
            : current === 'evidence' ? html`<${Proof} />`
            : current === 'planning' ? html`<${Planning} />`
            : html`<${Worktrees} />`
          }
        </>
      </div>
    </div>
  `
}
