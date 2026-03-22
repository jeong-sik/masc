import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { callMcpTool } from '../api/mcp'

interface Worktree {
  id?: string
  branch?: string
  path?: string
  agent?: string
  task_id?: string
  created_at?: string
  raw?: string
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
          const items = Array.isArray(parsed) ? parsed : parsed.worktrees || []
          
          // Handle [branch, path] tuple arrays specifically for masc_worktree_list OCaml backend format
          const mapped = items.map((item: any) => {
            if (Array.isArray(item) && item.length >= 2) {
              return { branch: item[0], path: item[1] }
            }
            return item
          })
          
          setWorktrees(mapped)
        } catch {
          setWorktrees([{ id: 'raw', branch: '알 수 없음', raw: resText }])
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
    return html`<div class="loading-state loading-pulse p-10 text-center text-[var(--text-muted)]">워크트리 목록을 불러오는 중...</div>`
  }

  if (error) {
    return html`<div class="text-[var(--bad)] p-4 border border-[var(--bad)] rounded-xl bg-[rgba(255,0,0,0.1)] m-4">${error}</div>`
  }

  if (worktrees.length === 0) {
    return html`
      <div class="empty-state text-center p-12 text-[var(--text-muted)] border border-dashed border-[var(--card-border)] rounded-2xl bg-[var(--bg-1)] m-4 shadow-sm">
        <span class="text-3xl mb-3 block">🌱</span>
        <h3 class="text-lg font-medium text-[var(--text-strong)] mb-1">활성화된 워크트리가 없습니다</h3>
        <p class="text-sm">현재 분리된 작업 공간 없이 메인 브랜치에서 대기 중입니다.</p>
      </div>
    `
  }

  if (worktrees.length === 1 && worktrees[0].raw) {
    return html`
      <div class="m-4">
        <div class="bg-[var(--bg-1)] border border-[var(--card-border)] rounded-2xl p-5 shadow-sm">
          <pre class="font-mono text-sm text-[var(--text-body)] whitespace-pre-wrap">${worktrees[0].raw}</pre>
        </div>
      </div>
    `
  }

  return html`
    <div class="grid gap-5">
      <div class="flex items-center justify-between px-2">
        <div>
          <h2 class="text-xl font-semibold tracking-tight text-[var(--text-strong)] flex items-center gap-2">
            <span>🌱</span> 활성 워크트리
          </h2>
          <p class="text-[13px] text-[var(--text-muted)] mt-1">각 에이전트/태스크별 독립된 Git 작업 공간입니다.</p>
        </div>
        <span class="text-sm font-medium px-3 py-1 bg-[var(--white-6)] border border-[var(--card-border)] rounded-full text-[var(--text-muted)] shadow-inner">
          총 ${worktrees.length}개
        </span>
      </div>
      
      <div class="grid gap-4 grid-cols-1 md:grid-cols-2 lg:grid-cols-3">
        ${worktrees.map(wt => html`
          <div key=${wt.branch} class="group flex flex-col p-5 rounded-2xl border border-[var(--card-border)] bg-[var(--bg-1)] hover:border-[var(--accent-soft)] hover:shadow-md hover:bg-[var(--bg-0)] transition-all duration-200">
            <div class="flex items-start justify-between gap-3 mb-4">
              <div class="flex items-center gap-2.5 min-w-0">
                <div class="w-8 h-8 rounded-full bg-[rgba(71,184,255,0.1)] flex items-center justify-center text-[var(--accent)] shrink-0 border border-[rgba(71,184,255,0.2)]">
                  <svg xmlns="http://www.w0.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3v12"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/></svg>
                </div>
                <div class="flex flex-col min-w-0">
                  <span class="font-semibold text-[15px] text-[var(--text-strong)] truncate group-hover:text-[var(--accent)] transition-colors" title=${wt.branch}>
                    ${wt.branch}
                  </span>
                  ${wt.task_id ? html`<span class="text-xs text-[var(--text-muted)] truncate">Task: ${wt.task_id}</span>` : null}
                </div>
              </div>
              
              ${wt.agent ? html`
                <div class="shrink-0 text-[10px] font-bold px-2 py-1 rounded-md bg-[var(--white-6)] text-[var(--text-strong)] border border-[var(--border-slate-12)] uppercase tracking-wider">
                  ${wt.agent}
                </div>
              ` : null}
            </div>
            
            <div class="mt-auto pt-3 border-t border-[var(--border-slate-12)] flex flex-col gap-2">
              <div class="flex items-center gap-2 text-xs text-[var(--text-muted)] font-mono bg-[var(--white-2)] p-2 rounded-lg border border-[var(--white-4)]">
                <svg class="shrink-0 text-[var(--text-dim)]" xmlns="http://www.w0.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/></svg>
                <span class="truncate" title=${wt.path}>${wt.path}</span>
              </div>
              
              ${wt.created_at ? html`
                <div class="text-[10px] text-[var(--text-dim)] flex justify-end">
                  생성: ${new Date(wt.created_at).toLocaleString()}
                </div>
              ` : null}
            </div>
          </div>
        `)}
      </div>
    </div>
  `
}
