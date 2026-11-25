/**
 * Entity Tab 3: `Portrait & Candle` (`/keepers/:name/portrait-candle`)
 *
 * - Live `GET /api/v1/keepers/:k/portrait.png?size=256&preview=<item_id>` preview
 *   (single bare item ID matching `Keeper_portrait_item.of_id` + 5-key JSON object `expected_equipment`)
 * - 5-slot ornament wardrobe observer + try-on preview (`face`, `neck`, `head`, `hand`, `base`)
 * - Personal Candle balance & history (`/api/v1/candle/ledger?keeper=:k`, decimal-string `*_milli` per #36)
 * - Honest Keeper-autonomous economy surface: purchases/equipping are executed autonomously
 *   by the Keeper itself (server wallet policy forbids operator wallet spoofing).
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import { formatObserved } from '../../core/resource-cache'
import { EQUIPMENT_IDS, type KeeperEquipment } from '../../lib/keeper-portrait'
import { useAuthenticatedPortrait } from '../../lib/portrait-cache'
import { kSigil } from '../../components/keeper-badge'
import { DataTable, type DataTableColumn } from '../../components/primitives/data-table'
import {
  buildPortraitPreviewUrl,
  fetchKeeperCandleLedgerApi,
  fetchKeeperItemsApi,
  formatCandleMilli,
} from './keepers-api'
import type {
  CandleLedgerEventRow,
  KeeperCandleLedgerData,
  KeeperItemsData,
  KeeperRosterItem,
  PortraitSlot,
} from './types'

export interface KeeperPortraitCandleTabProps {
  readonly keeper: KeeperRosterItem
  readonly onMutated: () => void
}

const SLOTS: readonly PortraitSlot[] = ['face', 'neck', 'head', 'hand', 'base']

const DEFAULT_SLOT_ITEM: Readonly<Record<PortraitSlot, string>> = {
  face: 'bare_face',
  neck: 'bare_neck',
  head: 'bare_head',
  hand: 'empty_hand',
  base: 'no_dish',
}

export function KeeperPortraitCandleTab(props: KeeperPortraitCandleTabProps) {
  const { keeper } = props
  const [ledger, setLedger] = useState<KeeperCandleLedgerData | null>(null)
  const [items, setItems] = useState<KeeperItemsData | null>(null)
  const [previewItemId, setPreviewItemId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const loadAll = useCallback(async () => {
    setLoading(true)
    const [ledRes, itRes] = await Promise.all([
      fetchKeeperCandleLedgerApi(keeper.name, 100),
      fetchKeeperItemsApi(keeper.name),
    ])
    setLoading(false)
    if (ledRes.ok) setLedger(ledRes.value)
    if (itRes.ok) setItems(itRes.value)
  }, [keeper.name])

  useEffect(() => {
    setPreviewItemId(null)
    void loadAll()
  }, [loadAll])

  const ownedSet = useMemo(() => {
    const s = new Set<string>()
    if (items?.owned_items) for (const id of items.owned_items) s.add(id)
    if (ledger?.balance?.owned_items) for (const id of ledger.balance.owned_items) s.add(id)
    return s
  }, [items, ledger])

  const currentEquipped = useMemo<KeeperEquipment>(() => {
    const eq = ledger?.balance?.equipped ?? keeper.portrait_equipment
    return {
      face: (eq?.face ?? DEFAULT_SLOT_ITEM.face) as KeeperEquipment['face'],
      neck: (eq?.neck ?? DEFAULT_SLOT_ITEM.neck) as KeeperEquipment['neck'],
      head: (eq?.head ?? DEFAULT_SLOT_ITEM.head) as KeeperEquipment['head'],
      hand: (eq?.hand ?? DEFAULT_SLOT_ITEM.hand) as KeeperEquipment['hand'],
      base: (eq?.base ?? DEFAULT_SLOT_ITEM.base) as KeeperEquipment['base'],
    }
  }, [ledger, keeper.portrait_equipment])

  const portraitUrl = useMemo(
    () =>
      buildPortraitPreviewUrl(
        keeper.name,
        256,
        previewItemId,
        previewItemId === null ? keeper.portrait_equipment : null,
      ),
    [keeper.name, previewItemId, keeper.portrait_equipment],
  )
  const authenticatedPortraitSrc = useAuthenticatedPortrait(portraitUrl)
  const [failedSrc, setFailedSrc] = useState<string | null>(null)

  const eventColumns = useMemo<readonly DataTableColumn<CandleLedgerEventRow>[]>(() => [
    { id: 'seq', header: 'Seq', accessor: (r) => r.seq, numeric: true, sortable: true },
    { id: 'kind', header: 'Kind', accessor: (r) => r.kind, sortable: true },
    { id: 'summary', header: 'Detail', accessor: (r) => r.summary || '없음' },
    { id: 'at', header: 'Time', accessor: (r) => r.at_rfc3339 || String(r.at_unix) },
  ], [])

  const balanceDisplay = ledger?.balance
    ? formatObserved(formatCandleMilli(ledger.balance.balance_milli))
    : items?.balance_milli
      ? formatObserved(formatCandleMilli(items.balance_milli))
      : '없음'

  const decayedDisplay = ledger?.balance
    ? formatObserved(formatCandleMilli(ledger.balance.decayed_milli))
    : '없음'

  return html`
    <div class="kp-scroll-pane" data-keeper-tab="portrait-candle">
      <div class="kp-card-head">
        <h3>Portrait & Candle · ${keeper.name}</h3>
        <button type="button" class="btn-ghost" disabled=${loading} onClick=${() => void loadAll()}>
          새로고침
        </button>
      </div>

      <div class="kp-notice" data-tone="info" role="note">
        Candle 장신구 구매·장착은 Keeper 자율 턴 지갑 정책으로 실행됩니다. 여기서는 실시간 초상화 착용 미리보기(?preview)와 원장 상태를 관측합니다.
      </div>

      <div class="kp-grid-2">
        <!-- Portrait Live Preview + 5-Slot Wardrobe -->
        <section class="kp-card" aria-label="초상화 미리보기 및 5슬롯 장신구">
          <div class="kp-portrait-stage">
            ${authenticatedPortraitSrc !== null && failedSrc !== authenticatedPortraitSrc
              ? html`
                  <img
                    class="kp-portrait-preview"
                    src=${authenticatedPortraitSrc}
                    data-portrait-url=${portraitUrl}
                    alt=${`${keeper.name} portrait preview`}
                    onError=${() => setFailedSrc(authenticatedPortraitSrc)}
                  />
                `
              : html`
                  <div
                    class="kp-portrait-preview kp-hero-portrait-sigil"
                    data-portrait-url=${portraitUrl}
                    role="img"
                    aria-label=${`${keeper.name} portrait preview`}
                  >
                    ${kSigil(keeper.name)}
                  </div>
                `}
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone="brass">
                Balance: ${balanceDisplay} C
              </span>
              <span class="kp-pill">
                Decayed: ${decayedDisplay} C
              </span>
              ${previewItemId !== null && html`
                <span class="kp-pill" data-tone="info">Preview: ${previewItemId}</span>
                <button type="button" class="btn-ghost" onClick=${() => setPreviewItemId(null)}>
                  미리보기 초기화
                </button>
              `}
            </div>
          </div>

          <div class="kp-card-head">
            <h3>5-Slot Ornament Wardrobe (Try-On Preview)</h3>
          </div>
          ${SLOTS.map((slot) => {
            const slotItems = EQUIPMENT_IDS[slot]
            const equippedVal = currentEquipped[slot]
            const selectedPreview = previewItemId && (slotItems as readonly string[]).includes(previewItemId)
              ? previewItemId
              : equippedVal
            return html`
              <div key=${slot} class="kp-field-row">
                <div>
                  <div class="kp-roster-name">${slot}</div>
                  <div class="kp-roster-sub">착용 중: ${equippedVal}</div>
                </div>
                <select
                  class="kp-input"
                  aria-label=${`${slot} 슬롯 미리보기`}
                  value=${selectedPreview}
                  onChange=${(e: Event) => {
                    const val = (e.currentTarget as HTMLSelectElement).value
                    setPreviewItemId(val === DEFAULT_SLOT_ITEM[slot] || val === equippedVal ? null : val)
                  }}
                >
                  ${slotItems.map((id) => html`
                    <option key=${id} value=${id}>
                      ${id}${id === DEFAULT_SLOT_ITEM[slot] ? ' (기본)' : ownedSet.has(id) ? ' (보유)' : ' (미보유 · 미리보기)'}
                    </option>
                  `)}
                </select>
              </div>
            `
          })}
        </section>

        <!-- Candle Balance, Policy & Ornament Catalog -->
        <section class="kp-card" aria-label="Candle 상점 및 원장 정책">
          <div class="kp-card-head">
            <h3>Candle Economy & Catalog</h3>
            <span class="kp-pill" data-tone=${ledger?.policy_configuration === 'enabled' ? 'brass' : 'default'}>
              ${ledger?.policy_configuration ?? items?.status ?? 'off'}
            </span>
          </div>

          <div class="kp-grid-2">
            <div class="kp-kv-box">
              <span class="kp-kv-k">Pricing Mode</span>
              <span class="kp-kv-v">${ledger?.pricing_mode ?? '없음'}</span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Half-Life</span>
              <span class="kp-kv-v">${ledger?.half_life_hours != null ? `${ledger.half_life_hours}h` : '없음'}</span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Supply Circulating</span>
              <span class="kp-kv-v">
                ${ledger ? `${formatObserved(formatCandleMilli(ledger.supply.circulating_milli))} C` : '없음'}
              </span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Owned Ornaments</span>
              <span class="kp-kv-v">${ownedSet.size}</span>
            </div>
          </div>

          ${items && items.status === 'ready'
            ? html`
                <div class="kp-card-head">
                  <h3>Catalog (${items.catalog.length})</h3>
                </div>
                <div>
                  ${items.catalog.map((cat) => {
                    const owned = ownedSet.has(cat.id)
                    const priceText = cat.price_status === 'priced' && cat.price_milli
                      ? `${formatObserved(formatCandleMilli(cat.price_milli))} C`
                      : '가격 미정'
                    return html`
                      <div key=${cat.id} class="kp-field-row">
                        <div>
                          <div class="kp-roster-name">${cat.id}</div>
                          <div class="kp-roster-sub">${cat.slot} · ${priceText}</div>
                        </div>
                        <div class="kp-pill-row">
                          <button
                            type="button"
                            class="btn-ghost"
                            onClick=${() => setPreviewItemId(cat.id)}
                          >
                            미리보기
                          </button>
                          <span class="kp-pill" data-tone=${owned ? 'ok' : undefined}>
                            ${owned ? '보유' : 'Keeper 자율 구매'}
                          </span>
                        </div>
                      </div>
                    `
                  })}
                </div>
              `
            : html`
                <div class="kp-empty">
                  ${items?.status === 'disabled'
                    ? `Candle 상점 비활성: ${items.reason ?? 'disabled'}`
                    : 'Candle 상점이 꺼져 있습니다 (초상화 장신구 전용 보상 화폐).'}
                </div>
              `}
        </section>
      </div>

      <!-- Candle Personal History -->
      <section class="kp-card" aria-label="Candle 원장 이력">
        <div class="kp-card-head">
          <h3>Candle Ledger History (${ledger?.recent_events.length ?? 0})</h3>
        </div>
        <${DataTable}
          data=${ledger?.recent_events ?? []}
          columns=${eventColumns}
          getRowId=${(r: CandleLedgerEventRow) => String(r.seq)}
          maxHeight=${260}
          emptyLabel="Candle 원장 이벤트 없음"
          caption="Keeper Candle Ledger History"
        />
      </section>
    </div>
  `
}
