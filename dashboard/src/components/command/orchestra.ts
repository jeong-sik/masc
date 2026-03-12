import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef, useState } from 'preact/hooks'
import type {
  CommandPlaneOrchestraEdge,
  CommandPlaneOrchestraNode,
  CommandPlaneOrchestraResponse,
  CommandPlaneOrchestraSignal,
  CommandPlaneSurface,
} from '../../types'
import {
  commandPlaneOrchestra,
  commandPlaneOrchestraError,
  commandPlaneOrchestraLoading,
  setCommandPlaneSurface,
} from '../../command-store'
import { navigate } from '../../router'
import { PanelSemanticDetails } from '../common/semantic-layer'
import {
  relativeTime,
  surfaceRouteParams,
  toneClass,
} from './helpers'

const orchestraSelection = signal<string | null>(null)
const orchestraDensity = signal<'balanced' | 'compact'>('compact')
const orchestraCamera = signal({ zoom: 1, panX: 0, panY: 0 })
const orchestraDragging = signal(false)
const orchestraHasInteracted = signal(false)

type Point = { x: number; y: number }
type Bounds = { minX: number; minY: number; maxX: number; maxY: number; width: number; height: number }
type SignalPoint = { signalNode: CommandPlaneOrchestraSignal; x: number; y: number }

const DEFAULT_VIEWPORT = { width: 1280, height: 760 }
const ZOOM_MIN = 0.42
const ZOOM_MAX = 1.9

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value))
}

function truncateText(value: string | null | undefined, maxLength: number): string | null {
  const trimmed = value?.trim()
  if (!trimmed) return null
  if (trimmed.length <= maxLength) return trimmed
  return `${trimmed.slice(0, Math.max(1, maxLength - 1))}…`
}

function densityLabel(mode: 'balanced' | 'compact'): string {
  return mode === 'compact' ? '집약' : '균형'
}

function orchestraNodeKindLabel(kind?: string | null): string {
  switch ((kind ?? '').trim().toLowerCase()) {
    case 'room':
      return '룸'
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

function spreadX(count: number, min: number, max: number): number[] {
  if (count <= 0) return []
  if (count === 1) return [Math.round((min + max) / 2)]
  const step = (max - min) / (count - 1)
  return Array.from({ length: count }, (_, idx) => Math.round(min + idx * step))
}

function groupBy<T>(items: T[], getKey: (item: T) => string): Map<string, T[]> {
  const out = new Map<string, T[]>()
  for (const item of items) {
    const key = getKey(item)
    const bucket = out.get(key) ?? []
    bucket.push(item)
    out.set(key, bucket)
  }
  return out
}

function layoutConfig(density: 'balanced' | 'compact') {
  if (density === 'compact') {
    return {
      room: { x: 660, y: 108 },
      sessions: { y: 228, min: 220, max: 1110 },
      operations: { y: 338, min: 260, max: 1050 },
      detachments: { y: 430, min: 310, max: 1000 },
      lanes: { y: 540, min: 220, max: 1110 },
      worker: { perRow: 5, xSpacing: 60, ySpacing: 52, laneOffsetY: 76, freeBaseY: 662 },
      keeper: { startX: 1180, colSpacing: 92, rowSpacing: 90, startY: 176, columns: 2 },
      signalRadius: 116,
    }
  }

  return {
    room: { x: 700, y: 112 },
    sessions: { y: 236, min: 240, max: 1140 },
    operations: { y: 356, min: 300, max: 1080 },
    detachments: { y: 454, min: 340, max: 1030 },
    lanes: { y: 584, min: 230, max: 1110 },
    worker: { perRow: 4, xSpacing: 72, ySpacing: 60, laneOffsetY: 82, freeBaseY: 720 },
    keeper: { startX: 1210, colSpacing: 108, rowSpacing: 102, startY: 188, columns: 2 },
    signalRadius: 132,
  }
}

function nodeSize(node: CommandPlaneOrchestraNode, density: 'balanced' | 'compact'): { width: number; height: number; radius: number } {
  if (node.kind === 'room') {
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

function layout(orchestra: CommandPlaneOrchestraResponse, density: 'balanced' | 'compact'): Map<string, Point> {
  const cfg = layoutConfig(density)
  const positions = new Map<string, Point>()
  const nodes = orchestra.nodes
  const roomNode = nodes.find(node => node.kind === 'room') ?? null
  const sessions = nodes.filter(node => node.kind === 'session')
  const operations = nodes.filter(node => node.kind === 'operation')
  const detachments = nodes.filter(node => node.kind === 'detachment')
  const lanes = nodes.filter(node => node.kind === 'lane')
  const workers = nodes.filter(node => node.kind === 'worker')
  const keepers = nodes.filter(node => node.kind === 'keeper')

  if (roomNode) positions.set(roomNode.id, { x: cfg.room.x, y: cfg.room.y })

  spreadX(sessions.length, cfg.sessions.min, cfg.sessions.max).forEach((x, idx) => {
    const node = sessions[idx]
    if (node) positions.set(node.id, { x, y: cfg.sessions.y })
  })

  spreadX(operations.length, cfg.operations.min, cfg.operations.max).forEach((x, idx) => {
    const node = operations[idx]
    if (node) positions.set(node.id, { x, y: cfg.operations.y })
  })

  spreadX(detachments.length, cfg.detachments.min, cfg.detachments.max).forEach((x, idx) => {
    const node = detachments[idx]
    if (node) positions.set(node.id, { x, y: cfg.detachments.y })
  })

  spreadX(lanes.length, cfg.lanes.min, cfg.lanes.max).forEach((x, idx) => {
    const node = lanes[idx]
    if (node) positions.set(node.id, { x, y: cfg.lanes.y })
  })

  const laneCenters = new Map(
    lanes
      .map(node => {
        const point = positions.get(node.id)
        return point ? [node.id, point.x] as const : null
      })
      .filter((entry): entry is readonly [string, number] => entry !== null),
  )

  const workerBuckets = groupBy(workers, worker => {
    if (worker.lane_id) return `lane:${worker.lane_id}`
    if (worker.parent_id) return worker.parent_id
    return 'free'
  })

  let freeWorkerColumn = 0
  for (const [bucketId, bucket] of workerBuckets) {
    let xCenter = laneCenters.get(bucketId.replace(/^lane:/, ''))
    if (xCenter == null) {
      const parentPoint = positions.get(bucketId)
      xCenter = parentPoint?.x
    }
    if (xCenter == null) {
      xCenter = 260 + (freeWorkerColumn % 4) * 180
      freeWorkerColumn += 1
    }

    const rows = Math.max(1, Math.ceil(bucket.length / cfg.worker.perRow))
    for (let row = 0; row < rows; row += 1) {
      const rowItems = bucket.slice(row * cfg.worker.perRow, (row + 1) * cfg.worker.perRow)
      const rowWidth = (rowItems.length - 1) * cfg.worker.xSpacing
      const rowStartX = xCenter - rowWidth / 2
      rowItems.forEach((worker, idx) => {
        positions.set(worker.id, {
          x: Math.round(rowStartX + idx * cfg.worker.xSpacing),
          y:
            bucketId === 'free'
              ? cfg.worker.freeBaseY + row * cfg.worker.ySpacing
              : (positions.get(bucketId.replace(/^lane:/, ''))?.y ?? cfg.lanes.y)
                + cfg.worker.laneOffsetY
                + row * cfg.worker.ySpacing,
        })
      })
    }
  }

  keepers.forEach((keeper, idx) => {
    const col = idx % cfg.keeper.columns
    const row = Math.floor(idx / cfg.keeper.columns)
    positions.set(keeper.id, {
      x: cfg.keeper.startX + col * cfg.keeper.colSpacing,
      y: cfg.keeper.startY + row * cfg.keeper.rowSpacing,
    })
  })

  return positions
}

function signalPoints(
  orchestra: CommandPlaneOrchestraResponse,
  roomPoint: Point | null,
  density: 'balanced' | 'compact',
): SignalPoint[] {
  if (!roomPoint || orchestra.signals.length === 0) return []
  const cfg = layoutConfig(density)
  return orchestra.signals.slice(0, 6).map((signalNode, idx) => {
    const angle = (-130 + idx * 36) * (Math.PI / 180)
    return {
      signalNode,
      x: Math.round(roomPoint.x + Math.cos(angle) * cfg.signalRadius),
      y: Math.round(roomPoint.y + Math.sin(angle) * cfg.signalRadius),
    }
  })
}

function orchestraBounds(
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
    if (node.kind === 'room') {
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

function fitCamera(bounds: Bounds, viewport: { width: number; height: number }, density: 'balanced' | 'compact') {
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

function edgePath(source: Point, target: Point): string {
  const midX = (source.x + target.x) / 2
  const curve = target.y >= source.y ? 32 : -32
  return `M ${source.x} ${source.y} C ${midX} ${source.y + curve}, ${midX} ${target.y - curve}, ${target.x} ${target.y}`
}

function jumpTo(tab: string, surface: CommandPlaneSurface | string | null | undefined, params: Record<string, string>): void {
  if (tab === 'command') {
    if (surface) {
      setCommandPlaneSurface(surface as CommandPlaneSurface)
      navigate('command', { ...surfaceRouteParams(surface as CommandPlaneSurface), ...params })
      return
    }
    navigate('command', params)
    return
  }
  if (tab === 'intervene') {
    navigate('intervene', params)
    return
  }
  navigate('command', params)
}

function OrchestraSignals({
  signalNodes,
  roomPoint,
  onSelect,
}: {
  signalNodes: SignalPoint[]
  roomPoint: Point | null
  onSelect: (id: string) => void
}) {
  if (!roomPoint || signalNodes.length === 0) return null
  return html`
    ${signalNodes.map(({ signalNode, x, y }) => html`
      <g
        key=${signalNode.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${toneClass(signalNode.tone)}`}
        onClick=${() => onSelect(signalNode.id)}
      >
        <title>${signalNode.label}${signalNode.detail ? ` — ${signalNode.detail}` : ''}</title>
        <line x1=${roomPoint.x} y1=${roomPoint.y} x2=${x} y2=${y} class="orchestra-signal-link" />
        <circle cx=${x} cy=${y} r="16" class="orchestra-signal-dot" />
        <text x=${x} y=${y + 4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `
}

function OrchestraEdgeLayer({
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

function OrchestraNodeLayer({
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
      if (node.kind === 'room') {
        return html`
          <g
            key=${node.id}
            data-orchestra-node="true"
            class=${`orchestra-node room ${toneClass(node.tone)} ${selected ? 'selected' : ''} ${focused ? 'focused' : ''}`}
            onClick=${() => onSelect(node.id)}
          >
            <title>${node.label}</title>
            <circle cx=${point.x} cy=${point.y} r=${size.radius} class="orchestra-room-ring outer" />
            <circle cx=${point.x} cy=${point.y} r=${size.radius - 16} class="orchestra-room-ring inner" />
            <text x=${point.x} y=${point.y - 10} text-anchor="middle" class="orchestra-room-glyph">${node.glyph ?? '◎'}</text>
            <text x=${point.x} y=${point.y + 22} text-anchor="middle" class="orchestra-room-label">${label}</text>
          </g>
        `
      }
      const x = point.x - size.width / 2
      const y = point.y - size.height / 2
      return html`
        <g
          key=${node.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${visualClass} ${toneClass(node.tone)} ${selected ? 'selected' : ''} ${focused ? 'focused' : ''}`}
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

function selectedTarget(
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

function OrchestraDetailDrawer({ orchestra }: { orchestra: CommandPlaneOrchestraResponse }) {
  const selected = selectedTarget(orchestra)
  if (!selected) return html`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`
  if (selected.type === 'signal') {
    const signalNode = selected.value
    return html`
      <aside class="orchestra-drawer card ${toneClass(signalNode.tone)}">
        <div class="card-title-row">
          <div class="card-title">${signalNode.label}</div>
          <span class="command-chip ${toneClass(signalNode.tone)}">${orchestraNodeKindLabel(signalNode.kind)}</span>
        </div>
        <p>${signalNode.detail ?? '세부 설명이 없습니다.'}</p>
        ${signalNode.suggested_surface
          ? html`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${() => jumpTo('command', signalNode.suggested_surface, signalNode.suggested_params ?? {})}
                >
                  추천 화면 열기
                </button>
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
    <aside class="orchestra-drawer card ${toneClass(node.tone)}">
      <div class="card-title-row">
        <div class="card-title">${node.label}</div>
        <span class="command-chip ${toneClass(node.tone)}">${orchestraNodeKindLabel(node.kind)}</span>
      </div>
      ${node.subtitle ? html`<p class="command-card-sub">${node.subtitle}</p>` : null}
      <div class="orchestra-fact-list">
        ${node.facts.map(factRow => html`
          <div class="orchestra-fact-row">
            <span>${factRow.label}</span>
            <strong>${factRow.value}</strong>
          </div>
        `)}
      </div>
      ${relatedSignals.length > 0 ? html`
        <div class="command-tag-row">
          ${relatedSignals.map(signalNode => html`<span class="command-chip ${toneClass(signalNode.tone)}">${signalNode.label}</span>`)}
        </div>
      ` : null}
      <div class="command-card-sub">연결 ${relatedEdges.length}개 · 근거 ${node.provenance}</div>
      ${(node.link_tab && (node.link_surface || Object.keys(node.link_params ?? {}).length > 0))
        ? html`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${() => jumpTo(node.link_tab ?? 'command', node.link_surface, node.link_params ?? {})}
              >
                이 화면 열기
              </button>
            </div>
          `
        : null}
    </aside>
  `
}

export function OrchestraSurface() {
  const orchestra = commandPlaneOrchestra.value
  const hostRef = useRef<HTMLDivElement | null>(null)
  const dragRef = useRef<{ pointerId: number; startX: number; startY: number; panX: number; panY: number } | null>(null)
  const lastAutoFitKeyRef = useRef<string>('')
  const [viewport, setViewport] = useState(DEFAULT_VIEWPORT)

  useEffect(() => {
    const host = hostRef.current
    if (!host) return undefined

    const measure = () => {
      const rect = host.getBoundingClientRect()
      if (rect.width <= 0 || rect.height <= 0) return
      setViewport({
        width: Math.max(640, Math.round(rect.width)),
        height: Math.max(480, Math.round(rect.height)),
      })
    }

    measure()

    if (typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', measure)
      return () => window.removeEventListener('resize', measure)
    }

    const observer = new ResizeObserver(() => measure())
    observer.observe(host)
    return () => observer.disconnect()
  }, [])

  if (commandPlaneOrchestraLoading.value && !orchestra) {
    return html`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`
  }
  if (commandPlaneOrchestraError.value) {
    return html`<section class="card command-section"><div class="empty-state error">${commandPlaneOrchestraError.value}</div></section>`
  }
  if (!orchestra) {
    return html`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`
  }

  const density = orchestraDensity.value
  const positions = layout(orchestra, density)
  const roomNode = orchestra.nodes.find(node => node.kind === 'room') ?? null
  const roomPoint = roomNode ? positions.get(roomNode.id) ?? null : null
  const signalNodes = signalPoints(orchestra, roomPoint, density)
  const bounds = orchestraBounds(orchestra, positions, signalNodes, density)
  const selected = selectedTarget(orchestra)
  const selectedId = selected?.value.id ?? null
  const fitKey = `${density}:${viewport.width}x${viewport.height}:${orchestra.nodes.length}:${orchestra.edges.length}:${orchestra.signals.length}`

  const setCamera = (next: { zoom: number; panX: number; panY: number }, interacted: boolean) => {
    orchestraCamera.value = next
    orchestraHasInteracted.value = interacted
  }

  const applyFit = () => {
    setCamera(fitCamera(bounds, viewport, density), false)
  }

  const resetView = () => {
    orchestraSelection.value = null
    if (density !== 'compact') {
      orchestraDensity.value = 'compact'
      orchestraHasInteracted.value = false
      return
    }
    applyFit()
  }

  useEffect(() => {
    if (selectedId && !orchestra.nodes.some(node => node.id === selectedId) && !orchestra.signals.some(signalNode => signalNode.id === selectedId)) {
      orchestraSelection.value = null
    }
  }, [fitKey, selectedId, orchestra])

  useEffect(() => {
    if (!orchestraHasInteracted.value || lastAutoFitKeyRef.current !== fitKey) {
      setCamera(fitCamera(bounds, viewport, density), false)
      lastAutoFitKeyRef.current = fitKey
    }
  }, [fitKey])

  const camera = orchestraCamera.value

  const zoomAround = (anchorX: number, anchorY: number, factor: number) => {
    const currentZoom = orchestraCamera.value.zoom
    const nextZoom = clamp(currentZoom * factor, ZOOM_MIN, ZOOM_MAX)
    if (Math.abs(nextZoom - currentZoom) < 0.001) return
    const worldX = (anchorX - orchestraCamera.value.panX) / currentZoom
    const worldY = (anchorY - orchestraCamera.value.panY) / currentZoom
    setCamera({
      zoom: nextZoom,
      panX: anchorX - worldX * nextZoom,
      panY: anchorY - worldY * nextZoom,
    }, true)
  }

  const handleWheel = (event: WheelEvent) => {
    event.preventDefault()
    const host = hostRef.current
    if (!host) return
    const rect = host.getBoundingClientRect()
    const anchorX = clamp(event.clientX - rect.left, 0, rect.width)
    const anchorY = clamp(event.clientY - rect.top, 0, rect.height)
    zoomAround(anchorX, anchorY, event.deltaY < 0 ? 1.1 : 0.92)
  }

  const handlePointerDown = (event: PointerEvent) => {
    const target = event.target
    if (!(target instanceof Element)) return
    if (!target.closest('[data-orchestra-background="true"]')) return
    const currentTarget = event.currentTarget as HTMLDivElement | null
    if (!currentTarget) return
    dragRef.current = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      panX: orchestraCamera.value.panX,
      panY: orchestraCamera.value.panY,
    }
    orchestraDragging.value = true
    orchestraHasInteracted.value = true
    currentTarget.setPointerCapture?.(event.pointerId)
  }

  const handlePointerMove = (event: PointerEvent) => {
    const drag = dragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    setCamera({
      zoom: orchestraCamera.value.zoom,
      panX: drag.panX + (event.clientX - drag.startX),
      panY: drag.panY + (event.clientY - drag.startY),
    }, true)
  }

  const stopDrag = (event?: PointerEvent) => {
    if (!dragRef.current) return
    const currentTarget = event?.currentTarget as HTMLDivElement | null | undefined
    if (currentTarget && event) currentTarget.releasePointerCapture?.(event.pointerId)
    dragRef.current = null
    orchestraDragging.value = false
  }

  return html`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${PanelSemanticDetails} panelId="command.orchestra" compact=${true} />
      </div>
      <p class="command-card-sub">
        룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 확대/이동으로 밀집 구간을 읽고, 노드를 눌러 상세 신호와 연결 대상을 확인합니다.
      </p>

      <div class="orchestra-toolbar">
        <div class="orchestra-toolbar-group">
          <button class="control-btn ghost" onClick=${applyFit}>맞춤 보기</button>
          <button class="control-btn ghost" onClick=${resetView}>초기화</button>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class="control-btn ghost"
            onClick=${() => zoomAround(viewport.width / 2, viewport.height / 2, 1.12)}
          >
            확대
          </button>
          <button
            class="control-btn ghost"
            onClick=${() => zoomAround(viewport.width / 2, viewport.height / 2, 0.9)}
          >
            축소
          </button>
          <span class="command-chip">${Math.round(camera.zoom * 100)}%</span>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class=${`control-btn ${density === 'balanced' ? 'is-active' : 'ghost'}`}
            onClick=${() => {
              orchestraDensity.value = 'balanced'
              orchestraSelection.value = selectedId
            }}
          >
            균형
          </button>
          <button
            class=${`control-btn ${density === 'compact' ? 'is-active' : 'ghost'}`}
            onClick=${() => {
              orchestraDensity.value = 'compact'
              orchestraSelection.value = selectedId
            }}
          >
            집약
          </button>
          <span class="command-chip">${densityLabel(density)}</span>
        </div>
      </div>

      <div class="orchestra-shell">
        <div
          ref=${hostRef}
          class="orchestra-canvas-wrap"
          onWheel=${handleWheel}
          onPointerDown=${handlePointerDown}
          onPointerMove=${handlePointerMove}
          onPointerUp=${stopDrag}
          onPointerCancel=${stopDrag}
          onPointerLeave=${() => stopDrag()}
        >
          <svg
            class=${`orchestra-canvas ${orchestraDragging.value ? 'is-dragging' : ''}`}
            viewBox=${`0 0 ${viewport.width} ${viewport.height}`}
            preserveAspectRatio="xMidYMid meet"
          >
            <defs>
              <pattern id="orchestra-grid" width="32" height="32" patternUnits="userSpaceOnUse">
                <path d="M 32 0 L 0 0 0 32" fill="none" class="orchestra-grid-line"></path>
              </pattern>
            </defs>
            <rect
              data-orchestra-background="true"
              width=${viewport.width}
              height=${viewport.height}
              fill="url(#orchestra-grid)"
              class="orchestra-grid"
            ></rect>
            <g transform=${`translate(${camera.panX} ${camera.panY}) scale(${camera.zoom})`}>
              <${OrchestraEdgeLayer} edges=${orchestra.edges} positions=${positions} selectedId=${selectedId} />
              <${OrchestraSignals} signalNodes=${signalNodes} roomPoint=${roomPoint} onSelect=${(id: string) => { orchestraSelection.value = id }} />
              <${OrchestraNodeLayer}
                orchestra=${orchestra}
                positions=${positions}
                density=${density}
                selectedId=${selectedId}
                onSelect=${(id: string) => { orchestraSelection.value = id }}
              />
            </g>
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${orchestra.summary?.session_count ?? 0}</span>
            <span class="command-chip">워커 ${orchestra.summary?.worker_count ?? 0}</span>
            <span class="command-chip">키퍼 ${orchestra.summary?.keeper_count ?? 0}</span>
            <span class="command-chip ${toneClass(orchestra.signals.some(signalNode => signalNode.tone === 'bad') ? 'bad' : orchestra.signals.length > 0 ? 'warn' : 'ok')}">
              신호 ${orchestra.summary?.signal_count ?? orchestra.signals.length}
            </span>
            <span class="command-chip">갱신 ${relativeTime(orchestra.generated_at)}</span>
          </div>
        </div>

        <${OrchestraDetailDrawer} orchestra=${orchestra} />
      </div>
    </section>
  `
}
