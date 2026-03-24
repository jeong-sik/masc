import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  fetchDashboardSurfaceReadiness,
  type DashboardSurfaceReadinessItem,
  type DashboardSurfaceReadinessResponse,
  type DashboardVerificationRef,
} from '../../api'

const readinessData = signal<DashboardSurfaceReadinessResponse | null>(null)
const readinessError = signal<string | null>(null)
const readinessLoading = signal(false)

const SURFACE_SUMMARY_BY_ID: Record<string, string> = {
  'monitoring.sessions': '세션 운영과 룸 현황을 바로 확인하는 기본 화면입니다.',
  'monitoring.agents': '일반 에이전트와 키퍼 상태를 관찰하는 기본 화면입니다.',
  'monitoring.activity': '실시간 활동 흐름과 이벤트 변화를 추적하는 화면입니다.',
  'command.intervene': '방, 세션, 키퍼에 운영자가 직접 개입하는 화면입니다.',
  'command.warroom': '오케스트라, 스웜, 체인 제어를 시험하는 실험 화면입니다.',
  'command.governance': '판단과 판결 상태를 확인하는 운영 화면입니다.',
  'workspace.evidence': '증빙과 audit trail을 확인하는 기본 화면입니다.',
  'lab.tools': '도구 인벤토리와 준비도 감사를 보는 실험 화면입니다.',
}

const VERIFICATION_LABELS: Record<string, string> = {
  fixture_harness: 'Fixture',
  live_spotcheck: 'Live Spotcheck',
  logs: 'Logs',
  metrics: 'Metrics',
  proof: 'Proof',
  tool_name: 'Tool',
}

type SurfaceGroup = {
  id: 'main' | 'deferred'
  title: string
  description: string
  items: DashboardSurfaceReadinessItem[]
}

async function loadSurfaceReadiness() {
  if (readinessLoading.value) return
  readinessLoading.value = true
  readinessError.value = null
  try {
    readinessData.value = await fetchDashboardSurfaceReadiness()
  } catch (err) {
    readinessError.value = err instanceof Error ? err.message : String(err)
  } finally {
    readinessLoading.value = false
  }
}

function isMainOperationalSurface(item: DashboardSurfaceReadinessItem): boolean {
  return item.exposure_status === 'main' && item.meets_main_gate
}

function formatProofBar(value: string): string {
  return value
    .split('+')
    .map(part => part.replaceAll('_', ' '))
    .join(' + ')
}

function surfaceSummary(item: DashboardSurfaceReadinessItem): string {
  return SURFACE_SUMMARY_BY_ID[item.id] ?? item.rationale
}

function surfaceStatusLabel(item: DashboardSurfaceReadinessItem): string {
  if (isMainOperationalSurface(item)) return '메인 운영'
  if (item.exposure_status === 'lab') return '실험'
  if (item.exposure_status === 'hidden' || item.hidden_from_nav) return '숨김'
  return '보류'
}

function surfaceStatusTone(item: DashboardSurfaceReadinessItem): string {
  if (isMainOperationalSurface(item)) {
    return 'text-[var(--ok)] bg-[var(--ok-10)] border-[rgba(74,222,128,0.2)]'
  }

  if (item.exposure_status === 'lab') {
    return 'text-[var(--warn)] bg-[var(--warn-12)] border-[rgba(251,191,36,0.2)]'
  }

  return 'text-[var(--bad)] bg-[var(--bad-12)] border-[rgba(239,68,68,0.2)]'
}

function verificationLabel(ref: DashboardVerificationRef): string {
  return VERIFICATION_LABELS[ref.label] ?? ref.label
}

function openRouteHash(routeHash?: string | null) {
  if (!routeHash) return
  window.location.hash = routeHash
}

function readinessGroups(items: DashboardSurfaceReadinessItem[]): SurfaceGroup[] {
  const main = items.filter(isMainOperationalSurface)
  const deferred = items.filter(item => !isMainOperationalSurface(item))

  return [
    {
      id: 'main',
      title: '메인 운영',
      description: '바로 들어가서 운영 판단과 관찰에 쓰는 surface입니다.',
      items: main,
    },
    {
      id: 'deferred',
      title: '실험/보류',
      description: 'Lab에 두거나 메인 메뉴에서 숨긴 surface입니다.',
      items: deferred,
    },
  ]
}

function SurfaceReadinessRow({ item }: { item: DashboardSurfaceReadinessItem }) {
  const refs = item.verification_refs

  return html`
    <article
      data-surface-id=${item.id}
      class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] p-4 grid gap-3"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="grid gap-2">
          <div class="flex items-center gap-2 flex-wrap">
            <strong class="text-[14px] text-[var(--text-strong)]">${item.label}</strong>
            <span class="px-2 py-0.5 rounded-full border text-[10px] tracking-[0.04em] ${surfaceStatusTone(item)}">
              ${surfaceStatusLabel(item)}
            </span>
            ${item.hidden_from_nav
              ? html`<span class="px-2 py-0.5 rounded-full border border-[var(--white-8)] text-[10px] text-[var(--text-muted)]">메인 메뉴 숨김</span>`
              : null}
          </div>
          <span class="text-[12px] text-[var(--text-muted)] leading-[1.6]">${surfaceSummary(item)}</span>
        </div>
        ${item.route_hash
          ? html`
              <button
                type="button"
                class="shrink-0 px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
                onClick=${() => openRouteHash(item.route_hash)}
              >
                이 화면 열기
              </button>
            `
          : null}
      </div>
      <details class="rounded-lg border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-2">
        <summary class="cursor-pointer text-[12px] text-[var(--text-strong)] font-medium">
          검증 근거 보기
        </summary>
        <div class="mt-3 grid gap-2">
          <div class="grid gap-1">
            <span class="text-[11px] uppercase tracking-[0.05em] text-[var(--text-muted)]">운영 판단</span>
            <div class="text-[12px] text-[var(--text-muted)] leading-[1.5]">${item.rationale}</div>
          </div>
          ${refs.map(ref => html`
            <div key=${`${item.id}:${ref.label}`} class="grid gap-1">
              <span class="text-[11px] uppercase tracking-[0.05em] text-[var(--text-muted)]">
                ${verificationLabel(ref)}
              </span>
              <div class="text-[12px] font-mono break-all text-[var(--text-body)]">${ref.value}</div>
            </div>
          `)}
        </div>
      </details>
    </article>
  `
}

function SurfaceReadinessGroup({ group }: { group: SurfaceGroup }) {
  return html`
    <section data-surface-group=${group.id} class="grid gap-3">
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <div class="grid gap-1">
          <strong class="text-[13px] text-[var(--text-strong)]">${group.title}</strong>
          <span class="text-[12px] text-[var(--text-muted)] leading-[1.5]">${group.description}</span>
        </div>
        <span class="px-2.5 py-1 rounded-full border border-[var(--card-border)] text-[11px] text-[var(--text-muted)]">
          ${group.items.length}개
        </span>
      </div>
      ${group.items.length > 0
        ? group.items.map(item => html`<${SurfaceReadinessRow} key=${item.id} item=${item} />`)
        : html`<div class="rounded-xl border border-dashed border-[var(--card-border)] px-4 py-3 text-[12px] text-[var(--text-muted)]">
            노출된 surface가 없습니다.
          </div>`}
    </section>
  `
}

export function SurfaceReadinessPanel() {
  useEffect(() => {
    if (!readinessData.value && !readinessLoading.value) {
      void loadSurfaceReadiness()
    }
  }, [])

  const data = readinessData.value
  const items = data?.surfaces ?? []
  const groups = readinessGroups(items)
  const mainCount = groups[0]?.items.length ?? 0
  const deferredCount = groups[1]?.items.length ?? 0

  if (readinessError.value) {
    return html`<div class="text-[13px] text-[var(--bad)]">${readinessError.value}</div>`
  }

  if (readinessLoading.value && !data) {
    return html`<div class="text-[12px] text-[var(--text-muted)]">운영 surface 안내를 불러오는 중...</div>`
  }

  if (!data) {
    return html`<div class="text-[12px] text-[var(--text-muted)]">운영 surface 안내 데이터가 없습니다.</div>`
  }

  return html`
    <div class="grid gap-4">
      <div class="grid gap-2">
        <div class="text-[12px] text-[var(--text-muted)] leading-[1.6]">
          운영자는 메인 surface부터 보고, 실험/보류 surface는 필요할 때만 근거를 펼쳐 확인하면 됩니다.
        </div>
      </div>

      <div class="grid gap-3 sm:grid-cols-3">
        <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] px-4 py-3 grid gap-1">
          <span class="text-[11px] uppercase tracking-[0.05em] text-[var(--text-muted)]">메인 운영</span>
          <strong class="text-[20px] text-[var(--text-strong)]">${mainCount}</strong>
        </div>
        <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] px-4 py-3 grid gap-1">
          <span class="text-[11px] uppercase tracking-[0.05em] text-[var(--text-muted)]">실험/보류</span>
          <strong class="text-[20px] text-[var(--text-strong)]">${deferredCount}</strong>
        </div>
        <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] px-4 py-3 grid gap-1">
          <span class="text-[11px] uppercase tracking-[0.05em] text-[var(--text-muted)]">판단 기준</span>
          <strong class="text-[14px] text-[var(--text-strong)]">${formatProofBar(data.proof_bar)}</strong>
        </div>
      </div>

      ${groups.map(group => html`<${SurfaceReadinessGroup} key=${group.id} group=${group} />`)}
    </div>
  `
}
