import { html } from 'htm/preact'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { useEffect, useState } from 'preact/hooks'
import { callMcpTool } from '../api/mcp'

interface Worktree {
  id: string
  branch: string
  path: string
  agent?: string
  task_id?: string
  created_at?: string
}

export function Worktrees() {
  const [worktrees, setWorktrees] = useState<Worktree[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    async function load() {
      try {
        setLoading(true)
        const resText = await callMcpTool('masc_worktree_list', {})
        try {
          const parsed = JSON.parse(resText)
          setWorktrees(Array.isArray(parsed) ? parsed : parsed.worktrees || [])
        } catch {
          setWorktrees([{ id: 'raw', branch: 'Unknown', path: resText }])
        }
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : '워크트리 로드 실패')
      } finally {
        setLoading(false)
      }
    }
    load()
  }, [])

  if (loading) {
    return html`<${LoadingState}>워크트리 목록을 불러오는 중...<//>`
  }

  if (error) {
    return html`<div class="rounded-xl border border-bad/30 bg-bad/10 p-3.5 text-bad shadow-sm shadow-bad/5">${error}</div>`
  }

  if (!worktrees || worktrees.length === 0) {
    return html`
      <${EmptyState} message="활성화된 워크트리가 없습니다." />
    `
  }

  // Check if it's the raw text fallback
  if (worktrees.length === 1 && worktrees[0]?.id === 'raw') {
    return html`
      <div class="rounded-xl border border-card-border bg-card/34 p-4 shadow-sm shadow-black/8">
        <pre class="font-mono text-sm text-text-body whitespace-pre-wrap">${worktrees[0]?.path}</pre>
      </div>
    `
  }

  return html`
    <div class="grid gap-4">
      <div class="flex items-center justify-end">
        <span class="rounded-full border border-white/5 bg-white/10 px-2.5 py-0.5 text-xs font-medium text-text-muted">${worktrees.length}개</span>
      </div>
      
      <div class="grid grid-cols-1 gap-3 lg:grid-cols-2">
        ${worktrees.map(wt => html`
          <div key=${wt.id || wt.branch} class="group flex flex-col gap-2.5 rounded-xl border border-card-border bg-card/55 p-4 shadow-sm shadow-black/8 transition-all duration-200 hover:-translate-y-0.5 hover:border-accent/32 hover:shadow-md">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <div class="flex size-6.5 items-center justify-center rounded-lg border border-accent/20 bg-accent/10">
                  <span class="text-[14px]">🌿</span>
                </div>
                <span class="font-semibold text-[14px] text-text-strong truncate group-hover:text-accent transition-colors" title=${wt.branch}>${wt.branch}</span>
              </div>
              ${wt.agent ? html`<span class="rounded-md border border-accent/20 bg-accent/10 px-2 py-0.5 text-[10px] font-medium text-accent">${wt.agent}</span>` : null}
            </div>
            
            <div class="mt-0.5 flex items-center gap-2 rounded-lg border border-white/5 bg-bg-0/45 px-2.5 py-1.5 font-mono text-[11px] text-text-muted/90">
              <span>📁</span> <span class="truncate" title=${wt.path}>${wt.path}</span>
            </div>
            
            ${wt.task_id ? html`
              <div class="mt-0.5 flex items-center gap-2 px-0.5 text-[11px] font-medium text-text-muted">
                <span>📋</span> <span>${wt.task_id}</span>
              </div>
            ` : null}
            
            ${wt.created_at ? html`
              <div class="mt-1.5 flex justify-between border-t border-card-border/50 pt-2.5 text-[10px] text-text-dim">
                <span>생성됨</span>
                <span>${new Date(wt.created_at).toLocaleString('ko-KR')}</span>
              </div>
            ` : null}
          </div>
        `)}
      </div>
    </div>
  `
}
