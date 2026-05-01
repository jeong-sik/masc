// use-agent-announcer.ts — screen-reader live region manager
//
// Kimi design system sec06 6.4: useAgentAnnouncer exposes announce() and
// announceAgentOutput() for routing agent messages to aria-live regions.

import { useCallback } from 'preact/hooks'

export interface AgentOutput {
  type: 'code' | 'text' | 'table' | 'error'
  content: string
  metadata?: { language?: string; lineCount?: number }
}

export interface UseAgentAnnouncerResult {
  announce: (message: string, priority?: 'polite' | 'assertive') => void
  announceAgentOutput: (output: AgentOutput) => void
}

function summarizeOutput(output: AgentOutput): string {
  switch (output.type) {
    case 'code': {
      const lang = output.metadata?.language || 'unknown'
      const lines = output.metadata?.lineCount ?? output.content.split('\n').filter((l) => l.trim()).length
      return `Code output, ${lang}, ${lines} lines`
    }
    case 'table':
      return `Table data, ${output.content.split('\n').length} rows`
    case 'error':
      return `Error: ${output.content.slice(0, 100)}`
    default:
      return output.content.length > 200
        ? `Text output, ${output.content.length} chars: ${output.content.slice(0, 100)}...`
        : `Text output: ${output.content}`
  }
}

export function useAgentAnnouncer(): UseAgentAnnouncerResult {
  const announce = useCallback((message: string, priority: 'polite' | 'assertive' = 'polite') => {
    const liveRegion = document.getElementById(`live-region-${priority}`)
    if (!liveRegion) return
    liveRegion.textContent = ''
    // force reflow to clear previous message
    void liveRegion.offsetHeight
    liveRegion.textContent = message
  }, [])

  const announceAgentOutput = useCallback(
    (output: AgentOutput) => {
      const summary = summarizeOutput(output)
      const priority = output.type === 'error' ? 'assertive' : 'polite'
      announce(summary, priority)
    },
    [announce]
  )

  return { announce, announceAgentOutput }
}
