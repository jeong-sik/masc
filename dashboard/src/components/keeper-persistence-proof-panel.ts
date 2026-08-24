// Verification workspace projection for durable Keeper turn-span evidence.
//
// This is deliberately not an uptime panel. A tier passes only when the
// decision log contains enough ordered turn history; the explicit evidence
// label keeps operators from reading durable history as process continuity.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import {
  fetchKeeperPersistenceProof,
  type DashboardKeeperPersistenceProofResponse,
  type KeeperFeatureProofStatus,
  type KeeperPersistenceTierProof,
} from '../api/dashboard'
import type { ManagedAsyncResource } from '../lib/async-state'
import { relativeTime } from '../lib/format-time'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { registerInternalAgentRefresh } from '../sse-store'
import { Btn } from './btn'
import { EmptyState, ErrorState } from './common/feedback-state'
import { StatusBadge, type StatusBadgeTone } from './common/status-badge'

export function keeperProofTone(status: KeeperFeatureProofStatus): StatusBadgeTone {
  switch (status) {
    case 'pass':
      return 'ok'
    case 'warn':
      return 'warn'
    case 'fail':
      return 'bad'
  }
}

function keeperProofLabel(status: KeeperFeatureProofStatus): string {
  switch (status) {
    case 'pass':
      return '충족'
    case 'warn':
      return '부분 충족'
    case 'fail':
      return '미충족'
  }
}

async function loadData(resource: ManagedAsyncResource<DashboardKeeperPersistenceProofResponse>) {
  await resource.load(async signal => fetchKeeperPersistenceProof({ signal }))
}

function KeeperPersistenceTierCard({ tier }: { tier: KeeperPersistenceTierProof }) {
  const observedLabel = tier.keeperCount === 0
    ? '관찰할 Keeper 없음'
    : `${tier.observedCount}/${tier.keeperCount} Keeper`
  return html`
    <article
      class="rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-3"
      data-testid=${`keeper-persistence-tier-${tier.id}`}
      data-tier-id=${tier.id}
      data-proof-status=${tier.status}
      data-evidence-kind=${tier.evidenceKind}
      data-observed-count=${tier.observedCount}
      data-keeper-count=${tier.keeperCount}
      data-missing-count=${tier.missingCount}
      data-undetermined-count=${tier.undeterminedCount}
    >
      <div class="flex items-center justify-between gap-2">
        <strong class="text-base tabular-nums text-[var(--color-fg-primary)]">${tier.id}</strong>
        <${StatusBadge}
          tone=${keeperProofTone(tier.status)}
          label=${keeperProofLabel(tier.status)}
        />
      </div>
      <div class="mt-2 text-sm font-medium tabular-nums text-[var(--color-fg-primary)]">
        ${observedLabel}
      </div>
      <div class="mt-1 text-xs text-[var(--color-fg-muted)]">
        durable turn span ≥ ${tier.requiredSpanHours}h
      </div>
      ${tier.missingKeepers.length > 0
        ? html`
            <details class="mt-2 text-xs text-[var(--color-fg-secondary)]">
              <summary class="cursor-pointer">근거 부족 ${tier.missingCount}</summary>
              <div class="mt-1 break-words" data-testid=${`keeper-persistence-missing-${tier.id}`}>
                ${tier.missingKeepers.join(', ')}
              </div>
            </details>
          `
        : null}
      ${tier.undeterminedKeepers.length > 0
        ? html`
            <details class="mt-2 text-xs text-[var(--color-fg-muted)]">
              <summary class="cursor-pointer">확인 못 함 ${tier.undeterminedCount}</summary>
              <div
                class="mt-1 break-words"
                data-testid=${`keeper-persistence-undetermined-${tier.id}`}
              >
                기록을 끝까지 읽지 못해 이 Keeper 의 지속 시간을 알 수 없어요.
                ${tier.undeterminedKeepers.join(', ')}
              </div>
            </details>
          `
        : null}
    </article>
  `
}

export function KeeperPersistenceProofPanel() {
  const resource = useManagedAsyncResource<DashboardKeeperPersistenceProofResponse>()

  useEffect(() => {
    void loadData(resource)
    const unregister = registerInternalAgentRefresh(() => { void loadData(resource) })
    return () => {
      unregister()
      resource.cancel()
    }
  }, [resource])

  const current = resource.state.value
  const data = current.data ?? null

  return html`
    <section
      class="v2-workspace-surface flex flex-col gap-3"
      data-testid="keeper-persistence-proof-panel"
      data-proof-generated-at=${data?.generatedAt ?? ''}
      aria-labelledby="keeper-persistence-proof-heading"
    >
      <div class="flex items-center gap-3 flex-wrap">
        <h2
          id="keeper-persistence-proof-heading"
          class="text-sm font-semibold text-[var(--color-fg-primary)]"
        >
          Keeper 지속성 근거
        </h2>
        ${data
          ? html`<${StatusBadge}
              tone=${keeperProofTone(data.status)}
              label=${keeperProofLabel(data.status)}
            />`
          : null}
        <${Btn}
          class="v2-workspace-action"
          testId="keeper-persistence-proof-refresh"
          disabled=${current.loading}
          onClick=${() => void loadData(resource)}
        >
          새로고침
        <//>
        ${current.loading
          ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>`
          : null}
        ${data?.generatedAt
          ? html`<span class="text-xs text-[var(--color-fg-muted)]">
              updated · ${relativeTime(data.generatedAt)}
            </span>`
          : null}
      </div>

      <p class="text-xs text-[var(--color-fg-muted)]">
        decision log의 <strong>durable turn span</strong> 근거입니다. 무중단 uptime 증거가 아닙니다.
      </p>

      ${current.error
        ? html`<${ErrorState}>Keeper 지속성 근거를 불러오지 못했습니다: ${current.error}<//>`
        : data == null && !current.loading
          ? html`<${EmptyState}>지속성 근거가 없습니다.<//>`
          : data
            ? html`
                <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
                  ${data.tiers.map(tier => html`<${KeeperPersistenceTierCard} key=${tier.id} tier=${tier} />`)}
                </div>
                <p class="text-xs text-[var(--color-fg-secondary)]">${data.summary}</p>
              `
            : null}
    </section>
  `
}
