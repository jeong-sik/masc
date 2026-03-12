import { html } from 'htm/preact'
import { signal } from '@preact/signals'
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
import { provenanceLabel } from '../common/truth-copy'
import {
  relativeTime,
  surfaceRouteParams,
  toneClass,
} from './helpers'

const orchestraSelection = signal<string | null>(null)

type Point = { x: number; y: number }

const SVG_WIDTH = 1280
const SVG_HEIGHT = 760

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

function layout(orchestra: CommandPlaneOrchestraResponse): Map<string, Point> {
  const positions = new Map<string, Point>()
  const nodes = orchestra.nodes
  const roomNode = nodes.find(node => node.kind === 'room') ?? null
  const sessions = nodes.filter(node => node.kind === 'session')
  const operations = nodes.filter(node => node.kind === 'operation')
  const detachments = nodes.filter(node => node.kind === 'detachment')
  const lanes = nodes.filter(node => node.kind === 'lane')
  const workers = nodes.filter(node => node.kind === 'worker')
  const keepers = nodes.filter(node => node.kind === 'keeper')

  if (roomNode) positions.set(roomNode.id, { x: 640, y: 96 })

  spreadX(sessions.length, 170, 1110).forEach((x, idx) => {
    const node = sessions[idx]
    if (node) positions.set(node.id, { x, y: 220 })
  })

  spreadX(operations.length, 240, 1040).forEach((x, idx) => {
    const node = operations[idx]
    if (node) positions.set(node.id, { x, y: 330 })
  })

  spreadX(detachments.length, 300, 980).forEach((x, idx) => {
    const node = detachments[idx]
    if (node) positions.set(node.id, { x, y: 420 })
  })

  spreadX(lanes.length, 170, 1110).forEach((x, idx) => {
    const node = lanes[idx]
    if (node) positions.set(node.id, { x, y: 530 })
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

  let freeWorkerRow = 0
  for (const [bucketId, bucket] of workerBuckets) {
    let xCenter = laneCenters.get(bucketId)
    if (xCenter == null) {
      const parent = positions.get(bucketId)
      xCenter = parent?.x
    }
    if (xCenter == null) {
      xCenter = 180 + (freeWorkerRow % 5) * 200
      freeWorkerRow += 1
    }
    const xs = spreadX(bucket.length, xCenter - 90, xCenter + 90)
    xs.forEach((x, idx) => {
      const worker = bucket[idx]
      if (!worker) return
      const row = idx > 5 ? Math.floor(idx / 6) : 0
      positions.set(worker.id, {
        x,
        y: 635 + row * 62,
      })
    })
  }

  const keeperXs = keepers.length > 3 ? [1120, 1180] : [1140]
  keepers.forEach((keeper, idx) => {
    const col = idx % keeperXs.length
    const row = Math.floor(idx / keeperXs.length)
    positions.set(keeper.id, {
      x: keeperXs[col] ?? 1140,
      y: 190 + row * 108,
    })
  })

  return positions
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

function nodeSize(node: CommandPlaneOrchestraNode): { width: number; height: number; radius: number } {
  switch (node.kind) {
    case 'room':
      return { width: 150, height: 150, radius: 74 }
    case 'worker':
      return { width: 78, height: 42, radius: 22 }
    case 'lane':
      return { width: 170, height: 54, radius: 16 }
    case 'keeper':
      return { width: 120, height: 56, radius: 24 }
    default:
      return { width: 188, height: 64, radius: 18 }
  }
}

function OrchestraSignals({
  orchestra,
  roomPoint,
  onSelect,
}: {
  orchestra: CommandPlaneOrchestraResponse
  roomPoint: Point | null
  onSelect: (id: string) => void
}) {
  if (!roomPoint || orchestra.signals.length === 0) return null
  const radius = 108
  return html`
    ${orchestra.signals.slice(0, 6).map((signalNode, idx) => {
      const angle = (-120 + idx * 38) * (Math.PI / 180)
      const x = Math.round(roomPoint.x + Math.cos(angle) * radius)
      const y = Math.round(roomPoint.y + Math.sin(angle) * radius)
      return html`
        <g
          key=${signalNode.id}
          class=${`orchestra-signal-node ${toneClass(signalNode.tone)}`}
          onClick=${() => onSelect(signalNode.id)}
        >
          <line x1=${roomPoint.x} y1=${roomPoint.y} x2=${x} y2=${y} class="orchestra-signal-link" />
          <circle cx=${x} cy=${y} r="16" class="orchestra-signal-dot" />
          <text x=${x} y=${y + 4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
        </g>
      `
    })}
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
  selectedId,
  onSelect,
}: {
  orchestra: CommandPlaneOrchestraResponse
  positions: Map<string, Point>
  selectedId: string | null
  onSelect: (id: string) => void
}) {
  const focusId = orchestra.focus?.target_kind === 'node' ? orchestra.focus.target_id : null
  return html`
    ${orchestra.nodes.map(node => {
      const point = positions.get(node.id)
      if (!point) return null
      const size = nodeSize(node)
      const selected = node.id === selectedId
      const focused = node.id === focusId
      if (node.kind === 'room') {
        return html`
          <g
            key=${node.id}
            class=${`orchestra-node room ${toneClass(node.tone)} ${selected ? 'selected' : ''} ${focused ? 'focused' : ''}`}
            onClick=${() => onSelect(node.id)}
          >
            <circle cx=${point.x} cy=${point.y} r=${size.radius} class="orchestra-room-ring outer" />
            <circle cx=${point.x} cy=${point.y} r=${size.radius - 16} class="orchestra-room-ring inner" />
            <text x=${point.x} y=${point.y - 10} text-anchor="middle" class="orchestra-room-glyph">${node.glyph ?? '◎'}</text>
            <text x=${point.x} y=${point.y + 22} text-anchor="middle" class="orchestra-room-label">${node.label}</text>
          </g>
        `
      }
      const x = point.x - size.width / 2
      const y = point.y - size.height / 2
      return html`
        <g
          key=${node.id}
          class=${`orchestra-node ${node.kind} ${toneClass(node.tone)} ${selected ? 'selected' : ''} ${focused ? 'focused' : ''}`}
          onClick=${() => onSelect(node.id)}
        >
          <rect x=${x} y=${y} width=${size.width} height=${size.height} rx=${size.radius} class="orchestra-node-body" />
          <text x=${x + 16} y=${y + 24} class="orchestra-node-glyph">${node.glyph ?? '•'}</text>
          <text x=${x + 38} y=${y + 24} class="orchestra-node-label">${node.label}</text>
          ${node.subtitle ? html`<text x=${x + 38} y=${y + 42} class="orchestra-node-subtitle">${node.subtitle}</text>` : null}
          ${node.status ? html`<text x=${x + size.width - 10} y=${y + 18} text-anchor="end" class="orchestra-node-status">${node.status}</text>` : null}
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
      <div class="command-card-sub">연결 ${relatedEdges.length}개 · 근거 ${provenanceLabel(node.provenance)}</div>
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
  if (commandPlaneOrchestraLoading.value && !orchestra) {
    return html`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`
  }
  if (commandPlaneOrchestraError.value) {
    return html`<section class="card command-section"><div class="empty-state error">${commandPlaneOrchestraError.value}</div></section>`
  }
  if (!orchestra) {
    return html`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`
  }

  const positions = layout(orchestra)
  const selected = selectedTarget(orchestra)
  const selectedId = selected?.value.id ?? null
  const roomPoint = orchestra.nodes.find(node => node.kind === 'room')
    ? positions.get(orchestra.nodes.find(node => node.kind === 'room')!.id) ?? null
    : null

  return html`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${PanelSemanticDetails} panelId="command.orchestra" compact=${true} />
      </div>
      <p class="command-card-sub">룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 노드를 누르면 관련 신호와 내려볼 대상을 바로 확인할 수 있습니다.</p>

      <div class="orchestra-shell">
        <div class="orchestra-canvas-wrap">
          <svg class="orchestra-canvas" viewBox=${`0 0 ${SVG_WIDTH} ${SVG_HEIGHT}`}>
            <defs>
              <pattern id="orchestra-grid" width="32" height="32" patternUnits="userSpaceOnUse">
                <path d="M 32 0 L 0 0 0 32" fill="none" class="orchestra-grid-line"></path>
              </pattern>
            </defs>
            <rect width=${SVG_WIDTH} height=${SVG_HEIGHT} fill="url(#orchestra-grid)" class="orchestra-grid"></rect>
            <${OrchestraEdgeLayer} edges=${orchestra.edges} positions=${positions} selectedId=${selectedId} />
            <${OrchestraSignals} orchestra=${orchestra} roomPoint=${roomPoint} onSelect=${(id: string) => { orchestraSelection.value = id }} />
            <${OrchestraNodeLayer}
              orchestra=${orchestra}
              positions=${positions}
              selectedId=${selectedId}
              onSelect=${(id: string) => { orchestraSelection.value = id }}
            />
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
