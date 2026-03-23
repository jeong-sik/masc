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
      } catch (err: any) {
        setError(err.message || 'Failed to load worktrees')
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
    return html`<div class="text-bad p-4 border border-bad/30 rounded-xl bg-bad/10 shadow-sm shadow-bad/5">${error}</div>`
  }

  if (!worktrees || worktrees.length === 0) {
    return html`
      <${EmptyState} message="활성화된 워크트리가 없습니다." />
    `
  }

  // Check if it's the raw text fallback
  if (worktrees.length === 1 && worktrees[0]?.id === 'raw') {
    return html`
      <div class="bg-card/40 backdrop-blur-md border border-card-border rounded-2xl p-5 shadow-sm shadow-black/10">
        <pre class="font-mono text-sm text-text-body whitespace-pre-wrap">${worktrees[0]?.path}</pre>
      </div>
    `
  }

  return html`
    <div class="grid gap-5">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold tracking-wide text-text-strong">활성 워크트리</h2>
        <span class="text-xs font-medium px-2.5 py-1 bg-white/10 rounded-full text-text-muted border border-white/5">${worktrees.length}개</span>
      </div>
      
      <div class="grid gap-4 grid-cols-1 lg:grid-cols-2">
        ${worktrees.map(wt => html`
          <div key=${wt.id || wt.branch} class="flex flex-col gap-3 p-5 rounded-2xl border border-card-border bg-card/60 backdrop-blur-md hover:border-accent/40 hover:-translate-y-0.5 hover:shadow-md transition-all duration-200 shadow-sm shadow-black/10 group">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <div class="size-7 rounded-lg bg-accent/10 flex items-center justify-center border border-accent/20">
                  <span class="text-[14px]">🌿</span>
                </div>
                <span class="font-semibold text-[14px] text-text-strong truncate group-hover:text-accent transition-colors" title=${wt.branch}>${wt.branch}</span>
              </div>
              ${wt.agent ? html`<span class="text-[10px] font-medium px-2.5 py-1 rounded-md bg-accent/10 text-accent border border-accent/20 shadow-sm">${wt.agent}</span>` : null}
            </div>
            
            <div class="text-[11px] text-text-muted/90 flex items-center gap-2 font-mono mt-1 bg-bg-0/50 p-2 rounded-lg border border-white/5">
              <span>📁</span> <span class="truncate" title=${wt.path}>${wt.path}</span>
            </div>
            
            ${wt.task_id ? html`
              <div class="text-[11px] font-medium text-text-muted flex items-center gap-2 mt-1 px-1">
                <span>📋</span> <span>${wt.task_id}</span>
              </div>
            ` : null}
            
            ${wt.created_at ? html`
              <div class="text-[10px] text-text-dim mt-2 pt-3 border-t border-card-border/50 flex justify-between">
                <span>생성됨</span>
                <span>${new Date(wt.created_at).toLocaleString()}</span>
              </div>
            ` : null}
          </div>
        `)}
      </div>
    </div>
  `
}
