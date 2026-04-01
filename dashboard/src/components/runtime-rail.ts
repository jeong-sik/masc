import { html } from 'htm/preact'
import { navigate } from '../router'
import { operatorSnapshot, refreshOperatorRoomDigest, refreshOperatorSnapshot } from '../operator-store'
import { selectPendingConfirmState } from '../pending-confirm'

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
