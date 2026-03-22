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
import { ActionButton, ButtonGroup } from './common/button'
import { StatusDot } from './common/badge'
import { StatRow, StatGrid } from './common/stat-row'
import { SectionHeader } from './common/section-header'

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return 'dev'
  return value.length > 10 ? value.slice(0, 10) : value
}

export function SnapshotCard({ currentTab }: { currentTab: string }) {
  const liveConnected = connected.value
  const build = serverStatus.value?.build

  return html`
    <section class="grid gap-2.5">
      <!-- Connection + Version row -->
      <div class="flex items-center justify-between gap-2">
        <${StatusDot} status=${liveConnected ? 'online' : 'offline'} label=${liveConnected ? '연결됨' : '오프라인'} />
        ${build
          ? html`<span class="text-[10px] text-[var(--text-muted)] tabular-nums">v${build.release_version} · ${shortCommit(build.commit)}</span>`
          : null}
      </div>

      <!-- Compact stat rows -->
      <${StatGrid}>
        <${StatRow} label="에이전트"><span class="text-[var(--accent)]">${agents.value.length}</span><//>
        <${StatRow} label="키퍼"><span class="text-[var(--ok)]">${keepers.value.length}</span><//>
        <${StatRow} label="태스크"><span class="text-[var(--warn)]">${tasks.value.length}</span><//>
        <${StatRow} label="이벤트">${eventCount.value}<//>
      <//>

      <!-- Actions -->
      <${ButtonGroup}>
        <${ActionButton} variant="primary" block onClick=${() => {
          refreshDashboard()
          refreshForTab(currentTab)
        }}>새로고침<//>
        <${ActionButton} variant="ghost" block onClick=${() => navigate('operations', { section: 'intervene' })}>운영 패널<//>
      <//>
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
      <${SectionHeader} size="sm" class="mb-2" right=${html`<span class="text-[10px] ${pendingConfirms > 0 ? 'text-[var(--warn)]' : 'text-[#86efac]'}">${pendingConfirms > 0 ? `대기 ${pendingConfirms}건` : '정상'}</span>`}>개입<//>
      <${StatGrid} cols=${3} class="mb-2.5">
        <${StatRow} label="대기">${pendingConfirms}<//>
        <${StatRow} label="세션">${sessionCount}<//>
        <${StatRow} label="키퍼">${keeperCount}<//>
      <//>
      <${ButtonGroup}>
        <${ActionButton} variant="primary" block onClick=${() => {
          refreshOperatorSnapshot()
          refreshOperatorRoomDigest()
        }}>갱신<//>
        <${ActionButton} variant="ghost" block onClick=${() => navigate('operations', { section: 'intervene' })}>운영 패널<//>
      <//>
    </section>
  `
}
