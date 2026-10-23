import { html } from 'htm/preact'
import type { PromptAuthoringIssue } from '../../api/schemas/prompt-authoring'
import { StatusChip } from '../common/status-chip'

export function PromptAuthoringIssues({ issues, compact = false }: {
  issues: readonly PromptAuthoringIssue[]
  compact?: boolean
}) {
  if (issues.length === 0) return null
  return html`
    <div class="my-2 rounded-[var(--r-1)] border border-[var(--warn-border)] bg-[var(--warn-soft)] p-3 text-xs" role="note" aria-label="프롬프트 작성 오류">
      <${StatusChip} tone="warn">작성 오류 ${issues.length}<//>
      ${issues.map(issue => html`
        <div class="mt-2 min-w-0">
          <code class="break-all">${issue.code}</code>
          <div class="mt-1 break-all"><code>${issue.field} = ${JSON.stringify(issue.value)}</code></div>
          <div class="mt-1 break-all font-mono text-2xs">${issue.source_file}</div>
        </div>
      `)}
      ${compact ? null : html`
        <p class="mb-0 mt-2 leading-relaxed">원본 마크다운 파일의 <code>operator_surface</code>를 <code>primary</code> 또는 <code>fragment</code>로 고친 뒤 프롬프트를 다시 등록하세요. 새로고침하면 서버가 보고한 진단을 다시 읽습니다.</p>
        <p class="mb-0 mt-2 leading-relaxed">런타임 오버라이드는 본문을 바꿉니다. 아래에서 저장하거나 제거해도 이 파일의 작성 오류는 고쳐지지 않습니다.</p>
      `}
    </div>
  `
}
