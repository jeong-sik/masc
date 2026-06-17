import { html } from 'htm/preact'

export interface MemoryNodeType {
  readonly kr: string
  readonly g: string
  readonly c: string
}

export interface MemoryKeeper {
  readonly s: string
  readonly c: string
}

export interface MemoryNode {
  readonly type: string
  readonly title: string
  readonly kp: string
  readonly meta: string
  readonly ns: string
}

export function cx(...classes: Array<string | false | null | undefined>): string {
  return classes.filter(Boolean).join(' ')
}

interface SigProps {
  readonly kp: string
  readonly keepers?: Readonly<Record<string, MemoryKeeper>>
  readonly size?: number
}

export function MgSig({ kp, keepers = {}, size = 16 }: SigProps) {
  const k = keepers[kp] ?? { s: '??', c: 'var(--text-dim)' }
  return html`
    <span
      class="mg-sig"
      style=${{
        '--kc': k.c,
        width: size,
        height: size,
        fontSize: size * 0.5,
      }}
    >${k.s}</span>
  `
}

interface EntryProps {
  readonly extra?: string
}

export function MgEntry({ extra }: EntryProps) {
  return html`
    <div class="mg-entry">
      <span class="mg-entry-g">◆</span>
      <span>메모리 링크로 진입</span>
      <span class="mono dim">mem_7f3 · core/scheduler 체크포인트</span>
      ${extra ? html`<span class="mg-entry-x mono">${extra}</span>` : null}
    </div>
  `
}

interface LegendProps {
  readonly nodeTypes: Readonly<Record<string, MemoryNodeType>>
}

export function MgLegend({ nodeTypes }: LegendProps) {
  return html`
    <div class="mg-legend">
      ${Object.entries(nodeTypes).map(
        ([key, t]) => html`
          <span key=${key} class="mg-leg" style=${{ '--nc': t.c }}>
            <span class="d" />${t.kr}
          </span>
        `,
      )}
      <span class="mg-leg-sep">·</span>
      <span class="mg-leg-note mono">엣지 = 관계</span>
    </div>
  `
}

interface NodeCardProps {
  readonly node: MemoryNode
  readonly type: MemoryNodeType
  readonly keepers?: Readonly<Record<string, MemoryKeeper>>
  readonly anchor?: boolean
  readonly satellite?: boolean
  readonly onClick?: () => void
}

export function MgNodeCard({
  node,
  type,
  keepers = {},
  anchor,
  satellite,
  onClick,
}: NodeCardProps) {
  return html`
    <div
      class=${cx('mg-node ss-card', anchor && 'is-anchor', satellite && 'is-sat')}
      style=${{ '--nc': type.c }}
      onClick=${onClick}
      title=${node.title}
    >
      <div class="mg-node-top">
        <span class="mg-type"><span class="g">${type.g}</span>${type.kr}</span>
        <span class="mg-meta mono">${node.meta}</span>
      </div>
      <div class="mg-title">${node.title}</div>
      <div class="mg-node-foot">
        <${MgSig} kp=${node.kp} keepers=${keepers} size=${anchor ? 18 : 15} />
        <span class="mono ns">⌗ ${node.ns}</span>
      </div>
    </div>
  `
}
