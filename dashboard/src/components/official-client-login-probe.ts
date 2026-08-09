import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import {
  probeOfficialClientLogin,
  type DashboardOfficialClientLoginStatus,
  type DashboardOfficialClientProbeResponse,
} from '../api/dashboard'
import { errorToString } from '../lib/format-string'
import { ActionButton } from './common/button'
import { StatusChip } from './common/status-chip'

interface OfficialClientLoginProbeProps {
  runtimeId: string
  configuredModel?: string | null
}

function loginTone(status: DashboardOfficialClientLoginStatus | 'not_measured'):
  'ok' | 'warn' | 'bad' | 'neutral' {
  if (status === 'ready') return 'warn'
  if (status === 'not_measured' || status === 'timeout') return 'warn'
  return 'bad'
}

function measuredAtText(value: number): string {
  return new Date(value * 1_000).toLocaleString()
}

export function OfficialClientLoginProbe({
  runtimeId,
  configuredModel,
}: OfficialClientLoginProbeProps) {
  const response = useSignal<DashboardOfficialClientProbeResponse | null>(null)
  const loading = useSignal(false)
  const error = useSignal<string | null>(null)

  const probe = async () => {
    if (loading.value) return
    loading.value = true
    error.value = null
    try {
      response.value = await probeOfficialClientLogin(runtimeId)
    } catch (cause) {
      response.value = null
      error.value = errorToString(cause)
    } finally {
      loading.value = false
    }
  }

  const measured = response.value
  const loginStatus = measured?.login.status ?? 'not_measured'
  const loginStatusLabel = loginStatus === 'ready' ? 'self_reported' : loginStatus
  const model = measured?.configured_model ?? configuredModel ?? '—'

  return html`
    <section
      class="mt-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]/55 p-3"
      data-testid=${`official-client-login-probe-${runtimeId}`}
      aria-label=${`${runtimeId} subscription login evidence`}
    >
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <div class="text-xs font-semibold text-[var(--color-fg-primary)]">공식 CLI 구독 상태</div>
          <div class="mt-0.5 text-2xs text-[var(--color-fg-muted)]">
            로그인만 검사하며 모델 턴은 생성하지 않습니다.
          </div>
        </div>
        <${ActionButton}
          variant="ghost"
          size="sm"
          testId=${`official-client-login-probe-run-${runtimeId}`}
          disabled=${loading.value}
          ariaBusy=${loading.value}
          onClick=${() => void probe()}
        >${loading.value ? '확인 중…' : '로그인 확인'}<//>
      </div>

      <div class="grid grid-cols-1 gap-2 md:grid-cols-3">
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)]/70 p-2" data-testid="official-client-probe-configuration">
          <div class="mb-1 text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Configuration</div>
          <${StatusChip} tone="ok" uppercase=${false}>configured<//>
          <div class="mt-1 truncate text-2xs text-[var(--color-fg-secondary)]" title=${model}>${model}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)]/70 p-2" data-testid="official-client-probe-login">
          <div class="mb-1 text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Login</div>
          <${StatusChip} tone=${loginTone(loginStatus)} uppercase=${false}>${loginStatusLabel}<//>
          <div class="mt-1 text-2xs text-[var(--color-fg-secondary)]">
            ${measured ? measuredAtText(measured.measured_at) : '수동 확인 전'}
          </div>
        </div>
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)]/70 p-2" data-testid="official-client-probe-execution">
          <div class="mb-1 text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Execution</div>
          <${StatusChip} tone="neutral" uppercase=${false}>not_measured<//>
          <div class="mt-1 text-2xs text-[var(--color-fg-secondary)]">로그인 검사에서는 실행하지 않음</div>
        </div>
      </div>

      ${measured
        ? html`
          <div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-2xs text-[var(--color-fg-muted)]" data-testid="official-client-probe-details">
            <span>client · <span class="mono text-[var(--color-fg-secondary)]">${measured.client_kind}</span></span>
            <span>identity · <span class="mono text-[var(--status-warn)]">unverified</span></span>
            <span>auth · <span class="mono text-[var(--color-fg-secondary)]">${measured.login.auth_method ?? '—'}</span></span>
            <span>plan · <span class="mono text-[var(--color-fg-secondary)]">${measured.login.subscription_type ?? '—'}</span></span>
            <span>provider · <span class="mono text-[var(--color-fg-secondary)]">${measured.login.api_provider ?? '—'}</span></span>
            <span>CLI · <span class="mono text-[var(--color-fg-secondary)]">${measured.client.user_agent ?? '—'}</span></span>
          </div>
        `
        : null}
      ${measured?.login.detail
        ? html`<div class="mt-2 break-words text-2xs text-[var(--status-bad)]" data-testid="official-client-probe-detail">${measured.login.detail}</div>`
        : null}
      ${error.value
        ? html`<div class="mt-2 break-words text-2xs text-[var(--status-bad)]" role="alert" data-testid="official-client-probe-error">${error.value}</div>`
        : null}
    </section>
  `
}
