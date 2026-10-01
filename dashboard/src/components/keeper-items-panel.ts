import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchKeeperItems, type KeeperItemsReading } from '../api/keeper-items'
import { keeperEquipmentKey, type KeeperEquipment } from '../api/schemas/keeper-portrait'
import { KeeperPortrait } from './keeper-portrait'
import { KeeperBadge } from './keeper-badge'
import type { Keeper } from '../types'
import { executionWorkspaceRevision, keeperRosterObservationRevision, serverStatus } from '../store'
import { readCandleAccountRevision } from '../api/schemas/candle-observation'

type Reading =
  | { kind: 'loading'; identity: string }
  | { kind: 'loaded'; identity: string; value: KeeperItemsReading }
  | { kind: 'error'; identity: string; message: string }

type ItemSlot = keyof KeeperEquipment

const slotNames: Record<ItemSlot, string> = {
  face: '얼굴', neck: '목', head: '머리', hand: '손', base: '받침',
}

function candle(milli: string): string {
  const padded = milli.padStart(4, '0')
  return `${BigInt(padded.slice(0, -3)).toLocaleString('en-US')}.${padded.slice(-3)} Candle`
}

export function KeeperItemsPanel({ keeper }: { keeper: Keeper }) {
  const [revision, setRevision] = useState(0)
  const equipmentKey = keeper.portrait?.state === 'ready'
    ? keeperEquipmentKey(keeper.portrait.equipment) : null
  const rosterObservation = keeperRosterObservationRevision.value
  const accountRevision = readCandleAccountRevision(keeper.candle_account_revision)
  const revisionObserved = accountRevision !== undefined
  const workspaceRevision = executionWorkspaceRevision.value
  const project = serverStatus.value?.project ?? null
  const identity = JSON.stringify([workspaceRevision, project, keeper.name, equipmentKey, keeper.candle_balance_milli, accountRevision, revisionObserved, revision])
  const [reading, setReading] = useState<Reading>({ kind: 'loading', identity })

  useEffect(() => {
    setReading({ kind: 'loading', identity })
    if (!revisionObserved) return
    const controller = new AbortController()
    const currentAuthority = () => !controller.signal.aborted
      && executionWorkspaceRevision.value === workspaceRevision
      && (serverStatus.value?.project ?? null) === project
    fetchKeeperItems(keeper.name, controller.signal)
      .then(value => {
        if (!currentAuthority()) return
        if (value.account_revision !== accountRevision) {
          throw new Error('Item 계정 관측이 변경되었습니다. 다음 Keeper 관측에서 다시 읽습니다.')
        }
        setReading({ kind: 'loaded', identity, value })
      })
      .catch(error => {
        if (currentAuthority()) setReading({ kind: 'error', identity, message: error instanceof Error ? error.message : 'Item 계정을 읽지 못했습니다' })
      })
    return () => controller.abort()
  }, [identity])

  // Retry a settled failure only when another accepted roster observation arrives.
  // Reading state changes alone must neither spin nor abort a pending request.
  useEffect(() => {
    if (revisionObserved && reading.kind === 'error' && reading.identity === identity) {
      setRevision(value => value + 1)
    }
  }, [rosterObservation])

  const current = revisionObserved && reading.identity === identity ? reading : { kind: 'loading' as const, identity }
  const account = current.kind === 'loaded' && current.value.status === 'ready' ? current.value : null
  return html`
    <div class="flex flex-wrap items-center justify-between gap-3">
      <p class="m-0 text-xs text-[var(--color-fg-muted)]">Keeper가 직접 구매하고 착용한 결과를 보여 줍니다.</p>
      <button type="button" class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-3 py-1.5 text-xs text-[var(--color-fg-primary)] hover:bg-[var(--color-bg-hover)]" onClick=${() => setRevision(value => value + 1)}>새로고침</button>
    </div>
    ${!revisionObserved ? html`<p role="status">현재 Keeper의 Item 계정 관측을 확인하는 중…</p>`
      : current.kind === 'loading' ? html`<p role="status">Item 계정 불러오는 중…</p>` : null}
    ${current.kind === 'error' ? html`<p role="alert">Item 계정을 읽지 못했습니다: ${current.message}</p>` : null}
    ${current.kind === 'loaded' && current.value.status === 'off' ? html`<p role="status">Candle 기능이 꺼져 있습니다.</p>` : null}
    ${current.kind === 'loaded' && current.value.status === 'disabled' ? html`<p role="alert">Candle 설정을 사용할 수 없습니다: ${current.value.reason}</p>` : null}
    ${account ? html`
      <div class="flex flex-wrap items-center gap-5 rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-4">
        <${KeeperPortrait} name=${keeper.name} reading=${keeper.portrait ?? { state: 'unavailable', reason: '초상화 관측 없음' }} sizePx=${112} fallback=${html`<${KeeperBadge} id=${keeper.name} size="lg" variant="sigil" />`} />
        <div>
          <div class="text-xs text-[var(--color-fg-muted)]">현재 잔액</div>
          <div class="text-xl font-semibold tabular-nums text-[var(--color-fg-primary)]">${candle(account.balance_milli)}</div>
          <div class="mt-1 text-xs text-[var(--color-fg-muted)]">보유 ${account.owned_items.length} / ${account.catalog.length}개</div>
        </div>
      </div>
      <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
        ${(['face', 'neck', 'head', 'hand', 'base'] as ItemSlot[]).map(slot => html`
          <section class="rounded-[var(--r-2)] border border-[var(--color-border-default)] p-3" aria-label=${`${slotNames[slot]} 아이템`}>
            <h4 class="m-0 mb-2 text-sm font-semibold text-[var(--color-fg-primary)]">${slotNames[slot]}</h4>
            <ul class="m-0 list-none space-y-1 p-0">
              ${account.catalog.filter(item => item.slot === slot).map(item => {
                const owned = account.owned_items.includes(item.id)
                const equipped = keeper.portrait?.state === 'ready' && keeper.portrait.equipment[slot] === item.id
                return html`<li class="flex flex-wrap items-center justify-between gap-2 border-t border-[var(--color-border-divider)] py-2 text-xs">
                  <span class="font-mono text-[var(--color-fg-primary)]">${item.id}</span>
                  <span class="flex items-center gap-2 text-[var(--color-fg-muted)]">
                    ${equipped ? html`<span class="font-semibold text-[var(--color-accent-fg)]">착용 중</span>` : owned ? html`<span>보유</span>` : null}
                    <span class="tabular-nums">${item.price_status === 'unpriced' ? '가격 미설정' : candle(item.price_milli)}</span>
                  </span>
                </li>`
              })}
            </ul>
          </section>
        `)}
      </div>
    ` : null}
  `
}
