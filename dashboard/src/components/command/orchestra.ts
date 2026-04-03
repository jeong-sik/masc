import { html } from 'htm/preact'
import { ActionButton } from '../common/button'
import { EmptyState } from '../common/empty-state'
import { StatusChip } from '../common/status-chip'
import { groupByKey } from '../common/collection'
import { useEffect, useRef, useState } from 'preact/hooks'
import type {
  CommandPlaneOrchestraResponse,
  CommandPlaneOrchestraSignal,
} from '../../types'
import {
  commandPlaneOrchestra,
  commandPlaneOrchestraError,
  commandPlaneOrchestraLoading,
} from '../../command-store'
import { relativeTime, toneClass } from './helpers'
import {
  orchestraCamera,
  orchestraDensity,
  orchestraDragging,
  orchestraHasInteracted,
  orchestraSelection,
} from './orchestra-signals'
import {
  clamp,
  DEFAULT_VIEWPORT,
  fitCamera,
  OrchestraDetailDrawer,
  OrchestraEdgeLayer,
  OrchestraNodeLayer,
  OrchestraSignals,
  orchestraBounds,
  selectedTarget,
  ZOOM_MAX,
  ZOOM_MIN,
} from './orchestra-drawer'

type Point = { x: number; y: number }
type SignalPoint = { signalNode: CommandPlaneOrchestraSignal; x: number; y: number }

function densityLabel(mode: 'balanced' | 'compact'): string {
  return mode === 'compact' ? '집약' : '균형'
}

function spreadX(count: number, min: number, max: number): number[] {
  if (count <= 0) return []
  if (count === 1) return [Math.round((min + max) / 2)]
  const step = (max - min) / (count - 1)
  return Array.from({ length: count }, (_, idx) => Math.round(min + idx * step))
}


function layoutConfig(density: 'balanced' | 'compact') {
  if (density === 'compact') {
    return {
      namespace: { x: 660, y: 108 },
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
    namespace: { x: 700, y: 112 },
    sessions: { y: 236, min: 240, max: 1140 },
    operations: { y: 356, min: 300, max: 1080 },
    detachments: { y: 454, min: 340, max: 1030 },
    lanes: { y: 584, min: 230, max: 1110 },
    worker: { perRow: 4, xSpacing: 72, ySpacing: 60, laneOffsetY: 82, freeBaseY: 720 },
    keeper: { startX: 1210, colSpacing: 108, rowSpacing: 102, startY: 188, columns: 2 },
    signalRadius: 132,
  }
}

function layout(orchestra: CommandPlaneOrchestraResponse, density: 'balanced' | 'compact'): Map<string, Point> {
  const cfg = layoutConfig(density)
  const positions = new Map<string, Point>()
  const nodes = orchestra.nodes
  const namespaceNode = nodes.find(node => node.kind === 'namespace') ?? null
  const sessions = nodes.filter(node => node.kind === 'session')
  const operations = nodes.filter(node => node.kind === 'operation')
  const detachments = nodes.filter(node => node.kind === 'detachment')
  const lanes = nodes.filter(node => node.kind === 'lane')
  const workers = nodes.filter(node => node.kind === 'worker')
  const keepers = nodes.filter(node => node.kind === 'keeper')

  if (namespaceNode) positions.set(namespaceNode.id, { x: cfg.namespace.x, y: cfg.namespace.y })

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

  const workerBuckets = groupByKey(workers, worker => {
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
  namespacePoint: Point | null,
  density: 'balanced' | 'compact',
): SignalPoint[] {
  if (!namespacePoint || orchestra.signals.length === 0) return []
  const cfg = layoutConfig(density)
  return orchestra.signals.slice(0, 6).map((signalNode, idx) => {
    const angle = (-130 + idx * 36) * (Math.PI / 180)
    return {
      signalNode,
      x: Math.round(namespacePoint.x + Math.cos(angle) * cfg.signalRadius),
      y: Math.round(namespacePoint.y + Math.sin(angle) * cfg.signalRadius),
    }
  })
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
    return html`<section class="card rounded-xl min-h-[240px]"><${EmptyState} message="오케스트라 맵 불러오는 중…" compact /></section>`
  }
  if (commandPlaneOrchestraError.value) {
    return html`<section class="card rounded-xl min-h-[240px]"><${EmptyState} message=${commandPlaneOrchestraError.value} compact /></section>`
  }
  if (!orchestra) {
    return html`<section class="card rounded-xl min-h-[240px]"><${EmptyState} message="오케스트라 맵 데이터가 아직 없습니다." compact /></section>`
  }

  const density = orchestraDensity.value
  const positions = layout(orchestra, density)
  const namespaceNode = orchestra.nodes.find(node => node.kind === 'namespace') ?? null
  const namespacePoint = namespaceNode ? positions.get(namespaceNode.id) ?? null : null
  const signalNodes = signalPoints(orchestra, namespacePoint, density)
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
    <section class="card rounded-xl min-h-[240px] overflow-hidden">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">오케스트라 맵</div>
      </div>
      <p class="cmd-card rounded-xl-sub">
        네임스페이스 전체를 한 장의 작전판으로 읽는 시각화입니다. 확대/이동으로 밀집 구간을 읽고, 노드를 눌러 상세 신호와 연결 대상을 확인합니다.
      </p>

      <div class="orchestra-toolbar">
        <div class="orchestra-toolbar-group">
          <${ActionButton} variant="ghost" onClick=${applyFit}>맞춤 보기<//>
          <${ActionButton} variant="ghost" onClick=${resetView}>초기화<//>
        </div>
        <div class="orchestra-toolbar-group">
          <${ActionButton}
            variant="ghost"
            onClick=${() => zoomAround(viewport.width / 2, viewport.height / 2, 1.12)}
          >
            확대
          <//>
          <${ActionButton}
            variant="ghost"
            onClick=${() => zoomAround(viewport.width / 2, viewport.height / 2, 0.9)}
          >
            축소
          <//>
          <${StatusChip} label=${`${Math.round(camera.zoom * 100)}%`} />
        </div>
        <div class="orchestra-toolbar-group">
          <${ActionButton}
            variant=${density === 'balanced' ? 'primary' : 'ghost'}
            size="lg"
            onClick=${() => {
              orchestraDensity.value = 'balanced'
              orchestraSelection.value = selectedId
            }}
          >
            균형
          <//>
          <${ActionButton}
            variant=${density === 'compact' ? 'primary' : 'ghost'}
            size="lg"
            onClick=${() => {
              orchestraDensity.value = 'compact'
              orchestraSelection.value = selectedId
            }}
          >
            집약
          <//>
          <${StatusChip} label=${densityLabel(density)} />
        </div>
      </div>

      <div class="grid grid-cols-[minmax(0,1.35fr)_minmax(320px,0.65fr)] gap-4 mt-4">
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
            class=${`orchestra-canvas block w-full h-auto min-h-[720px] ${orchestraDragging.value ? 'is-dragging' : ''}`}
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
              <${OrchestraSignals} signalNodes=${signalNodes} namespacePoint=${namespacePoint} onSelect=${(id: string) => { orchestraSelection.value = id }} />
              <${OrchestraNodeLayer}
                orchestra=${orchestra}
                positions=${positions}
                density=${density}
                selectedId=${selectedId}
                onSelect=${(id: string) => { orchestraSelection.value = id }}
              />
            </g>
          </svg>
          <div class="absolute left-3.5 right-3.5 bottom-3 flex flex-wrap gap-2 pointer-events-none">
            <${StatusChip} label=${`세션 ${orchestra.summary?.session_count ?? 0}`} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
            <${StatusChip} label=${`워커 ${orchestra.summary?.worker_count ?? 0}`} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
            <${StatusChip} label=${`키퍼 ${orchestra.summary?.keeper_count ?? 0}`} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
            <${StatusChip} label=${`신호 ${orchestra.summary?.signal_count ?? orchestra.signals.length}`} tone=${toneClass(orchestra.signals.some(signalNode => signalNode.tone === 'bad') ? 'bad' : orchestra.signals.length > 0 ? 'warn' : 'ok')} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
            <${StatusChip} label=${`갱신 ${relativeTime(orchestra.generated_at)}`} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
          </div>
        </div>

        <${OrchestraDetailDrawer} orchestra=${orchestra} />
      </div>
    </section>
  `
}
