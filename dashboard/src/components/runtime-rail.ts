import { html } from 'htm/preact'
import { connected, eventCount } from '../sse'
import {
  refreshDashboard,
  agents,
  tasks,
  keepers,
  shellCounts,
  serverStatus,
  executionLoaded,
  executionLoading,
  executionError,
} from '../store'
import { refreshForRoute } from '../tab-refresh'
import { navigate, route } from '../router'
import { operatorSnapshot, refreshOperatorRoomDigest, refreshOperatorSnapshot } from '../operator-store'
import { selectPendingConfirmState } from '../pending-confirm'
import { missionKeeperBriefs } from '../mission-signals'
import { roomTruth } from '../room-truth-store'
import { resolveRuntimeCounts, runtimeCountSourceLabel } from '../runtime-counts'
import { countRuntimeKinds } from './agent-roster'

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return 'dev'
  return value.length > 10 ? value.slice(0, 10) : value
}

export function SnapshotCard() {
  const liveConnected = connected.value
  const build = serverStatus.value?.build
  const liveRuntimeCounts = countRuntimeKinds(agents.value, keepers.value, missionKeeperBriefs.value)
  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: executionLoaded.value,
    agentsCount: liveRuntimeCounts.agents,
    keepersCount: liveRuntimeCounts.keepers,
    tasksCount: tasks.value.length,
    roomTruthCounts: roomTruth.value?.room.counts,
    shellCounts: shellCounts.value,
  })
  const countSourceLabel = runtimeCountSourceLabel(runtimeCounts.source)
  const countStateMessage =
    executionError.value
      ? `execution 상세 실패 · ${countSourceLabel} 카운트 표시 중`
      : runtimeCounts.source !== 'execution'
        ? `${executionLoading.value || !executionLoaded.value ? '상세 runtime 동기화 중' : '상세 runtime 불일치'} · ${countSourceLabel} 카운트 표시 중`
        : null

  return html`
    <section class="grid gap-2 rounded-lg border border-[rgba(255,255,255,0.06)] bg-[linear-gradient(180deg,rgba(255,255,255,0.045),rgba(255,255,255,0.02))] p-2.5">
      <div>
        <div class="text-[10px] font-semibold uppercase tracking-[0.18em] text-[rgba(154,217,255,0.68)]">룸 펄스</div>
        <div class="mt-0.5 text-[13px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">
          ${liveConnected ? '라이브 관제실' : '신호 복구 중'}
        </div>
      </div>

      ${build
        ? html`
            <div class="rounded-md border border-[rgba(71,184,255,0.14)] bg-[rgba(71,184,255,0.08)] px-3 py-2 text-[10px] text-[rgba(191,231,255,0.78)]">
              build v${build.release_version} · ${shortCommit(build.commit)}
            </div>
          `
        : null}

      <div class="grid grid-cols-2 gap-2 text-[11px]">
        <div class="rounded-md border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">에이전트</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--accent)]">${runtimeCounts.agents}</strong>
        </div>
        <div class="rounded-md border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">키퍼</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--ok)]">${runtimeCounts.keepers}</strong>
        </div>
        <div class="rounded-md border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">태스크</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums ${runtimeCounts.tasks > 0 ? 'text-[var(--warn)]' : 'text-[var(--text-muted)]'}">${runtimeCounts.tasks}</strong>
        </div>
        <div class="rounded-md border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">이벤트</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--text-strong)]">${eventCount.value}</strong>
        </div>
      </div>

      ${countStateMessage
        ? html`
            <div class="rounded-md border border-[rgba(71,184,255,0.16)] bg-[rgba(71,184,255,0.08)] px-3 py-2 text-[10px] leading-[1.45] text-[rgba(191,231,255,0.78)]">
              ${countStateMessage}
            </div>
          `
        : null}

      <div class="grid grid-cols-2 gap-2">
        <button type="button"
          class="w-full rounded-md border border-solid border-[rgba(71,184,255,0.26)] bg-[rgba(71,184,255,0.14)] px-3 py-2 text-[11px] font-medium text-[#dff3ff] cursor-pointer transition-colors duration-150 hover:bg-[rgba(71,184,255,0.2)]"
          onClick=${(e: Event) => {
            e.preventDefault()
            void refreshDashboard({ force: true }).catch(() => {})
            refreshForRoute(route.value)
          }}
        >
          Room sync
        </button>
        <button type="button"
          class="w-full rounded-md border border-solid border-[var(--card-border)] px-3 py-2 bg-[rgba(255,255,255,0.04)] text-[var(--text-body)] text-[11px] font-medium cursor-pointer transition-colors duration-150 hover:bg-[rgba(255,255,255,0.08)]"
          onClick=${() => navigate('command', { section: 'intervene' })}
        >
          운영 패널
        </button>
      </div>
    </section>
  `
}

export function InterveneRailCard() {
  const snapshot = operatorSnapshot.value
  const pendingConfirms = selectPendingConfirmState(snapshot).total_count
  const sessionCount = snapshot?.sessions.length ?? 0
  const keeperCount = snapshot?.keepers.length ?? 0

  return html`
    <section class="border border-solid border-[var(--card-border)] rounded-xl bg-[var(--card)] p-3">
      <div class="flex items-center justify-between gap-2 mb-2">
        <h3 class="text-[var(--text-strong)] text-[11px] uppercase tracking-[0.08em] font-medium">개입</h3>
        <span class="text-[10px] ${pendingConfirms > 0 ? 'text-[var(--warn)]' : 'text-[#86efac]'}">${pendingConfirms > 0 ? `대기 ${pendingConfirms}건` : '정상'}</span>
      </div>
      <div class="grid grid-cols-3 gap-x-3 gap-y-1 text-[11px] mb-2.5">
        <div class="flex items-center justify-between">
          <span class="text-[var(--text-muted)]">대기</span>
          <strong class="text-[var(--text-strong)] tabular-nums">${pendingConfirms}</strong>
        </div>
        <div class="flex items-center justify-between">
          <span class="text-[var(--text-muted)]">세션</span>
          <strong class="text-[var(--text-strong)] tabular-nums">${sessionCount}</strong>
        </div>
        <div class="flex items-center justify-between">
          <span class="text-[var(--text-muted)]">키퍼</span>
          <strong class="text-[var(--text-strong)] tabular-nums">${keeperCount}</strong>
        </div>
      </div>
      <div class="grid grid-cols-2 gap-1.5">
        <button type="button"
          class="w-full border border-solid border-[rgba(71,184,255,0.3)] rounded-lg bg-[var(--accent-12)] text-[#d7efff] py-1.5 px-2 text-[11px] cursor-pointer transition-colors duration-150 hover:bg-[var(--accent-20)]"
          onClick=${() => {
            void refreshOperatorSnapshot({ force: true })
            void refreshOperatorRoomDigest({ force: true })
          }}
        >
          갱신
        </button>
        <button type="button"
          class="w-full border border-solid border-[var(--card-border)] rounded-lg py-1.5 px-2 bg-[var(--white-4)] text-[var(--text-body)] text-[11px] cursor-pointer transition-colors duration-150 hover:bg-[var(--white-8)]"
          onClick=${() => navigate('command', { section: 'intervene' })}
        >
          운영 패널
        </button>
      </div>
    </section>
  `
}
