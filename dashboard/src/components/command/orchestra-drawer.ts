import { html } from 'htm/preact'
import { ActionButton } from '../common/button'
import { EmptyState } from '../common/empty-state'
import { StatusChip } from '../common/status-chip'
import type {
  CommandPlaneOrchestraEdge,
  CommandPlaneOrchestraNode,
  CommandPlaneOrchestraResponse,
  CommandPlaneOrchestraSignal,
  CommandPlaneSurface,
} from '../../types'
import { setCommandPlaneSurface } from '../../command-store'
import { navigate } from '../../router'
import { surfaceRouteParams, toneClass } from './helpers'
import { orchestraSelection } from './orchestra-signals'

// ── Constants ──────────────────────────────

export const DEFAULT_VIEWPORT = { width: 1280, height: 760 }
export const ZOOM_MIN = 0.42
export const ZOOM_MAX = 1.9

export function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value))
}

// ── Pure helpers ──────────────────────────────

function truncateText(value: string | null | undefined, maxLength: number): string | null {
  const trimmed = value?.trim()
  if (!trimmed) return null
  if (trimmed.length <= maxLength) return trimmed
  return `${trimmed.slice(0, Math.max(1, maxLength - 1))}…`
}

export function orchestraNodeKindLabel(kind?: string | null): string {
  switch ((kind ?? '').trim().toLowerCase()) {
    case 'namespace':
      return '프로젝트'
    case 'session':
      return '세션'
    case 'operation':
      return '작전'
    case 'detachment':
      return '분견대'
    case 'lane':
      return '레인'
    case 'worker':
      return '워커'
    case 'keeper':
      return '키퍼'
    default:
      return kind?.trim() || '노드'
  }
}

function jumpTo(tab: string, surface: CommandPlaneSurface | string | null | undefined, params: Record<string, string>): void {
  const nextParams = { ...params }
  delete nextParams.section
  delete nextParams.surface
  if (tab === 'command') {
    if (surface) {
      setCommandPlaneSurface(surface as CommandPlaneSurface)
      navigate('command', { ...surfaceRouteParams(surface as CommandPlaneSurface), ...nextParams })
      return
    }
    navigate('command', { section: 'intervene', ...nextParams })
    return
  }
  if (tab === 'intervene') {
    navigate('command', { section: 'intervene', ...nextParams })
    return
  }
  navigate('command', { section: 'intervene', ...nextParams })
}

// ── Node rendering helpers ──────────────────────────────

export function nodeSize(node: CommandPlaneOrchestraNode, density: 'balanced' | 'compact'): { width: number; height: number; radius: number } {
  if (node.kind === 'namespace') {
    return density === 'compact'
      ? { width: 138, height: 138, radius: 68 }
      : { width: 156, height: 156, radius: 76 }
  }
  if (node.kind === 'worker') {
    return density === 'compact'
      ? { width: 70, height: 36, radius: 18 }
      : { width: 84, height: 44, radius: 22 }
  }
  if (node.kind === 'lane') {
    return density === 'compact'
      ? { width: 156, height: 48, radius: 15 }
      : { width: 176, height: 56, radius: 17 }
  }
  if (node.kind === 'keeper') {
    return density === 'compact'
      ? { width: 118, height: 50, radius: 22 }
      : { width: 132, height: 60, radius: 24 }
  }
  if (node.kind === 'session') {
    return density === 'compact'
      ? { width: 182, height: 58, radius: 17 }
      : { width: 202, height: 68, radius: 18 }
  }
  return density === 'compact'
    ? { width: 176, height: 58, radius: 16 }
    : { width: 196, height: 68, radius: 18 }
}

function nodeLabel(node: CommandPlaneOrchestraNode, density: 'balanced' | 'compact'): string {
  const maxLength =
    node.kind === 'worker'
      ? (density === 'compact' ? 10 : 14)
      : node.kind === 'keeper'
        ? (density === 'compact' ? 12 : 16)
        : node.kind === 'lane'
          ? (density === 'compact' ? 16 : 22)
          : (density === 'compact' ? 18 : 26)
  return truncateText(node.label, maxLength) ?? node.label
}

function nodeSubtitle(node: CommandPlaneOrchestraNode, density: 'balanced' | 'compact'): string | null {
  if (density === 'compact' && (node.kind === 'worker' || node.kind === 'keeper' || node.kind === 'detachment')) {
    return null
  }
  const maxLength =
    node.kind === 'session'
      ? (density === 'compact' ? 20 : 28)
      : (density === 'compact' ? 14 : 24)
  return truncateText(node.subtitle, maxLength)
}

function nodeStatus(node: CommandPlaneOrchestraNode, density: 'balanced' | 'compact'): string | null {
  if (density === 'compact' && node.kind !== 'session' && node.kind !== 'operation') return null
  return truncateText(node.status, density === 'compact' ? 10 : 14)
}

function edgePath(source: { x: number; y: number }, target: { x: number; y: number }): string {
  const midX = (source.x + target.x) / 2
  const curve = target.y >= source.y ? 32 : -32
  return `M ${source.x} ${source.y} C ${midX} ${source.y + curve}, ${midX} ${target.y - curve}, ${target.x} ${target.y}`
}

// ── Selection logic ──────────────────────────────

export function selectedTarget(
  orchestra: CommandPlaneOrchestraResponse,
): { type: 'node'; value: CommandPlaneOrchestraNode } | { type: 'signal'; value: CommandPlaneOrchestraSignal } | null {
  const current = orchestraSelection.value
  if (current) {
    const foundNode = orchestra.nodes.find(node => node.id === current)
    if (foundNode) return { type: 'node', value: foundNode }
    const foundSignal = orchestra.signals.find(signalNode => signalNode.id === current)
    if (foundSignal) return { type: 'signal', value: foundSignal }
  }
  if (orchestra.focus?.target_kind === 'node') {
    const found = orchestra.nodes.find(node => node.id === orchestra.focus?.target_id)
    if (found) return { type: 'node', value: found }
  }
  if (orchestra.focus?.target_kind === 'signal') {
    const found = orchestra.signals.find(signalNode => signalNode.id === orchestra.focus?.target_id)
    if (found) return { type: 'signal', value: found }
  }
  const firstNode = orchestra.nodes[0]
  return firstNode ? { type: 'node', value: firstNode } : null
}

// ── Layout computation ──────────────────────────────

type Point = { x: number; y: number }
type Bounds = { minX: number; minY: number; maxX: number; maxY: number; width: number; height: number }
type SignalPoint = { signalNode: CommandPlaneOrchestraSignal; x: number; y: number }

export function orchestraBounds(
  orchestra: CommandPlaneOrchestraResponse,
  positions: Map<string, Point>,
  signalNodes: SignalPoint[],
  density: 'balanced' | 'compact',
): Bounds {
  let minX = Number.POSITIVE_INFINITY
  let maxX = Number.NEGATIVE_INFINITY
  let minY = Number.POSITIVE_INFINITY
  let maxY = Number.NEGATIVE_INFINITY

  for (const node of orchestra.nodes) {
    const point = positions.get(node.id)
    if (!point) continue
    const size = nodeSize(node, density)
    if (node.kind === 'namespace') {
      minX = Math.min(minX, point.x - size.radius)
      maxX = Math.max(maxX, point.x + size.radius)
      minY = Math.min(minY, point.y - size.radius)
      maxY = Math.max(maxY, point.y + size.radius)
    } else {
      minX = Math.min(minX, point.x - size.width / 2)
      maxX = Math.max(maxX, point.x + size.width / 2)
      minY = Math.min(minY, point.y - size.height / 2)
      maxY = Math.max(maxY, point.y + size.height / 2)
    }
  }

  for (const signalNode of signalNodes) {
    minX = Math.min(minX, signalNode.x - 20)
    maxX = Math.max(maxX, signalNode.x + 20)
    minY = Math.min(minY, signalNode.y - 20)
    maxY = Math.max(maxY, signalNode.y + 20)
  }

  if (!Number.isFinite(minX) || !Number.isFinite(maxX) || !Number.isFinite(minY) || !Number.isFinite(maxY)) {
    return {
      minX: 0,
      minY: 0,
      maxX: DEFAULT_VIEWPORT.width,
      maxY: DEFAULT_VIEWPORT.height,
      width: DEFAULT_VIEWPORT.width,
      height: DEFAULT_VIEWPORT.height,
    }
  }

  return {
    minX,
    minY,
    maxX,
    maxY,
    width: Math.max(1, maxX - minX),
    height: Math.max(1, maxY - minY),
  }
}

export function fitCamera(bounds: Bounds, viewport: { width: number; height: number }, density: 'balanced' | 'compact') {
  const padding = density === 'compact' ? 48 : 72
  const safeWidth = Math.max(360, viewport.width - padding * 2)
  const safeHeight = Math.max(280, viewport.height - padding * 2)
  const zoom = clamp(
    Math.min(safeWidth / Math.max(bounds.width, 1), safeHeight / Math.max(bounds.height, 1)),
    ZOOM_MIN,
    ZOOM_MAX,
  )
  const centerX = bounds.minX + bounds.width / 2
  const centerY = bounds.minY + bounds.height / 2
  return {
    zoom,
    panX: viewport.width / 2 - centerX * zoom,
    panY: viewport.height / 2 - centerY * zoom,
  }
}

// ── SVG sub-components ──────────────────────────────

export function OrchestraSignals({
  signalNodes,
  namespacePoint,
  onSelect,
}: {
  signalNodes: SignalPoint[]
  namespacePoint: Point | null
  onSelect: (id: string) => void
}) {
  if (!namespacePoint || signalNodes.length === 0) return null
  return html`
    ${signalNodes.map(({ signalNode, x, y }) => html`
      <g
        key=${signalNode.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${toneClass(signalNode.tone)}`}
        onClick=${() => onSelect(signalNode.id)}
      >
        <title>${signalNode.label}${signalNode.detail ? ` — ${signalNode.detail}` : ''}</title>
        <line x1=${namespacePoint.x} y1=${namespacePoint.y} x2=${x} y2=${y} class="orchestra-signal-link" />
        <circle cx=${x} cy=${y} r="16" class="orchestra-signal-dot" />
        <text x=${x} y=${y + 4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `
}

export function OrchestraEdgeLayer({
  edges,
  positions,
  selectedId,
}: {
  edges: CommandPlaneOrchestraEdge[]
  positions: Map<string, Point>
  selectedId: string | null
}) {
  return html`
    ${edges.map(edge => {
      const source = positions.get(edge.source)
      const target = positions.get(edge.target)
      if (!source || !target) return null
      const active = selectedId != null && (edge.source === selectedId || edge.target === selectedId)
      return html`
        <path
          key=${edge.id}
          d=${edgePath(source, target)}
          class=${`orchestra-edge ${toneClass(edge.tone)} ${edge.animated ? 'animated' : ''} ${active ? 'active' : ''}`}
        />
      `
    })}
  `
}

export function OrchestraNodeLayer({
  orchestra,
  positions,
  density,
  selectedId,
  onSelect,
}: {
  orchestra: CommandPlaneOrchestraResponse
  positions: Map<string, Point>
  density: 'balanced' | 'compact'
  selectedId: string | null
  onSelect: (id: string) => void
}) {
  const focusId = orchestra.focus?.target_kind === 'node' ? orchestra.focus.target_id : null
  return html`
    ${orchestra.nodes.map(node => {
      const point = positions.get(node.id)
      if (!point) return null
      const size = nodeSize(node, density)
      const selected = node.id === selectedId
      const focused = node.id === focusId
      const visualClass = node.visual_class ?? node.kind
      const label = nodeLabel(node, density)
      const subtitle = nodeSubtitle(node, density)
      const status = nodeStatus(node, density)
      if (node.kind === 'namespace') {
        return html`
          <g
            key=${node.id}
            data-orchestra-node="true"
            class=${`orchestra-node namespace cursor-pointer ${toneClass(node.tone)} ${selected ? 'selected' : ''} ${focused ? 'focused' : ''}`}
            onClick=${() => onSelect(node.id)}
          >
            <title>${node.label}</title>
            <circle cx=${point.x} cy=${point.y} r=${size.radius} class="orchestra-namespace-ring outer" />
            <circle cx=${point.x} cy=${point.y} r=${size.radius - 16} class="orchestra-namespace-ring inner" />
            <text x=${point.x} y=${point.y - 10} text-anchor="middle" class="orchestra-namespace-glyph">${node.glyph ?? '◎'}</text>
            <text x=${point.x} y=${point.y + 22} text-anchor="middle" class="orchestra-namespace-label">${label}</text>
          </g>
        `
      }
      const x = point.x - size.width / 2
      const y = point.y - size.height / 2
      return html`
        <g
          key=${node.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${visualClass} cursor-pointer ${toneClass(node.tone)} ${selected ? 'selected' : ''} ${focused ? 'focused' : ''}`}
          onClick=${() => onSelect(node.id)}
        >
          <title>${node.label}${node.subtitle ? ` — ${node.subtitle}` : ''}${node.status ? ` (${node.status})` : ''}</title>
          <rect x=${x} y=${y} width=${size.width} height=${size.height} rx=${size.radius} class="orchestra-node-body" />
          <text x=${x + 16} y=${y + 24} class="orchestra-node-glyph">${node.glyph ?? '•'}</text>
          <text x=${x + 38} y=${y + 24} class="orchestra-node-label">${label}</text>
          ${subtitle ? html`<text x=${x + 38} y=${y + 42} class="orchestra-node-subtitle">${subtitle}</text>` : null}
          ${status ? html`<text x=${x + size.width - 10} y=${y + 18} text-anchor="end" class="orchestra-node-status">${status}</text>` : null}
        </g>
      `
    })}
  `
}

// ── Drawer component ──────────────────────────────

export function OrchestraDetailDrawer({ orchestra }: { orchestra: CommandPlaneOrchestraResponse }) {
  const selected = selectedTarget(orchestra)
  if (!selected) return html`<aside class="orchestra-drawer flex flex-col gap-3 min-h-[720px] card rounded-xl"><${EmptyState} message="선택 가능한 대상이 아직 없습니다." compact /></aside>`
  if (selected.type === 'signal') {
    const signalNode = selected.value
    return html`
      <aside class="orchestra-drawer flex flex-col gap-3 min-h-[720px] card rounded-xl ${toneClass(signalNode.tone)}">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">${signalNode.label}</div>
          <${StatusChip} label=${orchestraNodeKindLabel(signalNode.kind)} tone=${toneClass(signalNode.tone)} />
        </div>
        <p>${signalNode.detail ?? '세부 설명이 없습니다.'}</p>
        ${signalNode.suggested_surface
          ? html`
              <div class="flex gap-3 flex-wrap mt-3">
                <${ActionButton}
                  onClick=${() => jumpTo('command', signalNode.suggested_surface, signalNode.suggested_params ?? {})}
                >
                  추천 화면 열기
                <//>
              </div>
            `
          : null}
      </aside>
    `
  }

  const node = selected.value
  const relatedSignals = orchestra.signals.filter(signalNode => signalNode.source_id === node.id || signalNode.target_id === node.id)
  const relatedEdges = orchestra.edges.filter(edge => edge.source === node.id || edge.target === node.id)
  return html`
    <aside class="orchestra-drawer flex flex-col gap-3 min-h-[720px] card rounded-xl ${toneClass(node.tone)}">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">${node.label}</div>
        <${StatusChip} label=${orchestraNodeKindLabel(node.kind)} tone=${toneClass(node.tone)} />
      </div>
      ${node.subtitle ? html`<p class="cmd-card rounded-xl-sub">${node.subtitle}</p>` : null}
      <div class="orchestra-fact-list flex flex-col gap-2">
        ${node.facts.map(factRow => html`
          <div class="flex justify-between gap-3 py-2 px-2.5 rounded-[10px] bg-[var(--white-3)] border border-[var(--white-6)]">
            <span class="text-[rgba(226,232,240,0.64)] text-[0.82rem]">${factRow.label}</span>
            <strong class="text-[var(--text-near-white)] text-[0.84rem] text-right">${factRow.value}</strong>
          </div>
        `)}
      </div>
      ${relatedSignals.length > 0 ? html`
        <div class="cmd-tag rounded-full-row">
          ${relatedSignals.map(signalNode => html`<${StatusChip} label=${signalNode.label} tone=${toneClass(signalNode.tone)} />`)}
        </div>
      ` : null}
      <div class="cmd-card rounded-xl-sub">연결 ${relatedEdges.length}개 · 근거 ${node.provenance}</div>
      ${(node.link_tab && (node.link_surface || Object.keys(node.link_params ?? {}).length > 0))
        ? html`
            <div class="flex gap-3 flex-wrap mt-3">
              <${ActionButton}
                onClick=${() => jumpTo(node.link_tab ?? 'command', node.link_surface, node.link_params ?? {})}
              >
                이 화면 열기
              <//>
            </div>
          `
        : null}
    </aside>
  `
}
