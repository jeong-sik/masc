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
  }, [keeperName])

  if (loading) {
    return html`
      <div class="flex items-center justify-center gap-2 py-6 text-[11px] text-[var(--text-dim)]">
        <span class="inline-block w-3 h-3 rounded-full border-2 border-[var(--accent)] border-t-transparent" style="animation: spin 0.8s linear infinite;"></span>
        상태 다이어그램 로딩중
      </div>
    `
  }

  if (error || !mermaid) {
    return html`<${EmptyState} message=${error ?? '다이어그램 없음'} compact />`
  }

  return html`
    <div>
      ${currentPhase ? html`
        <div class="mb-2 text-[10px] text-[var(--text-dim)]">
          현재 phase: <span class="font-mono font-medium text-[var(--accent)]">${currentPhase}</span>
        </div>
      ` : null}
      <${MermaidGraph}
        source=${mermaid}
        prefix="keeper-state-diagram"
        diagramClass="[&_svg]:max-w-full [&_svg]:mx-auto"
        minHeightClass="min-h-[120px]"
      />
    </div>
  `
}
