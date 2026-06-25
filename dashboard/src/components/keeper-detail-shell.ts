import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { signal } from '@preact/signals'
import { TimeAgo } from './common/time-ago'
import type { Keeper } from '../types'
import { keepers } from '../store'
import { KeeperPhaseAndStage } from './keeper-phase-indicator'
import { keeperDisplayModel } from '../lib/keeper-runtime-display'
import { KeeperBadge } from './keeper-badge'

function SectionLabel({ children }: { children: unknown }) {
  return html`<div class="text-3xs font-semibold uppercase tracking-[var(--track-label)] text-[var(--color-fg-muted)]">${children}</div>`
}

function KeeperModelChip({ keeper }: { keeper: Keeper }) {
  const display = keeperDisplayModel(keeper)
  if (!display) return null
  return html`
    <span
      class="inline-flex max-w-full min-w-0 items-center py-0.5 px-2 rounded-[var(--r-1)] text-3xs font-mono bg-[var(--accent-12)] text-[var(--color-accent-fg)] border border-[var(--accent-20)]"
      title=${`${display.label}: ${display.value}`}
    ><span class="block min-w-0 truncate">${display.value}</span></span>
  `
}

export function KeeperDetailMissingState({
  keeperName,
  onClose,
}: {
  keeperName: string
  onClose: () => void
}) {
  // #12283: split the message by registry state. If [keepers.value] is empty
  // we are likely in a refresh transition (data still loading); if it has
  // entries but our target is missing, the keeper is genuinely absent — most
  // commonly a stale-watchdog kill (KeeperHeartbeat.tla idle_turn class) or
  // an operator stop. Naming the cause lets the operator decide between
  // "wait for refresh" and "filter is pointing at a dead keeper".
  const liveCount = keepers.value.length
  const isLikelyDead = liveCount > 0
  const explanation = isLikelyDead
    ? `현재 fleet에 ${keeperName}이(가) 없습니다 (live ${liveCount}명). watchdog 종료 또는 operator stop 가능성이 높습니다 — masc_keeper_stale_termination_total{keeper=\"${keeperName}\"} 에서 종료 시각을 확인하세요.`
    : '레지스트리가 아직 로드되지 않았습니다. 잠시 후 자동 갱신됩니다.'
  return html`
    <div class="mx-auto flex w-full max-w-[1100px] flex-col gap-4 v2-monitoring-surface">
      <div class="rounded-[var(--r-6)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-6 py-6 shadow-[var(--shadow-raised)] v2-monitoring-panel">
        <${SectionLabel}>키퍼 상세</${SectionLabel}>
        <h2 class="m-0 mt-2 text-xl font-semibold text-[var(--color-fg-primary)]">${keeperName}</h2>
        <p class="m-0 mt-2 text-sm leading-relaxed text-[var(--color-fg-secondary)]">
          ${explanation}
        </p>
        <div class="mt-4">
          <button
            type="button"
            class="inline-flex items-center gap-2 rounded-full border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-4 py-2 text-sm font-medium text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--color-bg-hover)] v2-monitoring-action"
            onClick=${onClose}
          >
            목록으로 돌아가기
          </button>
        </div>
      </div>
    </div>
  `
}

export function KeeperDetailHeaderInfo({
  keeper,
  titleId,
  phaseEnteredAtSec,
  onClose,
}: {
  keeper: Keeper
  titleId: string
  phaseEnteredAtSec: number | null
  onClose: () => void
}) {
  return html`
    <div class="flex min-w-0 flex-wrap items-center gap-3 v2-monitoring-surface">
      <button
        type="button"
        onClick=${onClose}
        class="inline-flex shrink-0 items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1.5 text-xs font-semibold text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--color-bg-hover)] v2-monitoring-action"
      >
        <span aria-hidden="true">←</span>
        목록
      </button>
      <div class="size-9 shrink-0 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] border border-[var(--color-border-default)] flex items-center justify-center text-lg">
        ${keeper.emoji
          ? html`<span aria-hidden="true">${keeper.emoji}</span>`
          : html`<${KeeperBadge} id=${keeper.name} size="lg" variant="sigil" />`}
      </div>
      <div class="flex min-w-0 flex-1 flex-col gap-0.5">
        <div class="flex flex-wrap items-center gap-2.5">
          <h2 id=${titleId} class="m-0 min-w-0 truncate text-xl font-semibold text-[var(--color-fg-primary)]">${keeper.name}</h2>
          <${KeeperPhaseAndStage}
            phase=${keeper.lifecycle_phase ?? keeper.phase}
            pipelineStage=${keeper.pipeline_stage}
            pipelineStageDetail=${keeper.pipeline_stage_detail}
            phaseEnteredAtSec=${phaseEnteredAtSec}
          />
          <${KeeperModelChip} keeper=${keeper} />
        </div>
        ${keeper.koreanName || keeper.created_at ? html`
          <div class="flex flex-wrap items-center gap-2 text-xs text-[var(--color-fg-muted)]">
            ${keeper.koreanName ? html`<span>${keeper.koreanName}</span>` : null}
            ${'' /* 활동 시각은 사이드바의 keeperActivityDisplay()가 SSOT. 여기서는 keeper 생성 시각만 표시하며 라벨로 의미를 분리한다. */}
            ${keeper.created_at ? html`<span class="font-mono tabular-nums opacity-60">생성 <${TimeAgo} timestamp=${keeper.created_at} /></span>` : null}
          </div>
        ` : null}
      </div>
    </div>
  `
}

type KeeperDetailSectionId =
  | 'keeper-summary'
  | 'keeper-comms'
  | 'keeper-runtime'
  | 'keeper-identity'
  | 'keeper-config'
  | 'keeper-debug'

export const activeKeeperDetailSection = signal<KeeperDetailSectionId>('keeper-comms')

const KEEPER_DETAIL_SECTIONS: Array<{
  id: KeeperDetailSectionId
  label: string
}> = [
  {
    id: 'keeper-comms',
    label: '대화',
  },
  {
    id: 'keeper-summary',
    label: '상태',
  },
  {
    id: 'keeper-runtime',
    label: '진단',
  },
  {
    id: 'keeper-identity',
    label: '정체성',
  },
  {
    id: 'keeper-config',
    label: '설정',
  },
  {
    id: 'keeper-debug',
    label: '디버그',
  },
]

function selectKeeperDetailSection(sectionId: KeeperDetailSectionId): void {
  activeKeeperDetailSection.value = sectionId
}

export function KeeperDetailSectionRail() {
  const active = activeKeeperDetailSection.value
  return html`
    <nav
      class="kw-detail-section-rail sm:sticky sm:top-[var(--header-h)] z-10 overflow-x-auto border-b border-[var(--color-border-default)] bg-[var(--color-bg-page)] py-1.5 v2-monitoring-toolbar"
      aria-label="키퍼 상세 섹션"
    >
      <div class="kw-detail-section-tabs flex min-w-max items-center gap-1.5 px-1" role="tablist" aria-label="키퍼 상세 탭">
        ${KEEPER_DETAIL_SECTIONS.map((section) => html`
          <button
            id=${`${section.id}-tab`}
            type="button"
            role="tab"
            aria-selected=${active === section.id}
            aria-controls=${section.id}
            class=${active === section.id
              ? 'kw-detail-section-tab h-8 shrink-0 rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-12)] px-3 text-2xs font-semibold text-[var(--color-accent-fg)] transition-colors'
              : 'kw-detail-section-tab h-8 shrink-0 rounded-[var(--r-1)] border border-transparent px-3 text-2xs font-semibold text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-surface)] hover:text-[var(--color-fg-primary)]'}
            onClick=${() => selectKeeperDetailSection(section.id)}
          >
            ${section.label}
          </button>
        `)}
      </div>
    </nav>
  `
}

export function KeeperDetailSection({
  id,
  eyebrow,
  title,
  lockedOpen = false,
  variant = 'default',
  children,
}: {
  id: KeeperDetailSectionId
  eyebrow: string
  title: string
  /** Preserved for old call sites; top-level keeper detail sections now render
   *  as tabs, while nested CollapsibleSection handles local disclosure. */
  defaultCollapsed?: boolean
  /** Primary sections, such as the chat lane, stay open and do not expose
   *  collapse controls. */
  lockedOpen?: boolean
  variant?: 'default' | 'primary'
  children: ComponentChildren
}) {
  const isActive = activeKeeperDetailSection.value === id
  const bodyId = `${id}-body`
  const sectionClass = variant === 'primary'
    ? 'scroll-mt-24 rounded-[var(--r-2)] bg-transparent shadow-none'
    : 'scroll-mt-24 rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-none'
  const headerClass = variant === 'primary'
    ? 'sr-only'
    : 'flex w-full items-center justify-between gap-3 border-b border-[var(--color-border-default)] px-4 py-3 text-left transition-colors hover:bg-[var(--color-bg-hover)] sm:px-5'
  if (!isActive) return null
  const headerContent = html`
    <div class="min-w-0">
      <div class="text-3xs font-semibold uppercase tracking-[var(--track-brand)] text-[var(--color-fg-muted)]">${eyebrow}</div>
      <h3 class="m-0 mt-1 text-lg font-semibold text-[var(--color-fg-primary)]">${title}</h3>
    </div>
    ${lockedOpen && variant !== 'primary'
      ? html`<span class="shrink-0 rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-accent-fg)]">기본</span>`
      : lockedOpen
        ? null
      : null}
  `
  return html`
    <section
      id=${id}
      class=${`${sectionClass} v2-monitoring-panel`}
      aria-label=${title}
      aria-labelledby=${`${id}-tab`}
      role="tabpanel"
    >
      <div class=${`${headerClass} v2-monitoring-toolbar`}>${headerContent}</div>
      <div id=${bodyId} class=${variant === 'primary' ? 'flex flex-col gap-4 px-0 py-0 v2-monitoring-panel' : 'flex flex-col gap-4 px-4 py-4 sm:px-5 v2-monitoring-panel'}>
        ${children}
      </div>
    </section>
  `
}
