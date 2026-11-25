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

import { computed, signal, type ReadonlySignal } from '@preact/signals'
import {
  activeWorkspaceId,
  authSession,
  currentSessionEpoch,
  isEpochCurrent,
  sessionEpoch,
} from '../core/auth'
import { apiGet, apiMutate } from '../core/transport'
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
  | { readonly kind: 'inspect'; readonly payload: WorkspaceInspectPayload }
  | { readonly kind: 'queue_context' }
  | { readonly kind: 'incidents' }

export const activeOverlay = signal<ShellOverlay>(null)
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
  if (isCompactDesktop.value && activeOverlay.value !== null) return false
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

export function setRailExpanded(expanded: boolean): void {
  railPreferredExpanded.value = expanded
  try {
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(RAIL_STORAGE_KEY, expanded ? '1' : '0')
    }
  } catch { /* storage unavailable */ }
}

export function openInspectDrawer(payload: WorkspaceInspectPayload): void {
  activeOverlay.value = { kind: 'inspect', payload }
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
    markAllIncidentsRead()
    activeOverlay.value = { kind: 'incidents' }
  }
}

export function closeActiveOverlay(): void {
  activeOverlay.value = null
}

export function openCommandPalette(): void {
  commandPaletteMounted.value = true
  commandPaletteOpen.value = true
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
): Promise<void> {
  const startEpoch = currentSessionEpoch()
  let version: string | null = null
  let serverCommit: string | null = null
  let bundleCommit: string | null = null

  try {
    const healthRes = await fetchImpl('/health', {
      method: 'GET',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    })
    if (healthRes.ok) {
      const ct = healthRes.headers.get('content-type') ?? ''
      if (ct === '' || ct.includes('application/json')) {
        const h = (await healthRes.json()) as unknown
        if (isRecord(h)) {
          version = asNonEmptyString(h.version)
          serverCommit = asNonEmptyString(h.source_commit) ?? asNonEmptyString(h.commit) ?? asNonEmptyString(h.build_commit)
          bundleCommit = asNonEmptyString(h.dashboard_commit) ?? asNonEmptyString(h.bundle_commit)
        }
      }
    }
  } catch { /* non-fatal diagnostic probe */ }

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

export const inboxPendingCount = computed<number>(
  () =>
    pendingApprovals.value.length
    + pendingAsks.value.length
    + pendingGateApprovals.value.length
    + pendingGoalConfirmations.value.length,
)

export function parseToolApprovalsPayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingApprovalItem[] {
  if (!isRecord(raw) || !Array.isArray(raw.pending)) return []
  const items: PendingApprovalItem[] = []
  for (const row of raw.pending) {
    if (!isRecord(row)) continue
    const approvalId = asNonEmptyString(row.approval_id)
    const keeper = asNonEmptyString(row.keeper)
    const toolCallId = asNonEmptyString(row.tool_call_id)
    if (!approvalId || !keeper || !toolCallId) continue
    const askedAt = typeof row.asked_at === 'number' ? row.asked_at : null
    const revision = asNonEmptyString(row.revision)
      ?? (typeof row.revision === 'number' ? String(row.revision) : `${approvalId}:${askedAt ?? 0}`)
    items.push({
      approvalId,
      keeper,
      toolCallId,
      tool: typeof row.tool === 'string' ? row.tool : '',
      args: typeof row.args === 'string' ? row.args : '',
      question: typeof row.question === 'string' ? row.question : '',
      because: typeof row.because === 'string' ? row.because : '',
      askedAt,
      workspaceId,
      revision,
    })
  }
  return items
}

export function parseKeeperAsksPayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingAskItem[] {
  if (!isRecord(raw)) return []
  const list = Array.isArray(raw.asks)
    ? raw.asks
    : Array.isArray(raw.open)
      ? raw.open
      : Array.isArray(raw.pending)
        ? raw.pending
        : []
  const items: PendingAskItem[] = []
  for (const row of list) {
    if (!isRecord(row)) continue
    const askId = asNonEmptyString(row.ask_id) ?? asNonEmptyString(row.id)
    const keeper = asNonEmptyString(row.keeper) ?? asNonEmptyString(row.name) ?? 'keeper'
    if (!askId) continue
    const resolutionState = isRecord(row.resolution) && typeof row.resolution.state === 'string'
      ? row.resolution.state
      : typeof row.state === 'string'
        ? row.state
        : 'open'
    const state = resolutionState.trim().toLowerCase()
    if (state === 'answered' || state === 'resolved' || state === 'closed' || state === 'withdrawn') continue
    const askedAt = typeof row.asked_at === 'number'
      ? row.asked_at
      : typeof row.created_at === 'number'
        ? row.created_at
        : null
    let prompt = asNonEmptyString(row.question) ?? asNonEmptyString(row.prompt) ?? ''
    if (!prompt && Array.isArray(row.questions) && row.questions.length > 0 && isRecord(row.questions[0])) {
      prompt = asNonEmptyString(row.questions[0].prompt) ?? asNonEmptyString(row.questions[0].text) ?? ''
    }
    const revision = asNonEmptyString(row.revision)
      ?? (typeof row.revision === 'number' ? String(row.revision) : `${askId}:${askedAt ?? 0}`)
    items.push({
      askId,
      keeper,
      prompt: prompt || 'Keeper awaiting operator answer',
      askedAt,
      workspaceId,
      revision,
    })
  }
  return items
}

export function parseGateQueuePayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingGateItem[] {
  if (!isRecord(raw) || !Array.isArray(raw.approval_queue)) return []
  const items: PendingGateItem[] = []
  for (const row of raw.approval_queue) {
    if (!isRecord(row)) continue
    const id = asNonEmptyString(row.id)
    const keeper = asNonEmptyString(row.keeper_name) ?? asNonEmptyString(row.keeper)
    const toolName = asNonEmptyString(row.tool_name) ?? asNonEmptyString(row.tool) ?? 'tool'
    if (!id || !keeper) continue
    items.push({
      id,
      keeper,
      toolName,
      phase: asNonEmptyString(row.phase) ?? 'human_required',
      waitingSec: typeof row.waiting_s === 'number' && Number.isFinite(row.waiting_s) ? row.waiting_s : null,
      workspaceId,
    })
  }
  return items
}

export function parseAwaitingGoalsPayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingGoalConfirmItem[] {
  if (!isRecord(raw) || !Array.isArray(raw.goals)) return []
  const items: PendingGoalConfirmItem[] = []
  for (const row of raw.goals) {
    if (!isRecord(row)) continue
    const phase = asNonEmptyString(row.phase)
    if (!phase || phase.toLowerCase() !== 'awaiting_confirmation') continue
    const goalId = asNonEmptyString(row.id)
    const title = asNonEmptyString(row.title)
    if (!goalId || !title) continue
    items.push({
      goalId,
      title,
      updatedAt: asNonEmptyString(row.updated_at),
      workspaceId,
    })
  }
  return items
}

export function parsePendingVerificationsPayload(
  raw: unknown,
  workspaceId: string,
): readonly PendingVerificationItem[] {
  if (!isRecord(raw)) return []
  const list = Array.isArray(raw.requests)
    ? raw.requests
    : Array.isArray(raw.items)
      ? raw.items
      : []
  const items: PendingVerificationItem[] = []
  for (const row of list) {
    if (!isRecord(row)) continue
    const requestId = asNonEmptyString(row.request_id) ?? asNonEmptyString(row.id)
    const taskId = asNonEmptyString(row.task_id)
    if (!requestId || !taskId) continue
    items.push({
      requestId,
      taskId,
      title: asNonEmptyString(row.task_title) ?? asNonEmptyString(row.title) ?? taskId,
      worker: asNonEmptyString(row.submitted_by) ?? asNonEmptyString(row.worker) ?? asNonEmptyString(row.producer),
      workspaceId,
    })
  }
  return items
}

let hitlRefreshSeq = 0
let hitlAbortCtrl: AbortController | null = null
const hitlIncidentLastSig = new Map<string, string>()

export async function refreshPendingHitl(
  fetchImpl?: typeof fetch,
  opts?: { readonly timeoutMs?: number },
): Promise<void> {
  hitlAbortCtrl?.abort()
  const seq = ++hitlRefreshSeq
  const sessionKind = authSession.peek().kind
  if (sessionKind !== 'single_user_local' && sessionKind !== 'multi_account_signed_in') {
    hitlAbortCtrl = null
    hitlLoading.value = false
    pendingApprovals.value = []
    pendingAsks.value = []
    pendingGateApprovals.value = []
    pendingGoalConfirmations.value = []
    pendingVerifications.value = []
    return
  }
  const ctrl = new AbortController()
  hitlAbortCtrl = ctrl
  const startEpoch = currentSessionEpoch()
  const workspaceId = activeWorkspaceId.peek()
  const reqOpts = { fetchImpl, signal: ctrl.signal, timeoutMs: opts?.timeoutMs }
  const isCurrent = (): boolean => seq === hitlRefreshSeq && isEpochCurrent(startEpoch)
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
    if (sessionKind === 'multi_account_signed_in') {
      pendingApprovals.value = []
      pendingAsks.value = []
      pendingGateApprovals.value = []
      pendingVerifications.value = []
      const planRes = await apiGet<unknown>('/api/v1/dashboard/planning', reqOpts)
      if (!isCurrent()) return
      if (planRes.ok) {
        clearHitlIncident('planning')
        pendingGoalConfirmations.value = parseAwaitingGoalsPayload(planRes.value, workspaceId)
      } else if (
        planRes.error.kind !== 'epoch_stale'
        && planRes.error.kind !== 'aborted'
        && planRes.error.kind !== 'forbidden'
        && planRes.error.kind !== 'not_found'
      ) {
        recordHitlIncidentOnce(
          'planning',
          `Goal confirmation queue unavailable (${planRes.error.status ?? planRes.error.kind})`,
          planRes.error.message,
        )
      }
      return
    }

    // Apply each HITL source independently as soon as it settles so one slow
    // or hung endpoint never blocks the other 4 sources from updating.
    const approvalsJob = apiGet<unknown>('/api/v1/keepers/tool-approvals', reqOpts).then((approvalsRes) => {
      if (!isCurrent()) return
      if (approvalsRes.ok) {
        clearHitlIncident('approvals')
        pendingApprovals.value = parseToolApprovalsPayload(approvalsRes.value, workspaceId)
      } else if (
        approvalsRes.error.kind !== 'epoch_stale'
        && approvalsRes.error.kind !== 'aborted'
        && approvalsRes.error.kind !== 'not_found'
      ) {
        recordHitlIncidentOnce(
          'approvals',
          `Tool approval queue unavailable (${approvalsRes.error.status ?? approvalsRes.error.kind})`,
          approvalsRes.error.message,
        )
      }
    })

    const asksJob = apiGet<unknown>('/api/v1/keepers/asks', reqOpts).then((asksRes) => {
      if (!isCurrent()) return
      if (asksRes.ok) {
        clearHitlIncident('asks')
        pendingAsks.value = parseKeeperAsksPayload(asksRes.value, workspaceId)
      } else if (
        asksRes.error.kind !== 'epoch_stale'
        && asksRes.error.kind !== 'aborted'
        && asksRes.error.kind !== 'forbidden'
        && asksRes.error.kind !== 'not_found'
      ) {
        recordHitlIncidentOnce(
          'asks',
          `Keeper asks queue unavailable (${asksRes.error.status ?? asksRes.error.kind})`,
          asksRes.error.message,
        )
      }
    })

    const gateJob = apiGet<unknown>('/api/v1/dashboard/gate', reqOpts).then((gateRes) => {
      if (!isCurrent()) return
      if (gateRes.ok) {
        if (
          isRecord(gateRes.value)
          && isRecord(gateRes.value.approval_queue_state)
          && gateRes.value.approval_queue_state.state === 'unavailable'
        ) {
          const st = gateRes.value.approval_queue_state
          recordHitlIncidentOnce(
            'gate',
            'Channel gate approval queue unavailable',
            asNonEmptyString(st.operator_detail)
              ?? asNonEmptyString(st.detail)
              ?? asNonEmptyString(st.title)
              ?? 'gate approval queue reported unavailable',
          )
        } else {
          clearHitlIncident('gate')
        }
        pendingGateApprovals.value = parseGateQueuePayload(gateRes.value, workspaceId)
      } else if (
        gateRes.error.kind !== 'epoch_stale'
        && gateRes.error.kind !== 'aborted'
        && gateRes.error.kind !== 'forbidden'
        && gateRes.error.kind !== 'not_found'
      ) {
        recordHitlIncidentOnce(
          'gate',
          `Channel gate queue unavailable (${gateRes.error.status ?? gateRes.error.kind})`,
          gateRes.error.message,
        )
      }
    })

    const planningJob = apiGet<unknown>('/api/v1/dashboard/planning', reqOpts).then((planRes) => {
      if (!isCurrent()) return
      if (planRes.ok) {
        clearHitlIncident('planning')
        pendingGoalConfirmations.value = parseAwaitingGoalsPayload(planRes.value, workspaceId)
      } else if (
        planRes.error.kind !== 'epoch_stale'
        && planRes.error.kind !== 'aborted'
        && planRes.error.kind !== 'forbidden'
        && planRes.error.kind !== 'not_found'
      ) {
        recordHitlIncidentOnce(
          'planning',
          `Goal confirmation queue unavailable (${planRes.error.status ?? planRes.error.kind})`,
          planRes.error.message,
        )
      }
    })

    const verificationJob = apiGet<unknown>('/api/v1/verification/requests?view=awaiting', reqOpts).then((verifRes) => {
      if (!isCurrent()) return
      if (verifRes.ok) {
        if (isRecord(verifRes.value) && asNonEmptyString(verifRes.value.backlog_error)) {
          recordHitlIncidentOnce(
            'verification',
            'Verification backlog read error',
            asNonEmptyString(verifRes.value.backlog_error) ?? 'verification backlog error',
          )
        } else {
          clearHitlIncident('verification')
        }
        pendingVerifications.value = parsePendingVerificationsPayload(verifRes.value, workspaceId)
      } else if (
        verifRes.error.kind !== 'epoch_stale'
        && verifRes.error.kind !== 'aborted'
        && verifRes.error.kind !== 'forbidden'
        && verifRes.error.kind !== 'not_found'
      ) {
        recordHitlIncidentOnce(
          'verification',
          `Verification queue unavailable (${verifRes.error.status ?? verifRes.error.kind})`,
          verifRes.error.message,
        )
      }
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
  pendingApprovals.value = pendingApprovals.peek().filter(
    (row) => row.approvalId !== item.approvalId,
  )
  pushShellToast(
    `${item.keeper} · ${item.tool || item.approvalId} ${decision === 'approve' ? '승인 완료' : '거절 완료'}`,
    decision === 'approve' ? 'success' : 'warning',
  )
  return { ok: true, message: 'ok' }
}

// ── Shell Toast Notifications ───────────────────────────────────────────

export type ShellToastTone = 'success' | 'warning' | 'error' | 'info'

export interface ShellToast {
  readonly id: number
  readonly message: string
  readonly tone: ShellToastTone
}

let toastSeq = 0
const toastsSignal = signal<readonly ShellToast[]>([])
export const shellToasts: ReadonlySignal<readonly ShellToast[]> = toastsSignal

export function pushShellToast(
  message: string,
  tone: ShellToastTone = 'info',
  durationMs = 4000,
): number {
  const id = ++toastSeq
  const next = [...toastsSignal.peek(), { id, message, tone }].slice(-MAX_TOASTS)
  toastsSignal.value = next
  if (durationMs > 0) {
    setTimeout(() => dismissShellToast(id), durationMs)
  }
  return id
}

export function dismissShellToast(id: number): void {
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
    pendingApprovals.value = []
    pendingAsks.value = []
    pendingGateApprovals.value = []
    pendingGoalConfirmations.value = []
    pendingVerifications.value = []
    const kind = authSession.peek().kind
    if (kind === 'single_user_local' || kind === 'multi_account_signed_in') {
      void refreshPendingHitl(fetchImpl)
    }
  })

  const unsubAuth = authSession.subscribe((session) => {
    if (session.kind !== 'single_user_local') {
      pendingApprovals.value = []
      pendingAsks.value = []
      pendingGateApprovals.value = []
      pendingVerifications.value = []
    }
    if (session.kind !== 'single_user_local' && session.kind !== 'multi_account_signed_in') {
      pendingGoalConfirmations.value = []
    }
  })

  const unsubReconnect = subscribeObserverReconnect(() => {
    const kind = authSession.peek().kind
    if (kind === 'single_user_local' || kind === 'multi_account_signed_in') {
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
  viewportWidth.value = 1440
  railPreferredExpanded.value = true
  activeOverlay.value = null
  commandPaletteOpen.value = false
  commandPaletteMounted.value = false
  mobileMoreOpen.value = false
  incidentsSignal.value = []
  hitlIncidentLastSig.clear()
  pendingApprovals.value = []
  pendingAsks.value = []
  pendingGateApprovals.value = []
  pendingGoalConfirmations.value = []
  pendingVerifications.value = []
  hitlLoading.value = false
  toastsSignal.value = []
  buildConnectionInfo.value = {
    version: null,
    serverCommit: null,
    bundleCommit: null,
    mismatched: false,
    checkedAt: null,
  }
}
