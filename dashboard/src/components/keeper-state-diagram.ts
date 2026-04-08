// Keeper state diagram panel — fetches and renders per-keeper
// Mermaid stateDiagram-v2 showing the 11-state lifecycle
// with current phase highlighted.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchKeeperStateDiagram } from '../api/keeper'
import { MermaidGraph } from './common/mermaid-graph'
import { EmptyState } from './common/empty-state'

interface KeeperStateDiagramProps {
  keeperName: string
  currentPhase?: string | null
}

export function KeeperStateDiagramPanel({ keeperName, currentPhase }: KeeperStateDiagramProps) {
  const [mermaid, setMermaid] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError(null)

    fetchKeeperStateDiagram(keeperName)
      .then(resp => {
        if (cancelled) return
        setMermaid(resp.mermaid)
        setLoading(false)
      })
      .catch(err => {
        if (cancelled) return
        setError(err instanceof Error ? err.message : 'state diagram fetch failed')
        setLoading(false)
      })

    return () => { cancelled = true }
  }, [keeperName, currentPhase])

  if (loading) {
    return html`
      <div class="flex items-center justify-center py-8 text-[11px] text-[var(--text-dim)]">
        상태 다이어그램 로딩중...
      </div>
    `
  }

  if (error || !mermaid) {
    return html`<${EmptyState} message=${error ?? '다이어그램 없음'} compact />`
  }

  return html`
    <div class="space-y-2">
      <div class="flex items-center gap-2">
        <span class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-muted)]">
          Phase State Machine
        </span>
        ${currentPhase ? html`
          <span class="text-[10px] font-mono text-[var(--accent)]">${currentPhase}</span>
        ` : null}
      </div>
      <${MermaidGraph}
        source=${mermaid}
        prefix="keeper-state-diagram"
        diagramClass="[&_svg]:max-w-full"
      />
    </div>
  `
}
