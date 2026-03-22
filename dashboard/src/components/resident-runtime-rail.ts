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
  if (!value) return '커밋 정보 없음'
  return value.length > 10 ? value.slice(0, 10) : value
}

export function SnapshotCard({ currentTab }: { currentTab: string }) {
  const liveConnected = connected.value
  const build = serverStatus.value?.build

  return html`
    <section class="rail-card rounded-xl">
      <div class="flex items-center justify-between gap-3">
        <h3 class="mb-0">현황</h3>
        <span class="rail-section-chip rounded-full ${liveConnected ? 'ok' : 'bad'}">${liveConnected ? '연결됨' : '오프라인'}</span>
      </div>
      <div class="grid grid-cols-2 gap-2">
        <div class="border border-[var(--border-slate-16)] rounded-[10px] py-2.5 px-[11px] bg-[var(--white-3)] grid gap-1">
          <span class="text-[color:var(--text-muted)] text-[11px] tracking-[0.06em] uppercase">에이전트</span>
          <strong class="text-[color:var(--text-strong)] text-lg leading-[1.1]">${agents.value.length}</strong>
        </div>
        <div class="border border-[var(--border-slate-16)] rounded-[10px] py-2.5 px-[11px] bg-[var(--white-3)] grid gap-1">
          <span class="text-[color:var(--text-muted)] text-[11px] tracking-[0.06em] uppercase">키퍼</span>
          <strong class="text-[color:var(--text-strong)] text-lg leading-[1.1]">${keepers.value.length}</strong>
        </div>
        <div class="border border-[var(--border-slate-16)] rounded-[10px] py-2.5 px-[11px] bg-[var(--white-3)] grid gap-1">
          <span class="text-[color:var(--text-muted)] text-[11px] tracking-[0.06em] uppercase">태스크</span>
          <strong class="text-[color:var(--text-strong)] text-lg leading-[1.1]">${tasks.value.length}</strong>
        </div>
        <div class="border border-[var(--border-slate-16)] rounded-[10px] py-2.5 px-[11px] bg-[var(--white-3)] grid gap-1">
          <span class="text-[color:var(--text-muted)] text-[11px] tracking-[0.06em] uppercase">이벤트</span>
          <strong class="text-[color:var(--text-strong)] text-lg leading-[1.1]">${eventCount.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions mt-3 grid grid-cols-2 gap-2">
        <button
          class="rail-refresh-btn"
          onClick=${() => {
            refreshDashboard()
            refreshForTab(currentTab)
          }}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn w-full border border-[var(--card-border)] rounded-[10px] py-[9px] px-[11px] bg-[var(--white-4)] text-[color:var(--text-body)] text-xs cursor-pointer" onClick=${() => navigate('operations', { section: 'intervene' })}>
          운영 패널 열기
        </button>
      </div>
      ${build
        ? html`<div class="mt-2.5 text-xs text-[color:var(--text-muted)]">서버 빌드 · v${build.release_version} · ${shortCommit(build.commit)}</div>`
        : null}
    </section>
  `
}

export function InterveneRailCard() {
  const snapshot = operatorSnapshot.value
  const pendingConfirms = selectPendingConfirmState(snapshot).total_count
  const sessionCount = snapshot?.sessions.length ?? 0
  const keeperCount = snapshot?.keepers.length ?? 0

  return html`
    <section class="rail-card rounded-xl">
      <div class="flex items-center justify-between gap-3">
        <h3 class="mb-0">개입 바로가기</h3>
        <span class="rail-section-chip rounded-full ${pendingConfirms > 0 ? 'warn' : 'ok'}">${pendingConfirms > 0 ? '확인 필요' : '정상'}</span>
      </div>
      <div class="grid grid-cols-2 gap-2">
        <div class="border border-[var(--border-slate-16)] rounded-[10px] py-2.5 px-[11px] bg-[var(--white-3)] grid gap-1">
          <span class="text-[color:var(--text-muted)] text-[11px] tracking-[0.06em] uppercase">확인 대기</span>
          <strong class="text-[color:var(--text-strong)] text-lg leading-[1.1]">${pendingConfirms}</strong>
        </div>
        <div class="border border-[var(--border-slate-16)] rounded-[10px] py-2.5 px-[11px] bg-[var(--white-3)] grid gap-1">
          <span class="text-[color:var(--text-muted)] text-[11px] tracking-[0.06em] uppercase">Session</span>
          <strong class="text-[color:var(--text-strong)] text-lg leading-[1.1]">${sessionCount}</strong>
        </div>
        <div class="border border-[var(--border-slate-16)] rounded-[10px] py-2.5 px-[11px] bg-[var(--white-3)] grid gap-1">
          <span class="text-[color:var(--text-muted)] text-[11px] tracking-[0.06em] uppercase">키퍼</span>
          <strong class="text-[color:var(--text-strong)] text-lg leading-[1.1]">${keeperCount}</strong>
        </div>
      </div>
      <div class="rail-inline-actions mt-3 grid grid-cols-2 gap-2">
        <button
          class="rail-refresh-btn"
          onClick=${() => {
            refreshOperatorSnapshot()
            refreshOperatorRoomDigest()
          }}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn w-full border border-[var(--card-border)] rounded-[10px] py-[9px] px-[11px] bg-[var(--white-4)] text-[color:var(--text-body)] text-xs cursor-pointer" onClick=${() => navigate('operations', { section: 'intervene' })}>
          운영 패널 열기
        </button>
      </div>
    </section>
  `
}
