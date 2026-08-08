import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchCodexSession,
  resolveCodexSession,
  type DashboardCodexRecoveryDecision,
  type DashboardCodexSessionResponse,
} from '../api/dashboard'
import { keepers } from '../store'
import { errorToString } from '../lib/format-string'
import { ActionButton } from './common/button'
import { SectionCard } from './common/card'
import { EmptyState } from './common/feedback-state'
import { TextInput } from './common/input'
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

export function CodexSessionRecoveryPanel() {
  const selectedKeeper = useSignal('')
  const response = useSignal<DashboardCodexSessionResponse | null>(null)
  const loading = useSignal(false)
  const resolving = useSignal(false)
  const error = useSignal<string | null>(null)
  const adoptThreadId = useSignal('')
  const adoptTurnId = useSignal('')
  const requestRevision = useSignal(0)

  const codexKeepers = keepers.value
    .filter(keeper => keeper.runtime_id?.startsWith('codex.') === true)
    .map(keeper => keeper.name)
    .filter((name, index, names) => names.indexOf(name) === index)
    .sort((left, right) => left.localeCompare(right))
  const keeperKey = codexKeepers.join('\u0000')

  const load = async (keeperName: string) => {
    if (!keeperName) {
      response.value = null
      return
    }
    const revision = requestRevision.value + 1
    requestRevision.value = revision
    loading.value = true
    error.value = null
    try {
      const next = await fetchCodexSession(keeperName)
      if (requestRevision.value === revision) response.value = next
    } catch (cause) {
      if (requestRevision.value === revision) error.value = errorToString(cause)
    } finally {
      if (requestRevision.value === revision) loading.value = false
    }
  }

  useEffect(() => {
    const next = codexKeepers.includes(selectedKeeper.value)
      ? selectedKeeper.value
      : (codexKeepers[0] ?? '')
    selectedKeeper.value = next
    void load(next)
  }, [keeperKey])

  const resolve = async (decision: DashboardCodexRecoveryDecision) => {
    const keeperName = selectedKeeper.value
    const recoveryId = response.value?.session?.phase.recovery_id
    if (!keeperName || !recoveryId || resolving.value) return
    resolving.value = true
    error.value = null
    try {
      response.value = await resolveCodexSession(keeperName, recoveryId, decision)
      adoptThreadId.value = ''
      adoptTurnId.value = ''
    } catch (cause) {
      error.value = errorToString(cause)
      await load(keeperName)
    } finally {
      resolving.value = false
    }
  }

  const session = response.value?.session ?? null
  const phase = session?.phase ?? null
  const recoveryRequired = phase?.kind === 'recovery_required'
  const lastResolution = session?.last_recovery_resolution ?? null
  const canAdopt = adoptThreadId.value.trim() !== '' && adoptTurnId.value.trim() !== ''

  return html`
    <${SectionCard}
      label="Codex 공식 클라이언트 세션"
      status=${phase?.kind ?? (session ? 'unknown' : '')}
      testId="codex-session-recovery-panel"
    >
      <div class="flex flex-wrap items-center gap-2 mb-3">
        <${Select}
          class="max-w-72"
          ariaLabel="Codex Keeper 선택"
          testId="codex-session-keeper"
          value=${selectedKeeper.value}
          disabled=${codexKeepers.length === 0 || loading.value || resolving.value}
          placeholder="Codex Keeper 없음"
          options=${codexKeepers}
          onInput=${(keeperName: string) => {
            selectedKeeper.value = keeperName
            void load(keeperName)
          }}
        />
        <${ActionButton}
          variant="ghost"
          size="sm"
          testId="codex-session-refresh"
          disabled=${!selectedKeeper.value || loading.value || resolving.value}
          ariaBusy=${loading.value}
          onClick=${() => void load(selectedKeeper.value)}
        >새로고침<//>
        ${phase
          ? html`<${StatusChip} tone=${phaseTone(phase.kind)} uppercase=${false} testId="codex-session-phase">${phase.kind}<//>`
          : null}
      </div>

      ${error.value
        ? html`<div class="mb-3 rounded-[var(--r-1)] border border-[var(--danger-20)] bg-[var(--danger-10)] px-3 py-2 text-xs text-[var(--color-status-err)]" role="alert" data-testid="codex-session-error">${error.value}</div>`
        : null}
      ${loading.value && !session
        ? html`<div class="text-xs text-[var(--color-fg-muted)]" role="status">Codex 세션 불러오는 중…</div>`
        : null}
      ${codexKeepers.length === 0
        ? html`<${EmptyState} message="Codex runtime이 배정된 Keeper가 없습니다. runtime.toml 배정에서 먼저 선택하세요." compact />`
        : null}
      ${codexKeepers.length > 0 && !loading.value && !session
        ? html`<${EmptyState} message="이 Keeper는 아직 공식 Codex 세션을 시작하지 않았습니다." compact />`
        : null}

      ${session && phase
        ? html`
          <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-2 text-xs" data-testid="codex-session-evidence">
            <div><span class="text-[var(--color-fg-muted)]">keeper</span> · <span class="mono">${response.value?.keeper_name}</span></div>
            <div><span class="text-[var(--color-fg-muted)]">runtime</span> · <span class="mono">${session.runtime_id}</span></div>
            <div><span class="text-[var(--color-fg-muted)]">completed turns</span> · ${session.turn_count}</div>
            <div><span class="text-[var(--color-fg-muted)]">updated</span> · ${timestampText(session.updated_at)}</div>
            <div title=${session.tool_surface_sha256}><span class="text-[var(--color-fg-muted)]">tool surface</span> · <span class="mono">${compactHash(session.tool_surface_sha256)}</span></div>
            ${phase.thread_id ? html`<div><span class="text-[var(--color-fg-muted)]">thread</span> · <span class="mono">${phase.thread_id}</span></div>` : null}
            ${phase.turn_id ? html`<div><span class="text-[var(--color-fg-muted)]">turn</span> · <span class="mono">${phase.turn_id}</span></div>` : null}
          </div>
          ${recoveryRequired
            ? html`
              <div class="mt-4 rounded-[var(--r-1)] border border-[var(--danger-20)] bg-[var(--danger-10)] p-3" data-testid="codex-session-recovery-required">
                <div class="flex flex-wrap items-center gap-2 mb-2">
                  <${StatusChip} tone="bad" uppercase=${false}>operator resolution required<//>
                  <span class="mono text-2xs">${phase.recovery_id}</span>
                </div>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-2 text-xs mb-3">
                  <div>failure · <span class="mono">${phase.failure}</span></div>
                  <div>required · ${timestampText(phase.required_at)}</div>
                  <div>observed thread · <span class="mono">${phase.observed_thread_id ?? '—'}</span></div>
                  <div>observed turn · <span class="mono">${phase.observed_turn_id ?? '—'}</span></div>
                </div>
                <div class="mb-3 whitespace-pre-wrap break-words text-xs text-[var(--color-fg-secondary)]">${phase.detail}</div>
                <div class="flex flex-wrap gap-2 mb-3">
                  <${ActionButton}
                    variant="warn"
                    size="sm"
                    testId="codex-session-retry-previous"
                    disabled=${resolving.value}
                    ariaBusy=${resolving.value}
                    onClick=${() => void resolve({ resolution: 'retry_previous' })}
                  >이전 settlement에서 재시도<//>
                  <${ActionButton}
                    variant="danger"
                    size="sm"
                    testId="codex-session-restart-fresh"
                    disabled=${resolving.value}
                    ariaBusy=${resolving.value}
                    onClick=${() => void resolve({ resolution: 'restart_fresh' })}
                  >새 thread로 재시작<//>
                </div>
                <div class="grid grid-cols-1 md:grid-cols-[1fr_1fr_auto] gap-2 items-end">
                  <label class="grid gap-1 text-2xs text-[var(--color-fg-muted)]">
                    검증된 thread ID
                    <${TextInput}
                      value=${adoptThreadId.value}
                      ariaLabel="검증된 Codex thread ID"
                      testId="codex-session-adopt-thread"
                      disabled=${resolving.value}
                      onInput=${(event: Event) => { adoptThreadId.value = (event.target as HTMLInputElement).value }}
                    />
                  </label>
                  <label class="grid gap-1 text-2xs text-[var(--color-fg-muted)]">
                    검증된 turn ID
                    <${TextInput}
                      value=${adoptTurnId.value}
                      ariaLabel="검증된 Codex turn ID"
                      testId="codex-session-adopt-turn"
                      disabled=${resolving.value}
                      onInput=${(event: Event) => { adoptTurnId.value = (event.target as HTMLInputElement).value }}
                    />
                  </label>
                  <${ActionButton}
                    variant="ok"
                    size="sm"
                    testId="codex-session-adopt-verified"
                    disabled=${resolving.value || !canAdopt}
                    ariaBusy=${resolving.value}
                    onClick=${() => void resolve({
                      resolution: 'adopt_verified',
                      thread_id: adoptThreadId.value.trim(),
                      turn_id: adoptTurnId.value.trim(),
                    })}
                  >검증 결과 채택<//>
                </div>
              </div>
            `
            : null}
          ${lastResolution
            ? html`
              <div class="mt-3 border-t border-[var(--color-border-default)] pt-3 text-xs" data-testid="codex-session-last-resolution">
                <span class="text-[var(--color-fg-muted)]">last resolution</span>
                · <span class="mono">${lastResolution.resolution.kind}</span>
                · ${lastResolution.resolved_by}
                · ${timestampText(lastResolution.resolved_at)}
                · <span class="mono">${lastResolution.failure}</span>
              </div>
            `
            : null}
        `
        : null}
    <//>
  `
}
