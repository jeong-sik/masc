// AgentOutputAnnouncer — AX molecule for screen-reader announcement of agent outputs.
//
// Kimi design system sec06 reference: Live Region policy + AgentOutputAnnouncer.
// Converts structured agent outputs into concise aria-live friendly strings.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'

export interface AgentOutput {
  id: string
  type: 'code' | 'text' | 'table' | 'error'
  content: string
  metadata?: { language?: string; lineCount?: number }
}

export type AgentOutputPriority = 'polite' | 'assertive'
export type AgentOutputPriorityPolicy = AgentOutputPriority | 'auto'

export interface AgentOutputAnnouncement {
  readonly id: string
  readonly type: AgentOutput['type']
  readonly message: string
  readonly priority: AgentOutputPriority
  readonly contentLength: number
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

export function resolveAgentOutputPriority(
  output: AgentOutput,
  priority: AgentOutputPriorityPolicy = 'polite',
): AgentOutputPriority {
  if (priority !== 'auto') return priority
  return output.type === 'error' ? 'assertive' : 'polite'
}

export function summarizeAgentOutput(
  output: AgentOutput,
  priority: AgentOutputPriorityPolicy = 'polite',
): AgentOutputAnnouncement {
  return {
    id: output.id,
    type: output.type,
    message: announceAgentOutput(output),
    priority: resolveAgentOutputPriority(output, priority),
    contentLength: output.content.length,
  }
}

interface AgentOutputAnnouncerProps {
  outputs: AgentOutput[]
  priority?: AgentOutputPriorityPolicy
  testId?: string
}

export function AgentOutputAnnouncer({
  outputs,
  priority = 'polite',
  testId,
}: AgentOutputAnnouncerProps) {
  const lastAnnouncedRef = useRef<string | null>(null)
  const renderedMessageRef = useRef('')
  const pendingAnnouncementTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const [announcement, setAnnouncement] = useState<AgentOutputAnnouncement | null>(null)

  useEffect(() => () => {
    if (pendingAnnouncementTimerRef.current !== null) {
      clearTimeout(pendingAnnouncementTimerRef.current)
    }
  }, [])

  useEffect(() => {
    const latest = outputs[outputs.length - 1]
    if (!latest) return

    const next = summarizeAgentOutput(latest, priority)
    const announcementKey = `${next.id}:${next.priority}`
    if (announcementKey === lastAnnouncedRef.current) return

    if (pendingAnnouncementTimerRef.current !== null) {
      clearTimeout(pendingAnnouncementTimerRef.current)
      pendingAnnouncementTimerRef.current = null
    }

    lastAnnouncedRef.current = announcementKey
    if (renderedMessageRef.current === next.message) {
      renderedMessageRef.current = ''
      setAnnouncement(null)
      pendingAnnouncementTimerRef.current = setTimeout(() => {
        renderedMessageRef.current = next.message
        setAnnouncement(next)
        pendingAnnouncementTimerRef.current = null
      }, 0)
      return
    }

    renderedMessageRef.current = next.message
    setAnnouncement(next)
  }, [outputs, priority])

  const ariaLive = announcement?.priority ?? (priority === 'assertive' ? 'assertive' : 'polite')
  const ariaAtomic = ariaLive === 'assertive' ? 'true' : 'false'

  return html`
    <div
      class="sr-only"
      role="log"
      aria-live=${ariaLive}
      aria-atomic=${ariaAtomic}
      aria-relevant="additions text"
      aria-label="에이전트 출력 알림"
      data-agent-output-announcer
      data-agent-output-announcer-priority=${ariaLive}
      data-agent-output-announcer-output-id=${announcement?.id}
      data-agent-output-announcer-output-type=${announcement?.type}
      data-agent-output-announcer-content-length=${announcement?.contentLength}
      data-testid=${testId}
    >${announcement?.message ?? ''}</div>
  `
}
