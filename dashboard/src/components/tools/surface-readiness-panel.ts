import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  fetchDashboardSurfaceReadiness,
  type DashboardSurfaceReadinessItem,
  type DashboardSurfaceReadinessResponse,
} from '../../api'

const readinessData = signal<DashboardSurfaceReadinessResponse | null>(null)
const readinessError = signal<string | null>(null)
const readinessLoading = signal(false)

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

function exposureTone(value: string): string {
  switch (value) {
    case 'main':
      return 'text-[var(--ok)] bg-[var(--ok-10)] border-[rgba(74,222,128,0.2)]'
    case 'lab':
      return 'text-[var(--warn)] bg-[var(--warn-12)] border-[rgba(251,191,36,0.2)]'
    default:
      return 'text-[var(--bad)] bg-[var(--bad-12)] border-[rgba(239,68,68,0.2)]'
  }
}

function openRouteHash(routeHash?: string | null) {
  if (!routeHash) return
  window.location.hash = routeHash
}

function SurfaceReadinessRow({ item }: { item: DashboardSurfaceReadinessItem }) {
  const refs = item.verification_refs.slice(0, 3)
  return html`
    <article class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] p-4 grid gap-3">
      <div class="flex items-start justify-between gap-3">
        <div class="grid gap-1">
          <div class="flex items-center gap-2 flex-wrap">
            <strong class="text-[14px] text-[var(--text-strong)]">${item.label}</strong>
            <span class="px-2 py-0.5 rounded-full border text-[10px] uppercase tracking-[0.06em] ${exposureTone(item.exposure_status)}">
              ${item.exposure_status}
            </span>
            ${item.hidden_from_nav ? html`<span class="px-2 py-0.5 rounded-full border border-[var(--white-8)] text-[10px] text-[var(--text-muted)]">main nav hidden</span>` : null}
          </div>
          <span class="text-[12px] text-[var(--text-muted)] leading-[1.5]">${item.rationale}</span>
        </div>
        ${item.route_hash
          ? html`
              <button
                type="button"
                class="px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
                onClick=${() => openRouteHash(item.route_hash)}
              >
                열기
              </button>
            `
          : null}
      </div>
      <div class="flex items-center gap-2 flex-wrap text-[11px] text-[var(--text-muted)]">
        <span>gate: ${item.proof_bar}</span>
        <span>${item.meets_main_gate ? 'main ready' : 'gate missing'}</span>
      </div>
      ${refs.length > 0
        ? html`
            <div class="grid gap-1.5">
              ${refs.map(ref => html`
                <div key=${`${item.id}:${ref.label}`} class="text-[11px] text-[var(--text-muted)] font-mono break-all">
                  ${ref.label} · ${ref.value}
                </div>
              `)}
            </div>
          `
        : null}
    </article>
  `
}

export function SurfaceReadinessPanel() {
  useEffect(() => {
    if (!readinessData.value && !readinessLoading.value) {
      void loadSurfaceReadiness()
    }
  }, [])

  const data = readinessData.value
  const items = [...(data?.surfaces ?? [])].sort((a, b) => {
    const rank = (value: string) => (value === 'lab' ? 0 : value === 'hidden' ? 1 : 2)
    return rank(a.exposure_status) - rank(b.exposure_status)
  })

  if (readinessError.value) {
    return html`<div class="text-[13px] text-[var(--bad)]">${readinessError.value}</div>`
  }

  if (readinessLoading.value && !data) {
    return html`<div class="text-[12px] text-[var(--text-muted)]">surface readiness 불러오는 중...</div>`
  }

  if (!data) {
    return html`<div class="text-[12px] text-[var(--text-muted)]">surface readiness 데이터가 없습니다.</div>`
  }

  return html`
    <div class="grid gap-3">
      <div class="text-[12px] text-[var(--text-muted)] leading-[1.5]">
        메인 노출은 fixture + live spotcheck 기준으로 판단합니다. 현재는 readiness audit가 낮은 surface를 먼저 위로 올려서 보여줍니다.
      </div>
      ${items.map(item => html`<${SurfaceReadinessRow} key=${item.id} item=${item} />`)}
    </div>
  `
}
