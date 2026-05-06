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
  labelOffsetX?: number
  labelOffsetY?: number
}

export interface LifecycleStateSummary {
  readonly key: string
  readonly label: string
  readonly index: number
  readonly current: boolean
  readonly x: number
  readonly y: number
}

export interface LifecycleTransitionSummary {
  readonly key: string
  readonly from: string
  readonly to: string
  readonly label: string
  readonly fromLabel: string
  readonly toLabel: string
  readonly flashing: boolean
  readonly path: string
  readonly labelX: number
  readonly labelY: number
}

export interface AgentLifecycleSummary {
  readonly currentState: string
  readonly currentLabel: string
  readonly currentKnown: boolean
  readonly stateCount: number
  readonly transitionCount: number
  readonly hasLastTransition: boolean
  readonly lastTransitionFrom: string
  readonly lastTransitionTo: string
  readonly lastTransitionFromLabel: string
  readonly lastTransitionToLabel: string
  readonly lastTransitionAt: number | null
  readonly lastTransitionTimeLabel: string
  readonly flashEdge: string
  readonly states: LifecycleStateSummary[]
  readonly transitions: LifecycleTransitionSummary[]
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
  { from: 'active', to: 'idle', label: 'pause', labelOffsetX: -36, labelOffsetY: 16 },
  { from: 'idle', to: 'active', label: 'resume', labelOffsetX: 40, labelOffsetY: 16 },
  { from: 'active', to: 'terminated', label: 'kill' },
  { from: 'idle', to: 'terminated', label: 'timeout', labelOffsetX: 28, labelOffsetY: 22 },
]

function nodeClass(isCurrent: boolean): string {
  const base =
    'transition-[background-color,border-color,box-shadow,opacity] duration-[var(--t-slow)]'
  if (isCurrent) {
    return `${base} r-6 stroke-[var(--color-accent-fg)] stroke-2 fill-[var(--color-bg-hover)]`
  }
  return `${base} r-4 stroke-[var(--color-border-strong)] stroke-1 fill-[var(--color-bg-elevated)]`
}

function nodeLabelClass(isCurrent: boolean): string {
  const base = 'text-xs font-medium select-none'
  if (isCurrent) {
    return `${base} fill-[var(--color-accent-fg)]`
  }
  return `${base} fill-[var(--color-fg-secondary)]`
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

export function lifecycleTransitionKey(from: string, to: string): string {
  return `${from}→${to}`
}

export function formatLifecycleTransitionTime(timestamp?: number | null): string {
  if (timestamp == null) return ''
  return new Date(timestamp).toLocaleTimeString()
}

export function summarizeAgentLifecycle(
  currentState: string,
  lastTransition?: { from: string; to: string; timestamp: number },
  flashEdge: string | null = null,
): AgentLifecycleSummary {
  const stateEntries = Object.entries(STATES)
  const currentDefinition = STATES[currentState]
  const states = stateEntries.map(([key, state], index) => ({
    key,
    label: state.label,
    index,
    current: key === currentState,
    x: state.x,
    y: state.y,
  }))
  const transitions = TRANSITIONS.map((transition) => {
    const from = STATES[transition.from]!
    const to = STATES[transition.to]!
    const key = lifecycleTransitionKey(transition.from, transition.to)
    const reverseKey = lifecycleTransitionKey(transition.to, transition.from)
    return {
      key,
      from: transition.from,
      to: transition.to,
      label: transition.label,
      fromLabel: from.label,
      toLabel: to.label,
      flashing: flashEdge === key || flashEdge === reverseKey,
      path: edgePath(from, to),
      labelX: (from.x + to.x) / 2 + (transition.labelOffsetX ?? 0),
      labelY: (from.y + to.y) / 2 - 8 + (transition.labelOffsetY ?? 0),
    }
  })

  return {
    currentState,
    currentLabel: currentDefinition?.label ?? currentState,
    currentKnown: currentDefinition != null,
    stateCount: states.length,
    transitionCount: transitions.length,
    hasLastTransition: lastTransition != null,
    lastTransitionFrom: lastTransition?.from ?? '',
    lastTransitionTo: lastTransition?.to ?? '',
    lastTransitionFromLabel: lastTransition
      ? STATES[lastTransition.from]?.label ?? lastTransition.from
      : '',
    lastTransitionToLabel: lastTransition
      ? STATES[lastTransition.to]?.label ?? lastTransition.to
      : '',
    lastTransitionAt: lastTransition?.timestamp ?? null,
    lastTransitionTimeLabel: formatLifecycleTransitionTime(lastTransition?.timestamp),
    flashEdge: flashEdge ?? '',
    states,
    transitions,
  }
}

export function AgentLifecycle({
  currentState,
  lastTransition,
  testId,
}: AgentLifecycleProps) {
  const [flashEdge, setFlashEdge] = useState<string | null>(() =>
    lastTransition ? lifecycleTransitionKey(lastTransition.from, lastTransition.to) : null,
  )
  const flashTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (lastTransition) {
      const key = lifecycleTransitionKey(lastTransition.from, lastTransition.to)
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

  const summary = summarizeAgentLifecycle(currentState, lastTransition, flashEdge)

  return html`
    <div
      class="max-w-full rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4"
      role="region"
      aria-label="에이전트 생명주기"
      data-agent-lifecycle
      data-lifecycle-current-state=${summary.currentState}
      data-lifecycle-current-label=${summary.currentLabel}
      data-lifecycle-current-known=${summary.currentKnown}
      data-lifecycle-state-count=${summary.stateCount}
      data-lifecycle-transition-count=${summary.transitionCount}
      data-lifecycle-has-last-transition=${summary.hasLastTransition}
      data-lifecycle-last-transition-from=${summary.lastTransitionFrom}
      data-lifecycle-last-transition-to=${summary.lastTransitionTo}
      data-lifecycle-last-transition-time-label=${summary.lastTransitionTimeLabel}
      data-lifecycle-flash-edge=${summary.flashEdge}
      data-testid=${testId}
    >
      <div class="mb-3 flex min-w-0 flex-wrap items-center gap-2">
        <span class="text-sm font-medium text-[var(--color-fg-primary)]">생명주기 상태</span>
        <span
          class="inline-flex max-w-full items-center rounded-full bg-[var(--color-accent-fg)]/12 px-2 py-0.5 text-xs font-medium text-[var(--color-accent-fg)]"
          aria-label="현재 상태: ${summary.currentLabel}"
        >
          <span class="min-w-0 truncate">${summary.currentLabel}</span>
        </span>
      </div>

      <svg
        role="img"
        aria-label="에이전트 상태 다이어그램. 상태: ${summary.states.map((s) => s.label).join(', ')}"
        viewBox="0 0 ${svgWidth} ${svgHeight}"
        class="block w-full max-w-full"
        style="max-width:420px;"
        data-lifecycle-svg
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
            <polygon points="0 0, 10 3.5, 0 7" fill="var(--color-border-strong)" />
          </marker>
          <marker
            id="arrowhead-flash"
            markerWidth="10"
            markerHeight="7"
            refX="9"
            refY="3.5"
            orient="auto"
          >
            <polygon points="0 0, 10 3.5, 0 7" fill="var(--color-accent-fg)" />
          </marker>
        </defs>

        ${summary.transitions.map((transition) => {
          return html`
            <g
              key=${transition.key}
              data-lifecycle-transition
              data-lifecycle-transition-key=${transition.key}
              data-lifecycle-transition-from=${transition.from}
              data-lifecycle-transition-to=${transition.to}
              data-lifecycle-transition-label=${transition.label}
              data-lifecycle-transition-flashing=${transition.flashing}
            >
              <path
                d=${transition.path}
                fill="none"
                stroke=${transition.flashing ? 'var(--color-accent-fg)' : 'var(--color-border-strong)'}
                stroke-width=${transition.flashing ? '2.5' : '1.5'}
                marker-end=${transition.flashing ? 'url(#arrowhead-flash)' : 'url(#arrowhead)'}
                class=${transition.flashing ? 'transition-colors duration-[var(--t-slow)]' : ''}
              />
              <text
                x=${transition.labelX}
                y=${transition.labelY}
                text-anchor="middle"
                class="select-none text-2xs fill-[var(--color-fg-muted)]"
              >
                ${transition.label}
              </text>
            </g>
          `
        })}

        ${summary.states.map((state) => {
          return html`
            <g
              key=${state.key}
              data-lifecycle-state
              data-lifecycle-state-key=${state.key}
              data-lifecycle-state-label=${state.label}
              data-lifecycle-state-index=${state.index}
              data-lifecycle-state-current=${state.current}
            >
              ${state.current
                ? html`
                    <circle
                      cx=${state.x}
                      cy=${state.y}
                      r="10"
                      fill="none"
                      stroke="var(--color-accent-fg)"
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
                class=${nodeClass(state.current)}
              />
              <text
                x=${state.x}
                y=${state.y + 20}
                text-anchor="middle"
                class=${nodeLabelClass(state.current)}
              >
                ${state.label}
              </text>
            </g>
          `
        })}
      </svg>

      ${lastTransition
        ? html`
            <div class="mt-2 break-words text-xs text-[var(--color-fg-muted)]">
              마지막 전환: ${summary.lastTransitionFromLabel}
              → ${summary.lastTransitionToLabel}
              (${summary.lastTransitionTimeLabel})
            </div>
          `
        : null}
    </div>
  `
}
