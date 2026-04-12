import type {
  ChainHistoryEventSummary,
  CommandPlaneSurface,
} from '../../types'
import {
  commandPlaneActionBusy,
  commandPlaneChainFocusOperationId,
} from '../../command-store'
import { route } from '../../router'
import { relativeTime, formatElapsed } from '../../lib/format-time'
import { toneClass, toneBorder, toneBg, chainStatusTone, sessionStatusTone, expiryTone } from '../../lib/tone'
import { prettyJson, displayStatus } from '../../lib/status-label'

// ── Pure helpers ──────────────────────────────

export { relativeTime, formatElapsed, toneClass, toneBorder, toneBg, chainStatusTone, sessionStatusTone, expiryTone, prettyJson, displayStatus }

export function alertBorderTone(tone: string): string {
  if (tone === 'warn') return 'border-[var(--warn-30)]'
  if (tone === 'bad') return 'border-[rgba(248,113,113,0.3)]'
  return ''
}

export function deadlineLabel(iso?: string | null): string {
  if (!iso) return '정보 없음'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.round((ts - Date.now()) / 1000)
  if (deltaSec <= 0) return '기한 지남'
  if (deltaSec < 60) return `${deltaSec}초 후`
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}분 후`
  if (deltaSec < 86400) return `${Math.round(deltaSec / 3600)}시간 후`
  return `${Math.round(deltaSec / 86400)}일 후`
}

type MermaidApi = typeof import('mermaid')['default']

let mermaidConfigured = false

let mermaidPromise: Promise<MermaidApi> | null = null

export async function getMermaid(): Promise<MermaidApi> {
  if (!mermaidPromise) {
    mermaidPromise = import('mermaid').then(module => module.default)
  }
  const mermaid = await mermaidPromise
  if (mermaidConfigured) return mermaid
  mermaid.initialize({
    startOnLoad: false,
    theme: 'dark',
    securityLevel: 'strict',
  })
  mermaidConfigured = true
  return mermaid
}

export function formatPercent(value?: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '정보 없음'
  return `${Math.round(value * 100)}%`
}

export function clampPercent(value?: number | null): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 0
  return Math.max(0, Math.min(100, value))
}

export function historySummary(history?: ChainHistoryEventSummary | null): string {
  if (!history) return '최근 체인 이력이 없습니다'
  const pieces = [history.event]
  if (typeof history.duration_ms === 'number') pieces.push(`${history.duration_ms}ms`)
  if (typeof history.tokens === 'number') pieces.push(`토큰 ${history.tokens}`)
  if (history.message) pieces.push(history.message)
  return pieces.join(' · ')
}

// ── Constants ─────────────────────────────────

export type CommandSurfaceGroup = 'status' | 'history' | 'control'

export const COMMAND_SURFACE_GROUPS: Array<{ id: CommandSurfaceGroup; label: string }> = [
  { id: 'status', label: '현황' },
  { id: 'history', label: '이력' },
  { id: 'control', label: '통제' },
]

export const COMMAND_SURFACE_META: Array<{ id: CommandPlaneSurface; label: string; group: CommandSurfaceGroup }> = [
  { id: 'operations', label: '작전', group: 'history' },
  { id: 'chains', label: '체인', group: 'history' },
  { id: 'control', label: '제어', group: 'control' },
]
const COMMAND_SURFACES: CommandPlaneSurface[] = COMMAND_SURFACE_META.map(item => item.id)
export const CHAIN_SSE_EVENT_TYPES = ['chain_start', 'node_start', 'node_complete', 'chain_complete', 'chain_error']

export function isCommandSurface(value: string | undefined): value is CommandPlaneSurface {
  return !!value && COMMAND_SURFACES.includes(value as CommandPlaneSurface)
}

// ── Route helpers (signal-dependent) ──────────

function inheritedWorkflowRouteParams(): Record<string, string> {
  const params = route.value.params
  if (params.source !== 'mission' && params.source !== 'execution') return {}
  return {
    source: params.source,
    ...(params.action_type ? { action_type: params.action_type } : {}),
    ...(params.target_type ? { target_type: params.target_type } : {}),
    ...(params.target_id ? { target_id: params.target_id } : {}),
    ...(params.focus_kind ? { focus_kind: params.focus_kind } : {}),
    ...(params.operation_id ? { operation_id: params.operation_id } : {}),
  }
}

export function surfaceRouteParams(surface: CommandPlaneSurface): Record<string, string> {
  const inherited = inheritedWorkflowRouteParams()
  const base = { ...inherited, section: 'intervene' }
  if (surface === 'operations') return base
  if (surface === 'chains') {
    const operationId = commandPlaneChainFocusOperationId.value
    return operationId ? { ...base, operation_id: operationId, target_type: 'operation', target_id: operationId } : base
  }
  return base
}

export function unitKindLabel(kind: string): string {
  switch (kind) {
    case 'company':
      return '중대'
    case 'platoon':
      return '소대'
    case 'squad':
      return '분대'
    case 'agent':
      return '에이전트'
    default:
      return kind
  }
}

export function actionDisabled(key: string): boolean {
  return commandPlaneActionBusy.value === key
}

export function dashboardLocationParams(): URLSearchParams {
  if (typeof window === 'undefined') return new URLSearchParams()
  const search = new URLSearchParams(window.location.search)
  const hash = window.location.hash.replace(/^#/, '')
  const queryIdx = hash.indexOf('?')
  if (queryIdx >= 0) {
    const hashSearch = new URLSearchParams(hash.slice(queryIdx + 1))
    hashSearch.forEach((value, key) => {
      if (!search.has(key)) search.set(key, value)
    })
  }
  return search
}

export function dashboardSwarmRunId(): string | null {
  const params = dashboardLocationParams()
  const value = params.get('run_id')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

export function dashboardSwarmOperationId(): string | null {
  const params = dashboardLocationParams()
  const value = params.get('operation_id')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

export async function fire(action: () => Promise<void>) {
  try {
    await action()
  } catch (err) {
    console.debug('[command] action error (state captured in store)', err instanceof Error ? err.message : err)
  }
}
