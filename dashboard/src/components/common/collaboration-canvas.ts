// CollaborationCanvas — AX organism for real-time collaborative editing.
//
// Kimi design system sec05 5.2.3 reference: shared canvas with participant
// presence, cursor indicators, and selection highlights.

import { html } from 'htm/preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'

export interface CanvasParticipant {
  id: string
  type: 'human' | 'agent'
  name: string
  color: string
  cursor?: { x: number; y: number }
  selection?: { start: number; end: number }
}

interface CollaborationCanvasProps {
  content: string
  participants: CanvasParticipant[]
  onChange: (value: string) => void
  testId?: string
}

const PARTICIPANT_BADGE_CLASS =
  'inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium'

function participantBadgeBg(type: CanvasParticipant['type']): string {
  return type === 'human'
    ? 'bg-[var(--accent-3)] text-[var(--accent-11)]'
    : 'bg-[var(--purple-3)] text-[var(--purple-11)]'
}

function participantDot(color: string): string {
  return `width:8px;height:8px;border-radius:50%;background:${color};`
}

function cursorStyle(
  cursor: CanvasParticipant['cursor'],
  color: string
): string {
  if (!cursor) return ''
  return `position:absolute;left:${cursor.x}px;top:${cursor.y}px;` +
    `width:2px;height:20px;background:${color};pointer-events:none;`
}

function selectionStyle(
  selection: CanvasParticipant['selection'],
  color: string
): string {
  if (!selection || selection.start === selection.end) return ''
  return `background:${color}33;`
}

export function CollaborationCanvas({
  content,
  participants,
  onChange,
  testId,
}: CollaborationCanvasProps) {
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const [localContent, setLocalContent] = useState(content)

  useEffect(() => {
    setLocalContent(content)
  }, [content])

  const handleInput = useCallback(
    (e: Event) => {
      const target = e.target as HTMLTextAreaElement
      setLocalContent(target.value)
      onChange(target.value)
    },
    [onChange]
  )

  const activeParticipants = participants.filter(
    (p) => p.cursor != null || p.selection != null
  )
  const textareaId = testId ? `${testId}-textarea` : 'collab-textarea'
  const labelId = testId ? `${testId}-label` : 'collab-label'

  return html`
    <div
      class="relative flex flex-col gap-3 rounded-lg border border-[var(--gray-6)] bg-[var(--gray-1)] p-4"
      role="region"
      aria-label="협업 편집 영역"
      data-testid=${testId}
    >
      <div class="flex items-center justify-between">
        <span id=${labelId} class="text-sm font-medium text-[var(--gray-12)]">
          협업 편집기
        </span>
        <div
          class="flex flex-wrap gap-1.5"
          role="list"
          aria-label="참여자 목록"
        >
          ${participants.map(
            (p) => html`
              <span
                class=${`${PARTICIPANT_BADGE_CLASS} ${participantBadgeBg(p.type)}`}
                role="listitem"
                aria-label="${p.name} (${p.type === 'human' ? '사람' : '에이전트'})"
              >
                <span style=${participantDot(p.color)}></span>
                ${p.name}
              </span>
            `
          )}
        </div>
      </div>

      <div class="relative">
        <textarea
          ref=${textareaRef}
          id=${textareaId}
          class="w-full min-h-[160px] resize-y rounded-md border border-[var(--gray-7)] bg-[var(--gray-1)] px-3 py-2 text-sm text-[var(--gray-12)] focus:border-[var(--accent-8)] focus:outline-none focus:ring-1 focus:ring-[var(--accent-8)]"
          value=${localContent}
          onInput=${handleInput}
          aria-labelledby=${labelId}
          aria-describedby=${activeParticipants.length > 0
            ? `${testId ? `${testId}-` : ''}presence-desc`
            : undefined}
        />

        ${activeParticipants.map(
          (p) => html`
            <div
              style=${cursorStyle(p.cursor, p.color)}
              role="img"
              aria-label="${p.name} 커서"
            />
          `
        )}
      </div>

      ${activeParticipants.length > 0
        ? html`
            <div
              id=${`${testId ? `${testId}-` : ''}presence-desc`}
              class="text-xs text-[var(--gray-10)]"
            >
              ${activeParticipants.map((p) => p.name).join(', ')}님이
              편집 중입니다.
            </div>
            <div class="flex flex-wrap gap-1" aria-hidden="true">
              ${activeParticipants
                .filter((p) => p.selection != null && p.selection.start !== p.selection.end)
                .map((p) => html`
                  <span
                    class="rounded px-2 py-0.5 text-xs text-[var(--gray-12)]"
                    style=${selectionStyle(p.selection, p.color)}
                  >
                    ${p.name} ${p.selection?.start}-${p.selection?.end}
                  </span>
                `)}
            </div>
          `
        : null}
    </div>
  `
}
