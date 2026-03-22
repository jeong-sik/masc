import { html } from 'htm/preact'
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
        // The MCP tool returns text (often markdown or JSON). 
        // Let's parse it if it's JSON or display it.
        try {
          const parsed = JSON.parse(resText)
          setWorktrees(Array.isArray(parsed) ? parsed : parsed.worktrees || [])
        } catch {
          // If it's just raw text, we might need a different display.
          // For now, let's wrap it in an object to render.
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
    return html`<div class="loading-state loading-pulse">워크트리 목록을 불러오는 중...</div>`
  }

  if (error) {
    return html`<div class="text-[var(--bad)] p-4 border border-[var(--bad)] rounded bg-[rgba(255,0,0,0.1)]">${error}</div>`
  }

  if (worktrees.length === 0) {
    return html`
      <div class="empty-state text-center p-8 text-[var(--text-muted)] border border-dashed border-[var(--card-border)] rounded-xl bg-[var(--white-2)]">
        활성화된 워크트리가 없습니다.
      </div>
    `
  }

  // Check if it's the raw text fallback
  if (worktrees.length === 1 && worktrees[0].id === 'raw') {
    return html`
      <div class="bg-[var(--bg-1)] border border-[var(--card-border)] rounded-xl p-4">
        <pre class="font-mono text-sm text-[var(--text-body)] whitespace-pre-wrap">${worktrees[0].path}</pre>
      </div>
    `
  }

  return html`
    <div class="grid gap-4">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold tracking-tight text-[var(--text-strong)]">활성 워크트리</h2>
        <span class="text-sm px-2 py-1 bg-[var(--white-6)] rounded-full text-[var(--text-muted)]">${worktrees.length}개</span>
      </div>
      
      <div class="grid gap-3 grid-cols-1 lg:grid-cols-2">
        ${worktrees.map(wt => html`
          <div key=${wt.id || wt.branch} class="flex flex-col gap-2 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--bg-1)] hover:border-[var(--accent-soft)] transition-colors shadow-sm">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <span class="text-[16px]">🌿</span>
                <span class="font-medium text-[var(--text-strong)] truncate" title=${wt.branch}>${wt.branch}</span>
              </div>
              ${wt.agent ? html`<span class="text-xs px-2 py-0.5 rounded-full bg-[rgba(71,184,255,0.15)] text-[#9ad9ff] border border-[rgba(71,184,255,0.3)]">${wt.agent}</span>` : null}
            </div>
            
            <div class="text-xs text-[var(--text-muted)] flex items-center gap-2 font-mono mt-1">
              <span>📁</span> <span class="truncate" title=${wt.path}>${wt.path}</span>
            </div>
            
            ${wt.task_id ? html`
              <div class="text-xs text-[var(--text-muted)] flex items-center gap-2 mt-1">
                <span>📋</span> <span>${wt.task_id}</span>
              </div>
            ` : null}
            
            ${wt.created_at ? html`
              <div class="text-[10px] text-[var(--text-dim)] mt-2 pt-2 border-t border-[var(--border-slate-12)]">
                생성: ${new Date(wt.created_at).toLocaleString()}
              </div>
            ` : null}
          </div>
        `)}
      </div>
    </div>
  `
}
