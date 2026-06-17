import { html } from 'htm/preact'
import {
  cx,
  MgEntry,
  MgLegend,
  MgSig,
  type MemoryKeeper,
  type MemoryNode,
  type MemoryNodeType,
} from './memory-primitives'

export interface MemoryLineageStep {
  readonly id: string
  readonly t: string
  readonly rel: string
  readonly anchor?: boolean
}

export interface MemoryLineageRailProps {
  readonly steps: ReadonlyArray<MemoryLineageStep>
  readonly nodes: Readonly<Record<string, MemoryNode>>
  readonly nodeTypes: Readonly<Record<string, MemoryNodeType>>
  readonly keepers?: Readonly<Record<string, MemoryKeeper>>
  readonly ariaLabel?: string
  readonly testId?: string
}

export function MemoryLineageRail({
  steps,
  nodes,
  nodeTypes,
  keepers = {},
  ariaLabel = '메모리 인과 추적',
  testId,
}: MemoryLineageRailProps) {
  if (steps.length === 0) {
    return html`
      <div class="mg-board ss-card" data-testid=${testId} aria-label=${ariaLabel}>
        <${MgEntry} extra="lineage · 위→아래 인과 흐름" />
        <div class="flex items-center justify-center text-[12px] text-text-tertiary" style=${{ minHeight: '160px' }}>
          인과 단계가 없습니다.
        </div>
      </div>
    `
  }

  return html`
    <div class="mg-board ss-card" data-testid=${testId} aria-label=${ariaLabel}>
      <${MgEntry} extra="lineage · 위→아래 인과 흐름" />
      <div class="mg-rail" role="list" aria-label=${ariaLabel}>
        ${steps.map((step, i) => {
          const n = nodes[step.id]
          const t = n ? nodeTypes[n.type] : undefined
          if (!n || !t) return null
          return html`
            <div
              key=${step.id}
              class=${cx('mg-step', step.anchor && 'is-anchor')}
              style=${{ '--nc': t.c }}
              role="listitem"
            >
              <div class="mg-spine">
                <span class="mg-time mono">${step.t}</span>
                <span class="mg-knot"><span class="g">${t.g}</span></span>
                ${i < steps.length - 1 ? html`<span class="mg-wire" />` : null}
              </div>
              <div class="mg-step-body">
                <div class="mg-rel mono">${step.rel}</div>
                <div class="mg-step-card ss-card">
                  <div class="mg-node-top">
                    <span class="mg-type"><span class="g">${t.g}</span>${t.kr}</span>
                    ${step.anchor ? html`<span class="mg-anchor-tag mono">진입 지점</span>` : null}
                  </div>
                  <div class="mg-title">${n.title}</div>
                  <div class="mg-node-foot">
                    <${MgSig} kp=${n.kp} keepers=${keepers} size=${15} />
                    <span class="mono ns">⌗ ${n.ns}</span>
                    <span class="mono meta2">${n.meta}</span>
                  </div>
                </div>
              </div>
            </div>
          `
        })}
      </div>
      <${MgLegend} nodeTypes=${nodeTypes} />
    </div>
  `
}
