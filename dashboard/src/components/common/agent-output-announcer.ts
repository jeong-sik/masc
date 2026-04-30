// AgentOutputAnnouncer — AX molecule for screen-reader announcement of agent outputs.
//
// Kimi design system sec06 reference: Live Region policy + AgentOutputAnnouncer.
// Converts structured agent outputs into concise aria-live friendly strings.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'

export interface AgentOutput {
  id: string
  type: 'code' | 'text' | 'table' | 'error'
  content: string
  metadata?: { language?: string; lineCount?: number }
}

export function announceAgentOutput(output: AgentOutput): string {
  switch (output.type) {
    case 'code':
      return `코드 출력, ${output.metadata?.language || '알 수 없는'} 언어, ${output.metadata?.lineCount ?? '여러'} 줄`
    case 'table':
      return `테이블 데이터, ${output.content.split('\n').length} 행`
    case 'error':
      return `오류 발생: ${output.content.slice(0, 100)}`
    default:
      return output.content.length > 200
        ? `텍스트 출력, ${output.content.length}자: ${output.content.slice(0, 100)}...`
        : `텍스트 출력: ${output.content}`
  }
}

interface AgentOutputAnnouncerProps {
  outputs: AgentOutput[]
  priority?: 'polite' | 'assertive'
  testId?: string
}

export function AgentOutputAnnouncer({
  outputs,
  priority = 'polite',
  testId,
}: AgentOutputAnnouncerProps) {
  const prevCountRef = useRef(0)
  const liveRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (outputs.length > prevCountRef.current && liveRef.current) {
      const latest = outputs[outputs.length - 1]
      liveRef.current.textContent = announceAgentOutput(latest)
    }
    prevCountRef.current = outputs.length
  }, [outputs])

  const ariaLive = priority === 'assertive' ? 'assertive' : 'polite'
  const ariaAtomic = priority === 'assertive' ? 'true' : 'false'

  return html`
    <div
      class="sr-only"
      role="log"
      aria-live=${ariaLive}
      aria-atomic=${ariaAtomic}
      aria-label="에이전트 출력 알림"
      ref=${liveRef}
      data-agent-output-announcer
      data-testid=${testId}
    ></div>
  `
}
