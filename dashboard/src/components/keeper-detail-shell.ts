import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchCascadeProfiles, updateKeeperCascade } from '../api/dashboard'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import type { Keeper } from '../types'
import { refreshDashboard, keepers } from '../store'
import { KeeperPhaseAndStage } from './keeper-phase-indicator'
import { formatDuration } from '../lib/format-time'
import {
  keeperDisplayModel,
  type KeeperActivityDisplay,
} from '../lib/keeper-runtime-display'

function SectionLabel({ children }: { children: unknown }) {
  return html`<div class="text-3xs font-semibold uppercase tracking-[0.18em] text-[var(--color-fg-muted)]">${children}</div>`
}

function KeeperModelChip({ keeper }: { keeper: Keeper }) {
  const display = keeperDisplayModel(keeper)
  if (!display) return null
  return html`
    <span
      class="inline-flex items-center py-0.5 px-2 rounded text-3xs font-mono bg-[var(--accent-12)] text-[var(--color-accent-fg)] border border-[var(--accent-20)]"
      title=${`${display.label}: ${display.value}`}
    >${display.value}</span>
  `
}

function KeeperCascadeSelector({ keeper }: { keeper: Keeper }) {
  const [cascadeProfiles, setCascadeProfiles] = useState<Awaited<ReturnType<typeof fetchCascadeProfiles>> | null>(null)
  const [draftCascade, setDraftCascade] = useState<{
    keeperName: string
    from: string
    cascade: string
  } | null>(null)

  useEffect(() => {
    let cancelled = false
    fetchCascadeProfiles()
      .then((next) => {
        if (!cancelled) setCascadeProfiles(next)
      })
      .catch((err) => {
        // P1 silent-failure fix: an empty selector previously rendered
        // identically to "no profiles to switch between" (line 69 returns
        // null when profiles + invalid_profiles <= 1).  Surfacing the
        // failure to the console lets an operator distinguish "fetch
        // failed" from "no profiles configured" via DevTools.
        if (!cancelled) {
          console.warn('[keeper-cascade-selector] fetchCascadeProfiles failed', err)
        }
      })
    return () => {
      cancelled = true
    }
  }, [])

  const fallbackCascade = keeper.cascade_name || 'default'
  const currentCascade = draftCascade?.keeperName === keeper.name && draftCascade.from === fallbackCascade
    ? draftCascade.cascade
    : fallbackCascade
  const profiles = cascadeProfiles?.profiles ?? []
  const invalidProfiles = cascadeProfiles?.invalid_profiles ?? []
  if (profiles.length + invalidProfiles.length <= 1) return null

  const invalidSummary = invalidProfiles
    .map((profile) => `${profile.name}: ${profile.errors.join(' | ')}`)
    .join('\n')
  const knownValues = new Set([
    ...profiles,
    ...invalidProfiles.map((profile) => profile.name),
  ])

  return html`
    <div class="flex items-center gap-1.5">
      <select
        aria-label="Cascade 프로필 선택"
        class="py-0.5 px-1 rounded text-3xs font-mono bg-[var(--white-5)] text-[var(--color-fg-muted)] border border-[var(--white-8)] cursor-pointer"
        title=${invalidProfiles.length > 0
          ? `Cascade 프로필\n\n비활성화된 잘못된 프로필:\n${invalidSummary}`
          : 'Cascade 프로필'}
        value=${currentCascade}
        onChange=${(e: Event) => {
          const val = (e.target as HTMLSelectElement).value
          const draft = { keeperName: keeper.name, from: fallbackCascade, cascade: val }
          setDraftCascade(draft)
          updateKeeperCascade(keeper.name, val)
            .then(() => {
              refreshDashboard()
            })
            .catch((err) => {
              setDraftCascade((current) => current === draft ? null : current)
              const msg = err instanceof Error ? err.message : 'Cascade 변경 실패'
              showToast(msg, 'error')
            })
        }}
      >
        ${!knownValues.has(currentCascade) && currentCascade
          ? html`<option value=${currentCascade}>${currentCascade} (current)</option>`
          : null}
        ${profiles.map((profile) => html`<option value=${profile}>${profile}</option>`)}
        ${invalidProfiles.length > 0
          ? html`<option disabled>──────── invalid ────────</option>`
          : null}
        ${invalidProfiles.map((profile) => html`
          <option
            value=${profile.name}
            disabled
            title=${profile.errors.join(' | ')}
          >${profile.name} (invalid)</option>
        `)}
      </select>
      ${invalidProfiles.length > 0
        ? html`
            <span
              class="inline-flex items-center py-0.5 px-1.5 rounded text-3xs font-semibold bg-[var(--bad-10)] text-[var(--rose-light)] border border-[var(--bad-30)]"
              title=${invalidSummary}
            >${invalidProfiles.length} invalid</span>
          `
        : null}
    </div>
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
    <div class="mx-auto flex w-full max-w-[1100px] flex-col gap-4">
      <div class="rounded-[28px] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-6 py-6 shadow-2xl">
        <${SectionLabel}>키퍼 상세</${SectionLabel}>
        <h2 class="m-0 mt-2 text-xl font-semibold text-[var(--color-fg-primary)]">${keeperName}</h2>
        <p class="m-0 mt-2 text-sm leading-relaxed text-[var(--text-secondary)]">
          ${explanation}
        </p>
        <div class="mt-4">
          <button
            type="button"
            class="inline-flex items-center gap-2 rounded-full border border-[var(--white-10)] bg-[var(--white-4)] px-4 py-2 text-sm font-medium text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--white-8)]"
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
    <div class="flex min-w-0 items-start gap-4">
      <button
        type="button"
        onClick=${onClose}
        class="inline-flex shrink-0 items-center gap-2 rounded-full border border-[var(--white-10)] bg-[var(--white-4)] px-3.5 py-2 text-sm font-medium text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--white-8)]"
      >
        <span aria-hidden="true">←</span>
        목록
      </button>
      <div class="size-12 shrink-0 rounded bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-2xl">${keeper.emoji}</div>
      <div class="flex flex-col gap-0.5">
        <${SectionLabel}>모니터링 / 에이전트 / 키퍼 상세</${SectionLabel}>
        <div class="mt-1 flex flex-wrap items-center gap-2.5">
          <h2 id=${titleId} class="m-0 text-lg font-semibold text-[var(--color-fg-primary)]">${keeper.name}</h2>
          <${KeeperPhaseAndStage} phase=${keeper.phase} pipelineStage=${keeper.pipeline_stage} phaseEnteredAtSec=${phaseEnteredAtSec} />
          <${KeeperModelChip} keeper=${keeper} />
          <${KeeperCascadeSelector} keeper=${keeper} />
        </div>
        ${keeper.koreanName || keeper.created_at ? html`
          <div class="flex flex-wrap items-center gap-2 text-xs text-[var(--color-fg-muted)]">
            ${keeper.koreanName ? html`<span>${keeper.koreanName}</span>` : null}
            ${keeper.created_at ? html`<span class="font-mono tabular-nums opacity-60"><${TimeAgo} timestamp=${keeper.created_at} /></span>` : null}
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

const KEEPER_DETAIL_SECTIONS: Array<{
  id: KeeperDetailSectionId
  label: string
  summary: string
}> = [
  {
    id: 'keeper-summary',
    label: '상태 개요',
    summary: '상태 기계, KPI, 메모리/추론 지표를 먼저 봅니다.',
  },
  {
    id: 'keeper-comms',
    label: '대화 / 세션',
    summary: '실시간 대화와 세션 이벤트를 함께 봅니다.',
  },
  {
    id: 'keeper-runtime',
    label: '진단 / 운영',
    summary: 'runtime action, eval, supervisor, 품질 시그널을 모았습니다.',
  },
  {
    id: 'keeper-identity',
    label: '정체성 / 세대',
    summary: '프로필, 관계, generation lineage, checkpoint를 함께 봅니다.',
  },
  {
    id: 'keeper-config',
    label: '설정 / 작업 방식',
    summary: '허용 도구, repos, config를 한 곳에서 조정합니다.',
  },
  {
    id: 'keeper-debug',
    label: '디버그',
    summary: '저널과 원시 데이터를 마지막에 몰아 둡니다.',
  },
]

function scrollToKeeperDetailSection(sectionId: KeeperDetailSectionId): void {
  document.getElementById(sectionId)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function KeeperDetailQuickFact({
  label,
  children,
}: {
  label: string
  children: ComponentChildren
}) {
  return html`
    <div class="rounded-2xl border border-[var(--white-8)] bg-[var(--color-bg-panel-alt)] px-3.5 py-3">
      <${SectionLabel}>${label}</${SectionLabel}>
      <div class="mt-1 text-sm font-medium leading-snug text-[var(--color-fg-primary)]">${children}</div>
    </div>
  `
}

function KeeperActivityValue({ activity }: { activity: KeeperActivityDisplay }) {
  if (activity.timestamp) {
    return html`${activity.label} <${TimeAgo} timestamp=${activity.timestamp} />`
  }
  if (activity.ageSeconds != null) {
    return html`${activity.label} ${formatDuration(activity.ageSeconds)} 전`
  }
  return html`정보 없음`
}

export function KeeperDetailOverviewSidebar({
  effectiveStatus,
  contextRatioPct,
  effectiveModelLabel,
  effectiveModel,
  activity,
}: {
  effectiveStatus: string
  contextRatioPct: string
  effectiveModelLabel: string
  effectiveModel: string
  activity: KeeperActivityDisplay
}) {
  return html`
    <aside class="order-2 xl:order-1 xl:sticky xl:top-[104px] xl:self-start" aria-label="키퍼 프로필 요약">
      <div class="flex flex-col gap-4 rounded-[28px] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 shadow-xl">
        <div>
          <${SectionLabel}>개요</${SectionLabel}>
          <p class="m-0 mt-2 text-sm leading-relaxed text-[var(--text-secondary)]">
            긴 단일 모달 대신 keeper 상세를 별도 화면으로 펼쳤습니다. 운영자가 자주 오가는 맥락 단위로 나눠서 바로 점프할 수 있습니다.
          </p>
        </div>

        <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-1">
          <${KeeperDetailQuickFact} label="상태">${effectiveStatus}<//>
          <${KeeperDetailQuickFact} label="컨텍스트">${contextRatioPct}<//>
          <${KeeperDetailQuickFact} label=${effectiveModelLabel}>${effectiveModel}<//>
          <${KeeperDetailQuickFact} label="최근 활동">
            <${KeeperActivityValue} activity=${activity} />
          <//>
        </div>

        <div class="rounded-2xl border border-[var(--white-8)] bg-[var(--color-bg-panel-alt)] p-3.5">
          <${SectionLabel}>빠른 이동</${SectionLabel}>
          <div class="mt-3 flex flex-col gap-2">
            ${KEEPER_DETAIL_SECTIONS.map((section) => html`
              <button
                type="button"
                class="rounded-2xl border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-left transition-colors hover:bg-[var(--white-6)]"
                onClick=${() => scrollToKeeperDetailSection(section.id)}
              >
                <div class="text-sm font-medium text-[var(--color-fg-primary)]">${section.label}</div>
                <div class="mt-1 text-2xs leading-relaxed text-[var(--color-fg-muted)]">${section.summary}</div>
              </button>
            `)}
          </div>
        </div>
      </div>
    </aside>
  `
}

export function KeeperDetailSection({
  id,
  eyebrow,
  title,
  description,
  children,
}: {
  id: KeeperDetailSectionId
  eyebrow: string
  title: string
  description: string
  children: ComponentChildren
}) {
  return html`
    <section
      id=${id}
      class="scroll-mt-24 rounded-[28px] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-2xl"
      aria-label=${title}
    >
      <div class="border-b border-[var(--white-8)] px-5 py-4 sm:px-6">
        <div class="text-3xs font-semibold uppercase tracking-[0.22em] text-[var(--color-fg-muted)]">${eyebrow}</div>
        <div class="mt-1 flex flex-col gap-1 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <h3 class="m-0 text-lg font-semibold text-[var(--color-fg-primary)]">${title}</h3>
            <p class="m-0 mt-1 text-sm leading-relaxed text-[var(--text-secondary)]">${description}</p>
          </div>
        </div>
      </div>
      <div class="flex flex-col gap-4 px-5 py-5 sm:px-6">
        ${children}
      </div>
    </section>
  `
}
