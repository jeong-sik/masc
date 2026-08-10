import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchOfficialClientSession,
  resolveOfficialClientSession,
  type DashboardOfficialClientRecoveryDecision,
  type DashboardOfficialClientSessionResponse,
} from '../api/dashboard'
import { keepers } from '../store'
import { errorToString } from '../lib/format-string'
import { ActionButton } from './common/button'
import { SectionCard } from './common/card'
import { EmptyState } from './common/feedback-state'
import { Select } from './common/select'
import { StatusChip } from './common/status-chip'

function phaseTone(kind: string): 'ok' | 'warn' | 'bad' | 'info' | 'neutral' {
  if (kind === 'settled' || kind === 'ready') return 'ok'
  if (kind === 'recovery_required') return 'bad'
  if (kind === 'active' || kind === 'turn_inflight') return 'info'
  if (kind === 'start') return 'warn'
  return 'neutral'
}

function timestampText(value: number | null | undefined): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '—'
  return new Date(value * 1_000).toLocaleString()
}

function compactHash(value: string): string {
  return value.length > 18 ? `${value.slice(0, 10)}…${value.slice(-8)}` : value
}

export function OfficialClientSessionPanel() {
  const selectedKeeper = useSignal('')
  const response = useSignal<DashboardOfficialClientSessionResponse | null>(null)
  const loading = useSignal(false)
  const resolving = useSignal(false)
  const error = useSignal<string | null>(null)
  const requestRevision = useSignal(0)

  const keeperNames = keepers.value
    .map(keeper => keeper.name)
    .filter((name, index, names) => names.indexOf(name) === index)
    .sort((left, right) => left.localeCompare(right))
  const keeperKey = keeperNames.join('\u0000')

  const load = async (keeperName: string) => {
    if (!keeperName) {
      response.value = null
      return
    }
    const revision = requestRevision.value + 1
    requestRevision.value = revision
    response.value = null
    loading.value = true
    error.value = null
    try {
      const next = await fetchOfficialClientSession(keeperName)
      if (requestRevision.value === revision) response.value = next
    } catch (cause) {
      if (requestRevision.value === revision) error.value = errorToString(cause)
    } finally {
      if (requestRevision.value === revision) loading.value = false
    }
  }

  useEffect(() => {
    const next = keeperNames.includes(selectedKeeper.value)
      ? selectedKeeper.value
      : (keeperNames[0] ?? '')
    selectedKeeper.value = next
    void load(next)
  }, [keeperKey])

  const resolve = async (decision: DashboardOfficialClientRecoveryDecision) => {
    const keeperName = selectedKeeper.value
    const currentPhase = response.value?.session?.phase
    const recoveryId = currentPhase?.kind === 'recovery_required'
      ? currentPhase.recovery_id
      : null
    if (!keeperName || !recoveryId || resolving.value) return
    resolving.value = true
    error.value = null
    try {
      const resolved = await resolveOfficialClientSession(keeperName, recoveryId, decision)
      response.value = resolved
      if (!resolved.audit.recorded) {
        error.value = `복구는 ${resolved.resolution_application} 상태로 반영됐지만 audit 기록에 실패했습니다: ${resolved.audit.error}`
      }
    } catch (cause) {
      error.value = errorToString(cause)
      await load(keeperName)
    } finally {
      resolving.value = false
    }
  }

  const session = response.value?.session ?? null
  const phase = session?.phase ?? null
  const recovery = phase?.kind === 'recovery_required' ? phase : null
  const ownerEpoch = phase && 'owner_epoch' in phase ? phase.owner_epoch : null
  const sessionId = phase && 'session_id' in phase ? phase.session_id : null
  const turnId = phase && 'turn_id' in phase ? phase.turn_id : null
  const lastResolution = session?.last_recovery_resolution ?? null
  const transientRelease = session?.last_transient_release ?? null

  return html`
    <${SectionCard}
      label="공식 클라이언트 세션"
      status=${phase?.kind ?? (session ? 'unknown' : '')}
      testId="official-client-session-panel"
    >
      <div class="flex flex-wrap items-center gap-2 mb-3">
        <${Select}
          class="max-w-72"
          ariaLabel="Keeper 선택"
          testId="official-client-session-keeper"
          value=${selectedKeeper.value}
          disabled=${keeperNames.length === 0 || loading.value || resolving.value}
          placeholder="Keeper 없음"
          options=${keeperNames}
          onInput=${(keeperName: string) => {
            selectedKeeper.value = keeperName
            void load(keeperName)
          }}
        />
        <${ActionButton}
          variant="ghost"
          size="sm"
          testId="official-client-session-refresh"
          disabled=${!selectedKeeper.value || loading.value || resolving.value}
          ariaBusy=${loading.value}
          onClick=${() => void load(selectedKeeper.value)}
        >새로고침<//>
        ${phase
          ? html`<${StatusChip} tone=${phaseTone(phase.kind)} uppercase=${false} testId="official-client-session-phase">${phase.kind}<//>`
          : null}
      </div>

      ${error.value
        ? html`<div class="mb-3 rounded-[var(--r-1)] border border-[var(--danger-20)] bg-[var(--danger-10)] px-3 py-2 text-xs text-[var(--color-status-err)]" role="alert" data-testid="official-client-session-error">${error.value}</div>`
        : null}
      ${loading.value && !session
        ? html`<div class="text-xs text-[var(--color-fg-muted)]" role="status">공식 클라이언트 세션 불러오는 중…</div>`
        : null}
      ${keeperNames.length === 0
        ? html`<${EmptyState} message="운영할 Keeper가 없습니다." compact />`
        : null}
      ${keeperNames.length > 0 && !loading.value && !session
        ? html`<${EmptyState} message="이 Keeper는 아직 공식 클라이언트 세션을 시작하지 않았습니다." compact />`
        : null}

      ${session && phase
        ? html`
          <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-2 text-xs" data-testid="official-client-session-evidence">
            <div><span class="text-[var(--color-fg-muted)]">keeper</span> · <span class="mono">${response.value?.keeper_name}</span></div>
            <div><span class="text-[var(--color-fg-muted)]">client</span> · <span class="mono">${session.client_kind}</span></div>
            <div><span class="text-[var(--color-fg-muted)]">runtime</span> · <span class="mono">${session.runtime_id}</span></div>
            <div><span class="text-[var(--color-fg-muted)]">completed turns</span> · ${session.turn_count}</div>
            <div><span class="text-[var(--color-fg-muted)]">updated</span> · ${timestampText(session.updated_at)}</div>
            <div title=${session.tool_surface_sha256}><span class="text-[var(--color-fg-muted)]">tool surface</span> · <span class="mono">${compactHash(session.tool_surface_sha256)}</span></div>
            ${ownerEpoch ? html`<div title=${ownerEpoch}><span class="text-[var(--color-fg-muted)]">process epoch</span> · <span class="mono">${compactHash(ownerEpoch)}</span></div>` : null}
            ${sessionId ? html`<div><span class="text-[var(--color-fg-muted)]">session</span> · <span class="mono">${sessionId}</span></div>` : null}
            ${turnId ? html`<div><span class="text-[var(--color-fg-muted)]">turn</span> · <span class="mono">${turnId}</span></div>` : null}
          </div>
          ${recovery
            ? html`
              <div class="mt-4 rounded-[var(--r-1)] border border-[var(--danger-20)] bg-[var(--danger-10)] p-3" data-testid="official-client-session-recovery-required">
                <div class="flex flex-wrap items-center gap-2 mb-2">
                  <${StatusChip} tone="warn" uppercase=${false}>next turn auto-recovers<//>
                  <span class="mono text-2xs">${recovery.recovery_id}</span>
                </div>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-2 text-xs mb-3">
                  <div>failure · <span class="mono">${recovery.failure}</span></div>
                  <div>required · ${timestampText(recovery.required_at)}</div>
                  <div>observed session · <span class="mono">${recovery.observed_session_id ?? '—'}</span></div>
                  <div>observed turn · <span class="mono">${recovery.observed_turn_id ?? '—'}</span></div>
                </div>
                <div class="mb-3 whitespace-pre-wrap break-words text-xs text-[var(--color-fg-secondary)]">${recovery.detail}</div>
                <div class="flex flex-wrap gap-2">
                  <${ActionButton}
                    variant="warn"
                    size="sm"
                    testId="official-client-session-retry-previous"
                    disabled=${resolving.value}
                    ariaBusy=${resolving.value}
                    onClick=${() => void resolve({ resolution: 'retry_previous' })}
                  >이전 settlement에서 재시도<//>
                  <${ActionButton}
                    variant="danger"
                    size="sm"
                    testId="official-client-session-restart-fresh"
                    disabled=${resolving.value}
                    ariaBusy=${resolving.value}
                    onClick=${() => void resolve({ resolution: 'restart_fresh' })}
                  >새 session으로 재시작<//>
                </div>
              </div>
            `
            : null}
          ${lastResolution
            ? html`
              <div class="mt-3 border-t border-[var(--color-border-default)] pt-3 text-xs" data-testid="official-client-session-last-resolution">
                <span class="text-[var(--color-fg-muted)]">last resolution</span>
                · <span class="mono">${lastResolution.resolution.kind}</span>
                · ${lastResolution.resolved_by}
                · ${timestampText(lastResolution.resolved_at)}
                · <span class="mono">${lastResolution.failure}</span>
              </div>
            `
            : null}
          ${transientRelease
            ? html`
              <div class="mt-3 border-t border-[var(--color-border-default)] pt-3 text-xs" data-testid="official-client-session-last-transient-release">
                <span class="text-[var(--color-fg-muted)]">last transient release</span>
                · <span class="mono">${transientRelease.failure}</span>
                · ${timestampText(transientRelease.released_at)}
                · <span class="mono" title=${transientRelease.owner_epoch}>${compactHash(transientRelease.owner_epoch)}</span>
              </div>
            `
            : null}
        `
        : null}
    <//>
  `
}
