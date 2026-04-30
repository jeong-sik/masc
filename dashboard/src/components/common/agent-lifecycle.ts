// AgentLifecycle — AX organism that visualises agent state-machine lifecycle.
//
// Kimi design system sec02 2.2.1 reference: SVG FSM diagram showing current
// state, transitions, and last transition flash.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'

export interface LifecycleTransition {
  from: string
  to: string
  label: string
}

interface AgentLifecycleProps {
  currentState: string
  lastTransition?: { from: string; to: string; timestamp: number }
  testId?: string
}

const STATES: Record<string, { x: number; y: number; label: string }> = {
  created: { x: 50, y: 50, label: '생성됨' },
  active: { x: 200, y: 50, label: '활성' },
  idle: { x: 200, y: 150, label: '유휴' },
  terminated: { x: 350, y: 100, label: '종료' },
}

const TRANSITIONS: LifecycleTransition[] = [
  { from: 'created', to: 'active', label: 'activate' },
  { from: 'active', to: 'idle', label: 'pause' },
  { from: 'idle', to: 'active', label: 'resume' },
  { from: 'active', to: 'terminated', label: 'kill' },
  { from: 'idle', to: 'terminated', label: 'timeout' },
]

function nodeClass(isCurrent: boolean): string {
  const base =
    'transition-all duration-300'
  if (isCurrent) {
    return `${base} r-6 stroke-[var(--accent-9)] stroke-2 fill-[var(--accent-3)]`
  }
  return `${base} r-4 stroke-[var(--gray-8)] stroke-1 fill-[var(--gray-3)]`
}

function nodeLabelClass(isCurrent: boolean): string {
  const base = 'text-xs font-medium select-none'
  if (isCurrent) {
    return `${base} fill-[var(--accent-11)]`
  }
  return `${base} fill-[var(--gray-11)]`
}

function edgePath(from: { x: number; y: number }, to: { x: number; y: number }): string {
  const dx = to.x - from.x
  const dy = to.y - from.y
  const midX = (from.x + to.x) / 2
  const midY = (from.y + to.y) / 2
  const offset = 20
  const ctrlX = midX - dy * 0.2 + (dx < 0 ? -offset : offset)
  const ctrlY = midY + dx * 0.2
  return `M ${from.x} ${from.y} Q ${ctrlX} ${ctrlY} ${to.x} ${to.y}`
}

export function AgentLifecycle({
  currentState,
  lastTransition,
  testId,
}: AgentLifecycleProps) {
  const [flashEdge, setFlashEdge] = useState<string | null>(null)
  const flashTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (lastTransition) {
      const key = `${lastTransition.from}→${lastTransition.to}`
      setFlashEdge(key)
      if (flashTimeoutRef.current) {
        clearTimeout(flashTimeoutRef.current)
      }
      flashTimeoutRef.current = setTimeout(() => {
        setFlashEdge((current) => (current === key ? null : current))
      }, 1000)
    }
    return () => {
      if (flashTimeoutRef.current) {
        clearTimeout(flashTimeoutRef.current)
      }
    }
  }, [lastTransition?.from, lastTransition?.to, lastTransition?.timestamp])

  const svgWidth = 420
  const svgHeight = 210

  const stateList = Object.entries(STATES)

  return html`
    <div
      class="rounded-lg border border-[var(--gray-6)] bg-[var(--gray-1)] p-4"
      role="region"
      aria-label="에이전트 생명주기"
      data-testid=${testId}
    >
      <div class="mb-3 flex items-center gap-2">
        <span class="text-sm font-medium text-[var(--gray-12)]">생명주기 상태</span>
        <span
          class="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium bg-[var(--accent-3)] text-[var(--accent-11)]"
          aria-label="현재 상태: ${STATES[currentState]?.label ?? currentState}"
        >
          ${STATES[currentState]?.label ?? currentState}
        </span>
      </div>

      <svg
        role="img"
        aria-label="에이전트 상태 다이어그램. 상태: ${stateList.map(([,s]) => s.label).join(', ')}"
        viewBox="0 0 ${svgWidth} ${svgHeight}"
        class="w-full"
        style="max-width:420px;"
      >
        <defs>
          <marker
            id="arrowhead"
            markerWidth="10"
            markerHeight="7"
            refX="9"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 10 3.5, 0 7" fill="var(--gray-8)" />
          </marker>
          <marker
            id="arrowhead-flash"
            markerWidth="10"
            markerHeight="7"
            refX="9"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 10 3.5, 0 7" fill="var(--accent-9)" />
          </marker>
        </defs>

        ${TRANSITIONS.map((t) => {
          const from = STATES[t.from]
          const to = STATES[t.to]
          if (!from || !to) return null
          const isFlashing =
            flashEdge === `${t.from}→${t.to}` ||
            flashEdge === `${t.to}→${t.from}`
          const pathD = edgePath(from, to)

          return html`
            <g key=${t.label}>
              <path
                d=${pathD}
                fill="none"
                stroke=${isFlashing ? 'var(--accent-9)' : 'var(--gray-8)'}
                stroke-width=${isFlashing ? '2.5' : '1.5'}
                marker-end=${isFlashing ? 'url(#arrowhead-flash)' : 'url(#arrowhead)'}
                class=${isFlashing ? 'transition-colors duration-300' : ''}
              />
              <text
                x=${(from.x + to.x) / 2}
                y=${(from.y + to.y) / 2 - 8}
                text-anchor="middle"
                class="text-2xs fill-[var(--gray-10)] select-none"
              >
                ${t.label}
              </text>
            </g>
          `
        })}

        ${stateList.map(([key, state]) => {
          const isCurrent = key === currentState
          return html`
            <g key=${key}>
              ${isCurrent
                ? html`
                    <circle
                      cx=${state.x}
                      cy=${state.y}
                      r="10"
                      fill="none"
                      stroke="var(--accent-7)"
                      stroke-width="1"
                      opacity="0.5"
                    >
                      <animate
                        attributeName="r"
                        values="10;14;10"
                        dur="2s"
                        repeatCount="indefinite"
                      />
                      <animate
                        attributeName="opacity"
                        values="0.5;0.2;0.5"
                        dur="2s"
                        repeatCount="indefinite"
                      />
                    </circle>
                  `
                : null}
              <circle
                cx=${state.x}
                cy=${state.y}
                class=${nodeClass(isCurrent)}
              />
              <text
                x=${state.x}
                y=${state.y + 20}
                text-anchor="middle"
                class=${nodeLabelClass(isCurrent)}
              >
                ${state.label}
              </text>
            </g>
          `
        })}
      </svg>

      ${lastTransition
        ? html`
            <div class="mt-2 text-xs text-[var(--gray-10)]">
              마지막 전환: ${STATES[lastTransition.from]?.label ?? lastTransition.from}
              → ${STATES[lastTransition.to]?.label ?? lastTransition.to}
              (${new Date(lastTransition.timestamp).toLocaleTimeString()})
            </div>
          `
        : null}
    </div>
  `
}
