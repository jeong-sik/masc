import { html } from 'htm/preact'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { useEffect, useState } from 'preact/hooks'
import { callMcpTool } from '../api/mcp'

const REFS_HEADS_PREFIX = 'refs/heads/'

interface Worktree {
  id: string
  branch: string
  path: string
  agent?: string
  task_id?: string
  created_at?: string
}

function normalizeWorktreeBranch(branch: string): string {
  if (branch.startsWith(REFS_HEADS_PREFIX)) {
    return branch.slice(REFS_HEADS_PREFIX.length)
  }
  return branch
}

function normalizeWorktreeEntry(entry: unknown, index: number): Worktree | null {
  if (!entry || typeof entry !== 'object') {
    return null
  }

  const record = entry as Record<string, unknown>
  const rawPath = record.path ?? record.worktree
  const path = typeof rawPath === 'string' ? rawPath.trim() : ''
  const rawBranch = typeof record.branch === 'string' ? record.branch.trim() : ''
  const branch = normalizeWorktreeBranch(rawBranch)

  if (!path || !branch) {
    return null
  }

  return {
    id:
      typeof record.id === 'string' && record.id.trim()
        ? record.id
        : `${branch}:${path}:${index}`,
    branch,
    path,
    agent: typeof record.agent === 'string' ? record.agent : undefined,
    task_id:
      typeof record.task_id === 'string'
        ? record.task_id
        : typeof record.taskId === 'string'
          ? record.taskId
          : undefined,
    created_at:
      typeof record.created_at === 'string'
        ? record.created_at
        : typeof record.createdAt === 'string'
          ? record.createdAt
          : undefined,
  }
}

function collectWorktreeItems(parsed: unknown): unknown[] {
  if (Array.isArray(parsed)) {
    return parsed
  }
  if (!parsed || typeof parsed !== 'object') {
    return []
  }

  const record = parsed as Record<string, unknown>
  if (Array.isArray(record.worktrees)) {
    return record.worktrees
  }
  if (Array.isArray(record.items)) {
    return record.items
  }
  return []
}

function hasWorktreeCollection(parsed: unknown): boolean {
  if (Array.isArray(parsed)) {
    return true
  }
  if (!parsed || typeof parsed !== 'object') {
    return false
  }

  const record = parsed as Record<string, unknown>
  return Array.isArray(record.worktrees) || Array.isArray(record.items)
}

function parsePorcelainWorktrees(raw: string): Worktree[] {
  const blocks = raw
    .trim()
    .split(/\n\s*\n/)
    .map(block => block.trim())
    .filter(Boolean)

  return blocks
    .map((block, index) => {
      let path = ''
      let branch = ''
      let detached = false

      for (const line of block.split('\n').map(item => item.trim())) {
        if (line.startsWith('worktree ')) {
          path = line.slice('worktree '.length).trim()
        } else if (line.startsWith('branch ')) {
          branch = normalizeWorktreeBranch(line.slice('branch '.length).trim())
        } else if (line === 'detached') {
          detached = true
        }
      }

      if (!path) {
        return null
      }

      const label = branch || (detached ? '(detached)' : '')
      if (!label) {
        return null
      }

      return {
        id: `${label}:${path}:${index}`,
        branch: label,
        path,
      } satisfies Worktree
    })
    .filter((item): item is Worktree => item !== null)
}

export function parseWorktreeResponse(raw: string): Worktree[] {
  const trimmed = raw.trim()
  if (!trimmed) {
    return []
  }

  try {
    const parsed = JSON.parse(trimmed)
    const worktrees = collectWorktreeItems(parsed)
      .map((entry, index) => normalizeWorktreeEntry(entry, index))
      .filter((entry): entry is Worktree => entry !== null)
    if (worktrees.length > 0 || hasWorktreeCollection(parsed)) {
      return worktrees
    }
  } catch {
    // Fall through to raw text parsing.
  }

  const porcelainWorktrees = parsePorcelainWorktrees(raw)
  if (porcelainWorktrees.length > 0) {
    return porcelainWorktrees
  }

  return [{ id: 'raw', branch: 'Unknown', path: raw }]
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
        setWorktrees(parseWorktreeResponse(resText))
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
                <div class="flex size-6.5 items-center justify-center rounded-lg border border-accent/20 bg-[var(--accent-10)]">
                  <span class="text-[14px]">🌿</span>
                </div>
                <span class="font-semibold text-[14px] text-text-strong truncate group-hover:text-accent transition-colors" title=${wt.branch}>${wt.branch}</span>
              </div>
              ${wt.agent ? html`<span class="rounded-md border border-accent/20 bg-[var(--accent-10)] px-2 py-0.5 text-[10px] font-medium text-accent">${wt.agent}</span>` : null}
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
