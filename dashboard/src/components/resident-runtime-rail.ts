import { html } from 'htm/preact'
import { connected, eventCount } from '../sse'
import {
  refreshDashboard,
  agents,
  tasks,
  keepers,
  serverStatus,
} from '../store'
import { refreshForTab } from '../tab-refresh'
import { navigate } from '../router'
import { operatorSnapshot, refreshOperatorRoomDigest, refreshOperatorSnapshot } from '../operator-store'
import { selectPendingConfirmState } from '../pending-confirm'

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return 'dev'
  return value.length > 10 ? value.slice(0, 10) : value
}

export function SnapshotCard({ currentTab }: { currentTab: string }) {
  const liveConnected = connected.value
  const build = serverStatus.value?.build

  return html`
    <section class="grid gap-2.5 rounded-lg border border-[rgba(255,255,255,0.06)] bg-[linear-gradient(180deg,rgba(255,255,255,0.045),rgba(255,255,255,0.02))] p-3">
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-[10px] font-semibold uppercase tracking-[0.18em] text-[rgba(154,217,255,0.68)]">Room Pulse</div>
          <div class="mt-1 text-[15px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">
            ${liveConnected ? 'Live control room' : 'Signal recovering'}
          </div>
        </div>
        <div class="flex items-center gap-1.5">
          <span class="size-[8px] rounded-full inline-block ${liveConnected ? 'bg-[var(--ok)] shadow-[0_0_9px_rgba(74,222,128,0.64)]' : 'bg-[var(--bad)] shadow-[0_0_9px_rgba(239,68,68,0.42)]'}"></span>
          <span class="text-[10px] font-medium ${liveConnected ? 'text-[#92f3b4]' : 'text-[#ffb4bf]'}">${liveConnected ? 'connected' : 'offline'}</span>
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
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--accent)]">${agents.value.length}</strong>
        </div>
        <div class="rounded-md border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">키퍼</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--ok)]">${keepers.value.length}</strong>
        </div>
        <div class="rounded-md border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">태스크</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--warn)]">${tasks.value.length}</strong>
        </div>
        <div class="rounded-md border border-[rgba(255,255,255,0.05)] bg-[rgba(255,255,255,0.03)] px-3 py-2">
          <div class="text-[10px] text-[var(--text-muted)]">이벤트</div>
          <strong class="mt-1 block text-[18px] font-semibold tabular-nums text-[var(--text-strong)]">${eventCount.value}</strong>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-2">
        <button
          class="w-full rounded-md border border-solid border-[rgba(71,184,255,0.26)] bg-[rgba(71,184,255,0.14)] px-3 py-2 text-[11px] font-medium text-[#dff3ff] cursor-pointer transition-colors duration-150 hover:bg-[rgba(71,184,255,0.2)]"
          onClick=${() => {
            refreshDashboard()
            refreshForTab(currentTab)
          }}
        >
          Room sync
        </button>
        <button
          class="w-full rounded-md border border-solid border-[var(--card-border)] px-3 py-2 bg-[rgba(255,255,255,0.04)] text-[var(--text-body)] text-[11px] font-medium cursor-pointer transition-colors duration-150 hover:bg-[rgba(255,255,255,0.08)]"
          onClick=${() => navigate('operations', { section: 'intervene' })}
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
        <button
          class="w-full border border-solid border-[rgba(71,184,255,0.3)] rounded-lg bg-[var(--accent-12)] text-[#d7efff] py-1.5 px-2 text-[11px] cursor-pointer transition-colors duration-150 hover:bg-[var(--accent-20)]"
          onClick=${() => {
            refreshOperatorSnapshot()
            refreshOperatorRoomDigest()
          }}
        >
          갱신
        </button>
        <button
          class="w-full border border-solid border-[var(--card-border)] rounded-lg py-1.5 px-2 bg-[var(--white-4)] text-[var(--text-body)] text-[11px] cursor-pointer transition-colors duration-150 hover:bg-[var(--white-8)]"
          onClick=${() => navigate('operations', { section: 'intervene' })}
        >
          운영 패널
        </button>
      </div>
    </section>
  `
}
