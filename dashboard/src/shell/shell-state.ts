/**
 * Reactive Shell State for Proposal A+.
 *
 * Manages:
 * - Collapsible 6-trunk rail preference (`[b]`, 208px ↔ 56px, auto-collapsing at <=1440px when Drawer opens)
 * - Viewport breakpoints (`<768px` mobile, `<=1440px` compact desktop)
 * - Single Read-Only `QuickPeekDrawer` overlay host (`inspect | queue_context | incidents`)
 * - Lazy Command Palette open/requested state (`⌘K`)
 * - Channel 1 Fast-Path Pending Tool Approvals & Keeper Asks (capability-gated!)
 * - Channel 3 Historical Incidents ring buffer (strictly isolated from Channel 2 Live SSOT!)
 * - Build-commit / server version metadata (surfaced in Provenance popover, never a top warning banner)
 * - Theme & Static High-Contrast signals synced with `src/lib/theme.ts`
 * - Lightweight shell toast notifications
 */

import { batch, computed, signal, type ReadonlySignal } from '@preact/signals'
import {
  activeWorkspaceId,
  authSession,
  canAccessAdmin,
  canAccessMemberWorkspace,
  consumeBootstrapHealthPayload,
  currentSessionEpoch,
  isEpochCurrent,
  isSingleUserMember,
  sessionEpoch,
} from '../core/auth'
import { apiGet, apiMutate } from '../core/transport'
import { resourceCache } from '../core/resource-cache'
import {
  extractObserverTopics,
  subscribeObserverFrames,
  subscribeObserverReconnect,
  subscribeObserverResync,
} from '../core/observer'
import {
  applyContrast,
  applyTheme,
  persistContrast,
  persistTheme,
  resolveInitialContrast,
  resolveInitialTheme,
  type ContrastId,
  type ThemeId,
} from '../lib/theme'
import type { WorkspaceInspectPayload } from '../workspaces/types'

export {
  parseAwaitingGoalsPayload,
  parseGateQueuePayload,
  parseKeeperAsksPayload,
  parsePendingVerificationsPayload,
  parseToolApprovalsPayload,
} from './hitl-parsers'

const RAIL_STORAGE_KEY = 'masc.shell.rail_expanded'
const MAX_INCIDENTS = 100
const MAX_TOASTS = 5

// ── Viewport & Rail Layout ──────────────────────────────────────────────

function readViewportWidth(): number {
  return typeof window === 'undefined' ? 1440 : window.innerWidth
}

function readInitialRailExpanded(): boolean {
  if (typeof window === 'undefined') return true
  try {
    const stored = localStorage.getItem(RAIL_STORAGE_KEY)
    if (stored === '0' || stored === 'false') return false
    if (stored === '1' || stored === 'true') return true
  } catch { /* storage unavailable */ }
  return window.innerWidth >= 1024
}

export const viewportWidth = signal<number>(readViewportWidth())
export const isMobileViewport = computed<boolean>(() => viewportWidth.value < 768)
export const isCompactDesktop = computed<boolean>(() => viewportWidth.value <= 1440)

export const railPreferredExpanded = signal<boolean>(readInitialRailExpanded())

export type ShellOverlay =
  | null
  | { readonly kind: 'inspect'; readonly payload: WorkspaceInspectPayload; readonly epoch: number }
  | { readonly kind: 'queue_context' }
  | { readonly kind: 'incidents' }

export const activeOverlay = signal<ShellOverlay>(null)
// Inspect payloads can contain workspace-owned data and render closures.
export const currentShellOverlay = computed<ShellOverlay>(() => {
  const overlay = activeOverlay.value
  return overlay?.kind === 'inspect' && overlay.epoch !== sessionEpoch.value ? null : overlay
})
export const commandPaletteOpen = signal<boolean>(false)
export const commandPaletteMounted = signal<boolean>(false)
export const mobileMoreOpen = signal<boolean>(false)

/**
 * Effective desktop rail expansion:
 * Auto-collapses to `56px` at `<=1440px` whenever Quick-Peek Drawer / Overlay opens
 * so main content never overflows horizontally (`scrollWidth <= clientWidth`).
 */
export const railExpanded = computed<boolean>(() => {
  if (isMobileViewport.value) return false
  if (isCompactDesktop.value && currentShellOverlay.value !== null) return false
  return railPreferredExpanded.value
})

export function toggleRail(): void {
  const next = !railPreferredExpanded.peek()
  railPreferredExpanded.value = next
  try {
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(RAIL_STORAGE_KEY, next ? '1' : '0')
    }
  } catch { /* storage unavailable */ }
}

export function openInspectDrawer(payload: WorkspaceInspectPayload): void {
  activeOverlay.value = { kind: 'inspect', payload, epoch: currentSessionEpoch() }
}

export function toggleQueueContextOverlay(): void {
  const cur = activeOverlay.peek()
  activeOverlay.value = cur?.kind === 'queue_context' ? null : { kind: 'queue_context' }
}

export function toggleIncidentsOverlay(): void {
  const cur = activeOverlay.peek()
  if (cur?.kind === 'incidents') {
    activeOverlay.value = null
  } else {
    batch(() => {
      markAllIncidentsRead()
      activeOverlay.value = { kind: 'incidents' }
    })
  }
}

export function closeActiveOverlay(): void {
  activeOverlay.value = null
}

export function openCommandPalette(): void {
  batch(() => {
    commandPaletteMounted.value = true
    commandPaletteOpen.value = true
  })
}

export function closeCommandPalette(): void {
  commandPaletteOpen.value = false
}

export function toggleCommandPalette(): void {
  if (commandPaletteOpen.peek()) {
    closeCommandPalette()
  } else {
    openCommandPalette()
  }
}

export function installViewportListener(): () => void {
  if (typeof window === 'undefined') return () => {}
  const onResize = () => {
    viewportWidth.value = window.innerWidth
  }
  onResize()
  window.addEventListener('resize', onResize, { passive: true })
  return () => window.removeEventListener('resize', onResize)
}

// ── Theme & Static High-Contrast Signals ────────────────────────────────

export const activeTheme = signal<ThemeId>(resolveInitialTheme())
export const activeContrast = signal<ContrastId | null>(resolveInitialContrast())

export function setThemeMode(theme: ThemeId): void {
  activeTheme.value = theme
  applyTheme(theme)
  persistTheme(theme)
}

export function toggleThemeMode(): ThemeId {
  const next: ThemeId = activeTheme.peek() === 'dark' ? 'light' : 'dark'
  setThemeMode(next)
  return next
}

export function setContrastMode(contrast: ContrastId | null): void {
  activeContrast.value = contrast
  applyContrast(contrast)
  persistContrast(contrast)
}

export function toggleHighContrast(): ContrastId {
  const next: ContrastId = activeContrast.peek() === 'high' ? 'normal' : 'high'
  setContrastMode(next)
  return next
}

// ── Channel 3 Historical Incidents (Isolated from Ch2 Live SSOT!) ───────

export type IncidentSeverity = 'warn' | 'error' | 'info'

export interface HistoricalIncident {
  readonly id: string
  readonly ts: number
  readonly severity: IncidentSeverity
  readonly source: string
  readonly summary: string
  readonly detail?: string
  readonly read: boolean
  readonly dismissed: boolean
}

let incidentSeq = 0
const incidentsSignal = signal<readonly HistoricalIncident[]>([])
export const historicalIncidents: ReadonlySignal<readonly HistoricalIncident[]> = incidentsSignal

export const unreadIncidentCount = computed<number>(() =>
  incidentsSignal.value.filter((item) => !item.read && !item.dismissed).length,
)

export function recordIncident(input: {
  readonly severity: IncidentSeverity
  readonly source: string
  readonly summary: string
  readonly detail?: string
}): HistoricalIncident {
  const entry: HistoricalIncident = {
    id: `inc-${++incidentSeq}`,
    ts: Date.now(),
    severity: input.severity,
    source: input.source,
    summary: input.summary,
    detail: input.detail,
    read: activeOverlay.peek()?.kind === 'incidents',
    dismissed: false,
  }
  const next = [entry, ...incidentsSignal.peek()].slice(0, MAX_INCIDENTS)
  incidentsSignal.value = next
  return entry
}

export function markAllIncidentsRead(): void {
  const cur = incidentsSignal.peek()
  if (cur.every((i) => i.read)) return
  incidentsSignal.value = cur.map((i) => (i.read ? i : { ...i, read: true }))
}

export function dismissIncident(id: string): void {
  incidentsSignal.value = incidentsSignal.peek().map((i) =>
    i.id === id ? { ...i, dismissed: true, read: true } : i,
  )
}

export function clearDismissedIncidents(): void {
  incidentsSignal.value = incidentsSignal.peek().filter((i) => !i.dismissed)
}

// ── Host Disk Observation & Pressure Summary ────────────────────────────

export interface HostDiskFilesystem {
  readonly path: string | null
  readonly filesystem: string | null
  readonly mountedOn: string | null
  readonly totalBytes: number | null
  readonly usedBytes: number | null
  readonly availableBytes: number | null
  readonly capacityPercent: number | null
  readonly availablePercent: number | null
  readonly error: string | null
}

export interface HostDiskObservation {
  readonly mascRoot: string | null
  readonly mode: string | null
  readonly status: string | null
  readonly statusReasons: readonly string[]
  readonly exhaustionTotal: number | null
  readonly lastExhaustionTs: number | null
  readonly filesystem: HostDiskFilesystem | null
}

export type DiskPressureLevel = 'ok' | 'warning' | 'critical' | 'exhausted' | 'unavailable'

export interface DiskPressureSummary {
  readonly level: DiskPressureLevel
  readonly label: string
  readonly detail: string
}

function asFiniteNumber(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

export function decodeDiskObservation(raw: unknown): HostDiskObservation | null {
  if (!isRecord(raw)) return null
  const fsRaw = isRecord(raw.filesystem) ? raw.filesystem : null
  const filesystem: HostDiskFilesystem | null = fsRaw
    ? {
        path: asNonEmptyString(fsRaw.path),
        filesystem: asNonEmptyString(fsRaw.filesystem),
        mountedOn: asNonEmptyString(fsRaw.mounted_on),
        totalBytes: asFiniteNumber(fsRaw.total_bytes),
        usedBytes: asFiniteNumber(fsRaw.used_bytes),
        availableBytes: asFiniteNumber(fsRaw.available_bytes),
        capacityPercent: asFiniteNumber(fsRaw.capacity_percent),
        availablePercent: asFiniteNumber(fsRaw.available_percent),
        error: asNonEmptyString(fsRaw.error),
      }
    : null
  const statusReasons = Array.isArray(raw.status_reasons)
    ? raw.status_reasons.filter((r): r is string => typeof r === 'string' && r.trim().length > 0).map((r) => r.trim())
    : []
  const mascRoot = asNonEmptyString(raw.masc_root)
  const mode = asNonEmptyString(raw.mode)
  const status = asNonEmptyString(raw.status)
  const exhaustionTotal = asFiniteNumber(raw.storage_space_exhaustion_observations_total)
  const lastExhaustionTs = asFiniteNumber(raw.last_storage_space_exhaustion_ts)
  if (
    mascRoot === null
    && mode === null
    && status === null
    && statusReasons.length === 0
    && exhaustionTotal === null
    && lastExhaustionTs === null
    && filesystem === null
  ) {
    return null
  }
  return {
    mascRoot,
    mode,
    status,
    statusReasons,
    exhaustionTotal,
    lastExhaustionTs,
    filesystem,
  }
}

export const ENOSPC_RECENT_WINDOW_SEC = 900

export function isRecentEnospcObservation(
  obs: HostDiskObservation | null,
  nowSec = Date.now() / 1000,
): boolean {
  if (!obs || obs.exhaustionTotal === null || obs.exhaustionTotal <= 0) {
    return false
  }
  const statusLower = obs.status?.toLowerCase() ?? null
  if (statusLower === 'exhausted_enospc') {
    return true
  }
  if (obs.lastExhaustionTs !== null && obs.lastExhaustionTs > 0) {
    const ageSec = Math.max(0, nowSec - obs.lastExhaustionTs)
    return ageSec <= ENOSPC_RECENT_WINDOW_SEC
  }
  // Undated monotonic counter alone must not pin a permanent alert once filesystem recovers.
  const pct = obs.filesystem?.capacityPercent ?? null
  return statusLower === 'error' || statusLower === 'degraded' || (pct !== null && pct >= 90)
}

export function classifyDiskPressure(
  obs: HostDiskObservation | null,
  nowSec = Date.now() / 1000,
): DiskPressureSummary {
  if (!obs) {
    return { level: 'ok', label: '', detail: '' }
  }
  if (isRecentEnospcObservation(obs, nowSec)) {
    return {
      level: 'exhausted',
      label: `ENOSPC ×${obs.exhaustionTotal}`,
      detail: `최근 호스트 스토리지 공간 부족(ENOSPC) ${obs.exhaustionTotal}건 관측`,
    }
  }
  if (obs.filesystem?.error) {
    return {
      level: 'unavailable',
      label: '디스크 오류',
      detail: `호스트 디스크 상태 조회 실패: ${obs.filesystem.error}`,
    }
  }
  const pct = obs.filesystem?.capacityPercent ?? null
  const pctLabel = pct !== null ? `${Math.round(pct)}%` : null
  const statusLower = obs.status?.toLowerCase() ?? null

  if (statusLower === 'degraded' || statusLower === 'error' || (pct !== null && pct >= 90)) {
    return {
      level: 'critical',
      label: pctLabel ? `디스크 ${pctLabel}` : '디스크 위험',
      detail: pctLabel
        ? `호스트 디스크 사용률 ${pctLabel} (위험 임계치 90% 이상)`
        : `호스트 디스크 상태: ${obs.status ?? 'critical'}`,
    }
  }
  if (statusLower === 'warning' || (pct !== null && pct >= 80)) {
    return {
      level: 'warning',
      label: pctLabel ? `디스크 ${pctLabel}` : '디스크 주의',
      detail: pctLabel
        ? `호스트 디스크 사용률 ${pctLabel} (주의 임계치 80% 이상)`
        : '호스트 디스크 경고 상태',
    }
  }
  return {
    level: 'ok',
    label: pctLabel ? `디스크 ${pctLabel}` : '',
    detail: pctLabel ? `호스트 디스크 사용률 ${pctLabel}` : '',
  }
}

export const hostDiskObservation = signal<HostDiskObservation | null>(null)
export const diskPressureSummary = computed<DiskPressureSummary>(() =>
  classifyDiskPressure(hostDiskObservation.value),
)

export function updateHostDiskObservation(raw: unknown): HostDiskObservation | null {
  const decoded = decodeDiskObservation(raw)
  hostDiskObservation.value = decoded
  return decoded
}

// ── Build-Commit & Connection Diagnostics (Popover Only!) ───────────────

export interface BuildConnectionInfo {
  readonly version: string | null
  readonly serverCommit: string | null
  readonly bundleCommit: string | null
  readonly mismatched: boolean
  readonly checkedAt: number | null
}

export const buildConnectionInfo = signal<BuildConnectionInfo>({
  version: null,
  serverCommit: null,
  bundleCommit: null,
  mismatched: false,
  checkedAt: null,
})

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asNonEmptyString(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

export async function probeBuildConnectionInfo(
  fetchImpl: typeof fetch = globalThis.fetch,
  opts: { readonly force?: boolean } = {},
): Promise<void> {
  const startEpoch = currentSessionEpoch()
  let version: string | null = null
  let serverCommit: string | null = null
  let bundleCommit: string | null = null

  const applyHealthRecord = (h: unknown): {
    version: string | null
    serverCommit: string | null
    bundleCommit: string | null
  } => {
    if (!isRecord(h)) return { version: null, serverCommit: null, bundleCommit: null }
    return {
      version: asNonEmptyString(h.version),
      serverCommit: asNonEmptyString(h.source_commit) ?? asNonEmptyString(h.commit) ?? asNonEmptyString(h.build_commit),
      bundleCommit: asNonEmptyString(h.dashboard_commit) ?? asNonEmptyString(h.bundle_commit),
    }
  }

  const reused = !opts.force && fetchImpl === globalThis.fetch
    ? consumeBootstrapHealthPayload(startEpoch)
    : null
  if (reused !== null) {
    const parsed = applyHealthRecord(reused)
    version = parsed.version
    serverCommit = parsed.serverCommit
    bundleCommit = parsed.bundleCommit
  } else {
    try {
      const healthRes = await fetchImpl('/health', {
        method: 'GET',
        credentials: 'same-origin',
        headers: { Accept: 'application/json' },
      })
      if (healthRes.ok) {
        const ct = healthRes.headers.get('content-type') ?? ''
        if (ct === '' || ct.includes('application/json')) {
          const parsed = applyHealthRecord(await healthRes.json())
          version = parsed.version
          serverCommit = parsed.serverCommit
          bundleCommit = parsed.bundleCommit
        }
      }
    } catch { /* non-fatal diagnostic probe */ }
  }

  if (!isEpochCurrent(startEpoch)) return
  const mismatched = Boolean(
    serverCommit && bundleCommit && !serverCommit.startsWith(bundleCommit) && !bundleCommit.startsWith(serverCommit),
  )
  buildConnectionInfo.value = {
    version,
    serverCommit,
    bundleCommit,
    mismatched,
    checkedAt: Date.now(),
  }
}

// ── Channel 1 Fast-Path Pending Approvals & Keeper Asks ─────────────────

export interface PendingApprovalItem {
  readonly approvalId: string
  readonly keeper: string
  readonly toolCallId: string
  readonly tool: string
  readonly args: string
  readonly question: string
  readonly because: string
  readonly askedAt: number | null
  readonly workspaceId: string
  readonly revision: string
}

export interface PendingAskItem {
  readonly askId: string
  readonly keeper: string
  readonly prompt: string
  readonly askedAt: number | null
  readonly workspaceId: string
  readonly revision: string
}

export interface PendingGateItem {
  readonly id: string
  readonly keeper: string
  readonly toolName: string
  readonly phase: string
  readonly waitingSec: number | null
  readonly workspaceId: string
}

export interface PendingGoalConfirmItem {
  readonly goalId: string
  readonly title: string
  readonly updatedAt: string | null
  readonly workspaceId: string
}

export interface PendingVerificationItem {
  readonly requestId: string
  readonly taskId: string
  readonly title: string
  readonly worker: string | null
  readonly workspaceId: string
}

export const pendingApprovals = signal<readonly PendingApprovalItem[]>([])
export const pendingAsks = signal<readonly PendingAskItem[]>([])
export const pendingGateApprovals = signal<readonly PendingGateItem[]>([])
export const pendingGoalConfirmations = signal<readonly PendingGoalConfirmItem[]>([])
export const pendingVerifications = signal<readonly PendingVerificationItem[]>([])
export const hitlLoading = signal<boolean>(false)

export type HitlSourceKey = 'approvals' | 'asks' | 'gate' | 'planning' | 'verification'

export type HitlSourceState =
  | { readonly kind: 'unread' }
  | { readonly kind: 'ok' }
  | { readonly kind: 'unbridged'; readonly reason: 'multi_account_unbridged' }
  | { readonly kind: 'failed'; readonly message: string }
  | { readonly kind: 'partial' | 'recovered'; readonly message: string }

export type HitlSourceStatusMap = Readonly<Record<HitlSourceKey, HitlSourceState>>

const DEFAULT_HITL_SOURCE_STATUS: HitlSourceStatusMap = {
  approvals: { kind: 'unread' },
  asks: { kind: 'unread' },
  gate: { kind: 'unread' },
  planning: { kind: 'unread' },
  verification: { kind: 'unread' },
}

export const hitlSourceStatus = signal<HitlSourceStatusMap>(DEFAULT_HITL_SOURCE_STATUS)

export const effectiveHitlSourceStatus = computed<HitlSourceStatusMap>(() => {
  const raw = hitlSourceStatus.value
  if (authSession.value.kind === 'multi_account_signed_in') {
    return {
      approvals: { kind: 'unbridged', reason: 'multi_account_unbridged' },
      asks: { kind: 'unbridged', reason: 'multi_account_unbridged' },
      gate: { kind: 'unbridged', reason: 'multi_account_unbridged' },
      planning: raw.planning,
      verification: { kind: 'unbridged', reason: 'multi_account_unbridged' },
    }
  }
  return raw
})

export interface HitlUncheckedSource {
  readonly key: HitlSourceKey
  readonly label: string
  readonly state: Exclude<HitlSourceState, { readonly kind: 'ok' }>
}

const HITL_SOURCE_LABELS: Readonly<Record<HitlSourceKey, string>> = {
  approvals: '도구 승인',
  asks: 'Keeper 질문',
  gate: 'Channel Gate',
  planning: 'Goal 확인',
  verification: '검증 대기',
}

export const hitlUncheckedSummary = computed<readonly HitlUncheckedSource[]>(() => {
  const map = effectiveHitlSourceStatus.value
  const out: HitlUncheckedSource[] = []
  for (const key of ['approvals', 'asks', 'gate', 'planning', 'verification'] as const) {
    const st = map[key]
    if (st.kind !== 'ok') {
      out.push({ key, label: HITL_SOURCE_LABELS[key], state: st })
    }
  }
  return out
})

export const inboxUncheckedSources = computed(
  () => hitlUncheckedSummary.value.filter((source) => source.key !== 'verification'),
)

export function uncheckedHitlStatusLabel(state: HitlUncheckedSource['state']): string {
  switch (state.kind) {
    case 'unread': return '조회 대기'
    case 'unbridged': return '멀티 계정 미지원'
    case 'failed': return '조회 실패'
    case 'partial': return '일부만 확인'
    case 'recovered': return '복구본 · 읽기 전용'
  }
}

export function formatInboxPendingCount(count: number, unchecked: boolean): string {
  if (!unchecked) return String(count)
  return count > 0 ? `${count}건 표시 · 일부 미확인` : '일부 미확인'
}

export function formatInboxBadge(pending: number, unchecked: boolean): string | null {
  if (pending > 0) {
    return unchecked ? `${pending}?` : String(pending)
  }
  return unchecked ? '?' : null
}

export const HITL_POLL_TIMEOUT_MS = 15_000

export const inboxPendingCount = computed<number>(
  () =>
    pendingApprovals.value.length
    + pendingAsks.value.length
    + pendingGateApprovals.value.length
    + pendingGoalConfirmations.value.length,
)

export const hasFastApprovalStripContent = computed<boolean>(
  () =>
    inboxPendingCount.value > 0
    || (canAccessMemberWorkspace(authSession.value) && inboxUncheckedSources.value.length > 0),
)

let hitlRefreshSeq = 0
let hitlAbortCtrl: AbortController | null = null
const hitlIncidentLastSig = new Map<string, string>()
let hitlParsersPromise: Promise<typeof import('./hitl-parsers')> | null = null

type HitlParsersLoadResult =
  | { readonly ok: true; readonly parsers: typeof import('./hitl-parsers') }
  | { readonly ok: false; readonly message: string }

function loadHitlParsers(): Promise<typeof import('./hitl-parsers')> {
  if (!hitlParsersPromise) {
    hitlParsersPromise = import('./hitl-parsers').catch((err) => {
      hitlParsersPromise = null
      throw err
    })
  }
  return hitlParsersPromise
}

async function loadHitlParsersSafe(): Promise<HitlParsersLoadResult> {
  try {
    return { ok: true, parsers: await loadHitlParsers() }
  } catch (err) {
    return {
      ok: false,
      message: err instanceof Error && err.message ? err.message : 'HITL 파서 모듈을 불러오지 못했습니다',
    }
  }
}

export async function refreshPendingHitl(
  fetchImpl?: typeof fetch,
  opts?: { readonly timeoutMs?: number },
): Promise<void> {
  hitlAbortCtrl?.abort()
  const seq = ++hitlRefreshSeq
  const session = authSession.peek()
  if (!canAccessMemberWorkspace(session)) {
    hitlAbortCtrl = null
    batch(() => {
      hitlLoading.value = false
      pendingApprovals.value = []
      pendingAsks.value = []
      pendingGateApprovals.value = []
      pendingGoalConfirmations.value = []
      pendingVerifications.value = []
      hitlSourceStatus.value = DEFAULT_HITL_SOURCE_STATUS
      hostDiskObservation.value = null
    })
    return
  }
  const sessionKind = session.kind
  const ctrl = new AbortController()
  hitlAbortCtrl = ctrl
  const startEpoch = currentSessionEpoch()
  const workspaceId = activeWorkspaceId.peek()
  const reqOpts = { fetchImpl, signal: ctrl.signal, timeoutMs: opts?.timeoutMs ?? HITL_POLL_TIMEOUT_MS }
  const isCurrent = (): boolean => seq === hitlRefreshSeq && isEpochCurrent(startEpoch)
  const setHitlSourceState = (key: HitlSourceKey, state: HitlSourceState): void => {
    hitlSourceStatus.value = { ...hitlSourceStatus.peek(), [key]: state }
  }
  const lastHitlIncidentBySource = hitlIncidentLastSig
  const recordHitlIncidentOnce = (
    source: string,
    summary: string,
    detail: string,
  ): void => {
    const sig = `${summary}|${detail}`
    if (lastHitlIncidentBySource.get(source) === sig) return
    lastHitlIncidentBySource.set(source, sig)
    recordIncident({ severity: 'warn', source, summary, detail })
  }
  const clearHitlIncident = (source: string): void => {
    lastHitlIncidentBySource.delete(source)
  }

  hitlLoading.value = true
  try {
    // Load HITL decoders concurrently with network reads so they stay out of the boot chunk.
    const parsersJob = loadHitlParsersSafe()
    if (sessionKind === 'multi_account_signed_in') {
      batch(() => {
        pendingApprovals.value = []
        pendingAsks.value = []
        pendingGateApprovals.value = []
        pendingVerifications.value = []
        hitlSourceStatus.value = {
          approvals: { kind: 'unbridged', reason: 'multi_account_unbridged' },
          asks: { kind: 'unbridged', reason: 'multi_account_unbridged' },
          gate: { kind: 'unbridged', reason: 'multi_account_unbridged' },
          planning: hitlSourceStatus.peek().planning.kind === 'unbridged' ? { kind: 'unread' } : hitlSourceStatus.peek().planning,
          verification: { kind: 'unbridged', reason: 'multi_account_unbridged' },
        }
      })
      const [planRes, parsersRes] = await Promise.all([
        apiGet<unknown>('/api/v1/dashboard/planning', reqOpts),
        parsersJob,
      ])
      if (!isCurrent()) return
      batch(() => {
        if (planRes.ok) {
          if (!parsersRes.ok) {
            setHitlSourceState('planning', { kind: 'failed', message: parsersRes.message })
            recordHitlIncidentOnce('planning', 'Goal confirmation decoder unavailable', parsersRes.message)
            return
          }
          if (!isRecord(planRes.value) || planRes.value.ok === false || !Array.isArray(planRes.value.goals)) {
            const message =
              isRecord(planRes.value) && typeof planRes.value.error === 'string' && planRes.value.error.trim()
                ? planRes.value.error.trim()
                : '목표 확인 큐 응답 형식이 올바르지 않습니다'
            setHitlSourceState('planning', { kind: 'failed', message })
            recordHitlIncidentOnce('planning', 'Goal confirmation queue response invalid', message)
            return
          }
          clearHitlIncident('planning')
          pendingGoalConfirmations.value = parsersRes.parsers.parseAwaitingGoalsPayload(planRes.value, workspaceId)
          setHitlSourceState('planning', { kind: 'ok' })
        } else if (
          planRes.error.kind !== 'epoch_stale'
          && planRes.error.kind !== 'aborted'
        ) {
          setHitlSourceState('planning', { kind: 'failed', message: planRes.error.message })
          recordHitlIncidentOnce(
            'planning',
            `Goal confirmation queue unavailable (${planRes.error.status ?? planRes.error.kind})`,
            planRes.error.message,
          )
        }
      })
      return
    }

    // Clear stale multi-account unbridged markers when entering single-user mode.
    const prevStatus = hitlSourceStatus.peek()
    if (
      prevStatus.approvals.kind === 'unbridged'
      || prevStatus.asks.kind === 'unbridged'
      || prevStatus.gate.kind === 'unbridged'
      || prevStatus.verification.kind === 'unbridged'
    ) {
      hitlSourceStatus.value = DEFAULT_HITL_SOURCE_STATUS
    }

    // Apply each HITL source independently as soon as it settles so one slow
    // or hung endpoint never blocks the other 4 sources from updating.
    const approvalsJob = apiGet<unknown>('/api/v1/keepers/tool-approvals', reqOpts).then(async (approvalsRes) => {
      if (!isCurrent()) return
      const parsersRes = approvalsRes.ok ? await parsersJob : null
      if (!isCurrent()) return
      batch(() => {
        if (approvalsRes.ok && parsersRes) {
          if (!parsersRes.ok) {
            setHitlSourceState('approvals', { kind: 'failed', message: parsersRes.message })
            recordHitlIncidentOnce('approvals', 'Tool approval decoder unavailable', parsersRes.message)
            return
          }
          const raw = approvalsRes.value
          const hasValidList =
            isRecord(raw)
            && raw.ok !== false
            && Array.isArray(raw.pending)
          if (!hasValidList) {
            const message =
              isRecord(raw) && typeof raw.error === 'string' && raw.error.trim()
                ? raw.error.trim()
                : '도구 승인 큐 응답 형식이 올바르지 않습니다'
            setHitlSourceState('approvals', { kind: 'failed', message })
            recordHitlIncidentOnce('approvals', 'Tool approval queue response invalid', message)
            return
          }
          clearHitlIncident('approvals')
          pendingApprovals.value = parsersRes.parsers.parseToolApprovalsPayload(raw, workspaceId)
          setHitlSourceState('approvals', { kind: 'ok' })
        } else if (
          !approvalsRes.ok
          && approvalsRes.error.kind !== 'epoch_stale'
          && approvalsRes.error.kind !== 'aborted'
        ) {
          setHitlSourceState('approvals', { kind: 'failed', message: approvalsRes.error.message })
          recordHitlIncidentOnce(
            'approvals',
            `Tool approval queue unavailable (${approvalsRes.error.status ?? approvalsRes.error.kind})`,
            approvalsRes.error.message,
          )
        }
      })
    })

    const asksJob = apiGet<unknown>('/api/v1/keepers/asks?include_resolved=false', reqOpts).then(async (asksRes) => {
      if (!isCurrent()) return
      const parsersRes = asksRes.ok ? await parsersJob : null
      if (!isCurrent()) return
      batch(() => {
        if (asksRes.ok && parsersRes) {
          if (!parsersRes.ok) {
            setHitlSourceState('asks', { kind: 'failed', message: parsersRes.message })
            recordHitlIncidentOnce('asks', 'Keeper asks decoder unavailable', parsersRes.message)
            return
          }
          const decoded = parsersRes.parsers.decodeKeeperAsksWire(asksRes.value)
          if (!decoded.ok) {
            setHitlSourceState('asks', { kind: 'failed', message: decoded.error })
            recordHitlIncidentOnce('asks', 'Keeper asks queue response invalid', decoded.error)
            return
          }
          clearHitlIncident('asks')
          pendingAsks.value = decoded.asks.map((ask) => ({
            askId: ask.askId,
            keeper: ask.keeper,
            prompt: ask.promptSummary ?? 'Keeper awaiting operator answer',
            askedAt: ask.askedAt,
            workspaceId,
            revision: ask.revision,
          }))
          setHitlSourceState('asks', { kind: 'ok' })
        } else if (
          !asksRes.ok
          && asksRes.error.kind !== 'epoch_stale'
          && asksRes.error.kind !== 'aborted'
        ) {
          setHitlSourceState('asks', { kind: 'failed', message: asksRes.error.message })
          recordHitlIncidentOnce(
            'asks',
            `Keeper asks queue unavailable (${asksRes.error.status ?? asksRes.error.kind})`,
            asksRes.error.message,
          )
        }
      })
    })

    const gateJob = apiGet<unknown>('/api/v1/dashboard/gate', reqOpts).then(async (gateRes) => {
      if (!isCurrent()) return
      const parsersRes = gateRes.ok ? await parsersJob : null
      if (!isCurrent()) return
      batch(() => {
        if (gateRes.ok && parsersRes) {
          if (!parsersRes.ok) {
            setHitlSourceState('gate', { kind: 'failed', message: parsersRes.message })
            recordHitlIncidentOnce('gate', 'Channel gate decoder unavailable', parsersRes.message)
            return
          }
          const decoded = parsersRes.parsers.decodeGateQueueStrict(gateRes.value)
          if (!decoded.ok) {
            setHitlSourceState('gate', { kind: 'failed', message: decoded.error })
            recordHitlIncidentOnce(
              'gate',
              decoded.unavailable
                ? 'Channel gate approval queue unavailable'
                : 'Channel gate queue response invalid',
              decoded.error,
            )
            return
          }
          clearHitlIncident('gate')
          setHitlSourceState('gate', { kind: 'ok' })
          pendingGateApprovals.value = decoded.rows.map((row) => ({
            id: row.id,
            keeper: row.keeper,
            toolName: row.toolName,
            phase: row.phase ?? 'unknown',
            waitingSec: row.waitingSec,
            workspaceId,
          }))
        } else if (
          !gateRes.ok
          && gateRes.error.kind !== 'epoch_stale'
          && gateRes.error.kind !== 'aborted'
        ) {
          setHitlSourceState('gate', { kind: 'failed', message: gateRes.error.message })
          recordHitlIncidentOnce(
            'gate',
            `Channel gate queue unavailable (${gateRes.error.status ?? gateRes.error.kind})`,
            gateRes.error.message,
          )
        }
      })
    })

    const planningJob = apiGet<unknown>('/api/v1/dashboard/planning', reqOpts).then(async (planRes) => {
      if (!isCurrent()) return
      const parsersRes = planRes.ok ? await parsersJob : null
      if (!isCurrent()) return
      batch(() => {
        if (planRes.ok && parsersRes) {
          if (!parsersRes.ok) {
            setHitlSourceState('planning', { kind: 'failed', message: parsersRes.message })
            recordHitlIncidentOnce('planning', 'Goal confirmation decoder unavailable', parsersRes.message)
            return
          }
          const raw = planRes.value
          if (!isRecord(raw) || raw.ok === false || !Array.isArray(raw.goals)) {
            const message =
              isRecord(raw) && typeof raw.error === 'string' && raw.error.trim()
                ? raw.error.trim()
                : '목표 확인 큐 응답 형식이 올바르지 않습니다'
            setHitlSourceState('planning', { kind: 'failed', message })
            recordHitlIncidentOnce('planning', 'Goal confirmation queue response invalid', message)
            return
          }
          clearHitlIncident('planning')
          pendingGoalConfirmations.value = parsersRes.parsers.parseAwaitingGoalsPayload(raw, workspaceId)
          setHitlSourceState('planning', { kind: 'ok' })
        } else if (
          !planRes.ok
          && planRes.error.kind !== 'epoch_stale'
          && planRes.error.kind !== 'aborted'
        ) {
          setHitlSourceState('planning', { kind: 'failed', message: planRes.error.message })
          recordHitlIncidentOnce(
            'planning',
            `Goal confirmation queue unavailable (${planRes.error.status ?? planRes.error.kind})`,
            planRes.error.message,
          )
        }
      })
    })

    const verificationJob = apiGet<unknown>('/api/v1/verification/requests?view=awaiting', reqOpts).then(async (verifRes) => {
      if (!isCurrent()) return
      const parsersRes = verifRes.ok ? await parsersJob : null
      if (!isCurrent()) return
      batch(() => {
        if (verifRes.ok && parsersRes) {
          if (!parsersRes.ok) {
            setHitlSourceState('verification', { kind: 'failed', message: parsersRes.message })
            recordHitlIncidentOnce('verification', 'Verification decoder unavailable', parsersRes.message)
            return
          }
          const raw = verifRes.value
          if (!isRecord(raw) || (!Array.isArray(raw.requests) && !Array.isArray(raw.items))) {
            const message = '응답에 검증 목록이 없습니다'
            setHitlSourceState('verification', { kind: 'failed', message })
            recordHitlIncidentOnce('verification', 'Verification queue response invalid', message)
            return
          }
          const coverage = parsersRes.parsers.decodeVerificationCoverage(raw)
          const details: string[] = []
          if (coverage.unresolvedTotal !== null && coverage.unresolvedTotal > 0) {
            details.push(`대기 기록 누락 ${coverage.unresolvedTotal}건`)
          }
          if (coverage.unreadableTotal !== null && coverage.unreadableTotal > 0) {
            details.push(`읽기 불가 ${coverage.unreadableTotal}건`)
          }
          if (coverage.truncated) details.push('일부 항목만 표시')
          if (coverage.backlogError) {
            const message = [coverage.backlogError, ...details].join(' · ')
            setHitlSourceState('verification', { kind: 'failed', message })
            recordHitlIncidentOnce('verification', 'Verification backlog read error', message)
            return
          }
          pendingVerifications.value = parsersRes.parsers.parsePendingVerificationsPayload(raw, workspaceId)
          if (coverage.backlogRecovery) {
            const message = [coverage.backlogRecovery, ...details].join(' · ')
            setHitlSourceState('verification', { kind: 'recovered', message })
            recordHitlIncidentOnce('verification', 'Verification backlog recovered', message)
          } else if (details.length > 0) {
            const message = details.join(' · ')
            setHitlSourceState('verification', { kind: 'partial', message })
            recordHitlIncidentOnce('verification', 'Verification backlog partially observed', message)
          } else {
            clearHitlIncident('verification')
            setHitlSourceState('verification', { kind: 'ok' })
          }
        } else if (
          !verifRes.ok
          && verifRes.error.kind !== 'epoch_stale'
          && verifRes.error.kind !== 'aborted'
        ) {
          setHitlSourceState('verification', { kind: 'failed', message: verifRes.error.message })
          recordHitlIncidentOnce(
            'verification',
            `Verification queue unavailable (${verifRes.error.status ?? verifRes.error.kind})`,
            verifRes.error.message,
          )
        }
      })
    })

    await Promise.all([approvalsJob, asksJob, gateJob, planningJob, verificationJob])
  } finally {
    if (seq === hitlRefreshSeq && isEpochCurrent(startEpoch)) {
      hitlLoading.value = false
    }
  }
}

export async function submitFastToolApproval(
  item: PendingApprovalItem,
  decision: 'approve' | 'deny',
  fetchImpl?: typeof fetch,
): Promise<{ readonly ok: boolean; readonly message: string }> {
  const cur = authSession.peek()
  if (cur.kind !== 'single_user_local' || !canAccessAdmin(cur)) {
    return { ok: false, message: '도구 승인 결정은 싱글유저 관리자 세션에서만 실행할 수 있습니다.' }
  }
  const startEpoch = currentSessionEpoch()
  const res = await apiMutate<Record<string, unknown>>(
    'POST',
    '/api/v1/keepers/tool-approval',
    {
      name: item.keeper,
      tool_call_id: item.toolCallId,
      approval_id: item.approvalId,
      decision,
    },
    { fetchImpl },
  )
  if (!isEpochCurrent(startEpoch)) {
    return { ok: false, message: '세션 또는 워크스페이스가 변경되어 요청이 취소되었습니다.' }
  }
  if (!res.ok) {
    recordIncident({
      severity: 'error',
      source: 'approvals',
      summary: `${decision === 'approve' ? '승인' : '거절'} 실패 (${item.keeper}/${item.tool || item.approvalId})`,
      detail: res.error.message,
    })
    return { ok: false, message: res.error.message }
  }
  const receipt = isRecord(res.value) ? res.value : null
  const settled = receipt?.settled === true
  const remembered = receipt?.remembered === true
  if (!settled && !remembered) {
    const detail = '결정 접수를 확인하지 못했습니다.'
    recordIncident({
      severity: 'error',
      source: 'approvals',
      summary: `${decision === 'approve' ? '승인' : '거절'} 미확인 (${item.keeper}/${item.tool || item.approvalId})`,
      detail,
    })
    return { ok: false, message: detail }
  }
  batch(() => {
    pendingApprovals.value = pendingApprovals.peek().filter(
      (row) => row.approvalId !== item.approvalId,
    )
    resourceCache.invalidateTopic('tool_approval')
    pushShellToast(
      settled
        ? `${item.keeper} · ${item.tool || item.approvalId} ${decision === 'approve' ? '승인 완료' : '거절 완료'}`
        : `${item.keeper} · ${item.tool || item.approvalId} · 같은 호출 재시도 시 적용할 결정으로 저장했습니다.`,
      decision === 'approve' ? 'success' : 'warning',
    )
  })
  return { ok: true, message: 'ok' }
}

// ── Shell Toast Notifications ───────────────────────────────────────────

export type ShellToastTone = 'success' | 'warning' | 'error' | 'info'
export type ShellToastPauseReason = 'hover' | 'focus'

export interface ShellToast {
  readonly id: number
  readonly message: string
  readonly tone: ShellToastTone
}

interface ShellToastTimer {
  remainingMs: number
  startedAt: number
  timerId: ReturnType<typeof setTimeout> | null
  readonly pauseReasons: Set<ShellToastPauseReason>
}

let toastSeq = 0
const toastsSignal = signal<readonly ShellToast[]>([])
const shellToastTimers = new Map<number, ShellToastTimer>()
export const shellToasts: ReadonlySignal<readonly ShellToast[]> = toastsSignal

function clearShellToastTimer(id: number): void {
  const timer = shellToastTimers.get(id)
  if (!timer) return
  if (timer.timerId !== null) {
    clearTimeout(timer.timerId)
  }
  shellToastTimers.delete(id)
}

function scheduleShellToastDismiss(id: number, ms: number): void {
  const existing = shellToastTimers.get(id)
  if (existing && existing.timerId !== null) {
    clearTimeout(existing.timerId)
  }
  const pauseReasons = existing ? existing.pauseReasons : new Set<ShellToastPauseReason>()
  const timerId = setTimeout(() => dismissShellToast(id), ms)
  shellToastTimers.set(id, {
    remainingMs: ms,
    startedAt: Date.now(),
    timerId,
    pauseReasons,
  })
}

export function pauseShellToastTimer(id: number, reason: ShellToastPauseReason = 'focus'): void {
  const timer = shellToastTimers.get(id)
  if (!timer) return
  const wasPaused = timer.pauseReasons.size > 0
  timer.pauseReasons.add(reason)
  if (wasPaused) return
  if (timer.timerId !== null) {
    clearTimeout(timer.timerId)
    timer.timerId = null
  }
  const elapsed = Math.max(0, Date.now() - timer.startedAt)
  timer.remainingMs = Math.max(0, timer.remainingMs - elapsed)
  timer.startedAt = 0
}

export function resumeShellToastTimer(id: number, reason: ShellToastPauseReason = 'focus'): void {
  const timer = shellToastTimers.get(id)
  if (!timer) return
  timer.pauseReasons.delete(reason)
  if (timer.pauseReasons.size > 0 || timer.timerId !== null) return
  if (timer.remainingMs <= 0) {
    dismissShellToast(id)
    return
  }
  scheduleShellToastDismiss(id, timer.remainingMs)
}

export function pushShellToast(
  message: string,
  tone: ShellToastTone = 'info',
  durationMs = 4000,
): number {
  const id = ++toastSeq
  const combined = [...toastsSignal.peek(), { id, message, tone }]
  const evictedCount = Math.max(0, combined.length - MAX_TOASTS)
  for (let i = 0; i < evictedCount; i += 1) {
    clearShellToastTimer(combined[i]!.id)
  }
  toastsSignal.value = combined.slice(-MAX_TOASTS)
  if (durationMs > 0) {
    scheduleShellToastDismiss(id, durationMs)
  }
  return id
}

export function dismissShellToast(id: number): void {
  clearShellToastTimer(id)
  toastsSignal.value = toastsSignal.peek().filter((t) => t.id !== id)
}

// ── Observer / Epoch Reactive Bridge ────────────────────────────────────

export function installShellObservers(fetchImpl?: typeof fetch): () => void {
  const unsubResync = subscribeObserverResync((reason) => {
    recordIncident({
      severity: 'warn',
      source: 'observer',
      summary: `Observer stream gap: ${reason}`,
      detail: 'Live event sequence gap detected; snapshot resync recommended.',
    })
  })

  const hitlTopics = new Set([
    'approval',
    'approvals',
    'approval:pending',
    'tool_approval',
    'tool_approvals',
    'ask',
    'asks',
    'keeper_ask',
    'keeper_asks',
    'gate',
    'gate_approval',
    'goal',
    'goals',
    'goal_projection_changed',
    'planning',
    'verification',
    'verification_requests',
    'pending_confirms_changed',
  ])
  let hitlDebounceTimer: ReturnType<typeof setTimeout> | null = null

  const unsubFrames = subscribeObserverFrames((frame) => {
    const topics = extractObserverTopics(frame)
    if (!topics.some((t) => hitlTopics.has(t))) return
    if (hitlDebounceTimer) return
    hitlDebounceTimer = setTimeout(() => {
      hitlDebounceTimer = null
      void refreshPendingHitl(fetchImpl)
    }, 350)
  })

  let lastEpoch = sessionEpoch.peek()
  const unsubEpoch = sessionEpoch.subscribe((epoch) => {
    if (epoch === lastEpoch) return
    lastEpoch = epoch
    if (hitlDebounceTimer) {
      clearTimeout(hitlDebounceTimer)
      hitlDebounceTimer = null
    }
    hitlAbortCtrl?.abort()
    hitlIncidentLastSig.clear()
    batch(() => {
      const overlay = activeOverlay.peek()
      if (overlay?.kind === 'inspect' && overlay.epoch !== epoch) activeOverlay.value = null
      pendingApprovals.value = []
      pendingAsks.value = []
      pendingGateApprovals.value = []
      pendingGoalConfirmations.value = []
      pendingVerifications.value = []
      hitlSourceStatus.value = DEFAULT_HITL_SOURCE_STATUS
      hostDiskObservation.value = null
    })
    if (canAccessMemberWorkspace(authSession.peek())) {
      void refreshPendingHitl(fetchImpl)
    }
  })

  const unsubAuth = authSession.subscribe((session) => {
    batch(() => {
      if (!isSingleUserMember(session)) {
        pendingApprovals.value = []
        pendingAsks.value = []
        pendingGateApprovals.value = []
        pendingVerifications.value = []
      }
      if (!canAccessMemberWorkspace(session)) {
        pendingGoalConfirmations.value = []
        hitlSourceStatus.value = DEFAULT_HITL_SOURCE_STATUS
      }
    })
  })

  const unsubReconnect = subscribeObserverReconnect(() => {
    if (canAccessMemberWorkspace(authSession.peek())) {
      void refreshPendingHitl(fetchImpl)
    }
  })

  return () => {
    unsubResync()
    unsubFrames()
    unsubReconnect()
    unsubEpoch()
    unsubAuth()
    if (hitlDebounceTimer) {
      clearTimeout(hitlDebounceTimer)
      hitlDebounceTimer = null
    }
  }
}

export function resetShellStateForTests(): void {
  hitlIncidentLastSig.clear()
  for (const id of [...shellToastTimers.keys()]) {
    clearShellToastTimer(id)
  }
  batch(() => {
    viewportWidth.value = 1440
    railPreferredExpanded.value = true
    activeOverlay.value = null
    commandPaletteOpen.value = false
    commandPaletteMounted.value = false
    mobileMoreOpen.value = false
    incidentsSignal.value = []
    pendingApprovals.value = []
    pendingAsks.value = []
    pendingGateApprovals.value = []
    pendingGoalConfirmations.value = []
    pendingVerifications.value = []
    hitlSourceStatus.value = DEFAULT_HITL_SOURCE_STATUS
    hitlLoading.value = false
    hostDiskObservation.value = null
    toastsSignal.value = []
    buildConnectionInfo.value = {
      version: null,
      serverCommit: null,
      bundleCommit: null,
      mismatched: false,
      checkedAt: null,
    }
  })
}
