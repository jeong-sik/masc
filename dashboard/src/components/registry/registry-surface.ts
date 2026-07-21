import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

import type { Keeper } from '../../types'
import { route } from '../../router'
import {
  buildCompositeByKeeperKey,
  fleetCompositeSnapshot,
} from '../../composite-signals'
import { compositeSnapshotForKeeper } from '../../lib/keeper-composite-lookup'
import {
  deriveKeeperOperationalState,
  type KeeperOperationalState,
} from '../../lib/keeper-operational-state'
import { keeperDisplayRuntime } from '../../lib/keeper-runtime-display'
import { keepers } from '../../store'
import { KeeperDetailPage } from '../keeper-detail-page'
import { openKeeperDetail } from '../keeper-detail-state'
import { PersonaBrowser } from '../keeper-spawn/persona-browser'
import { KeeperBadge } from '../keeper-badge'
import { Dot, Pill, type DotState, type PillTone } from '../v2/primitives-v2'

export type RegistryKeeperGroupId = KeeperOperationalState['kind']

interface RegistryKeeperRow {
  readonly keeper: Keeper
  readonly state: KeeperOperationalState
}

interface RegistryKeeperGroup {
  readonly id: RegistryKeeperGroupId
  readonly label: string
  readonly dot: DotState
  readonly tone: PillTone
}

const KEEPER_GROUPS: Readonly<Record<RegistryKeeperGroupId, RegistryKeeperGroup>> = {
  running: { id: 'running', label: '실행 중', dot: 'ok', tone: 'ok' },
  stuck: { id: 'stuck', label: '차단 · 확인 필요', dot: 'bad', tone: 'bad' },
  paused: { id: 'paused', label: '일시정지', dot: 'warn', tone: 'warn' },
  offline: { id: 'offline', label: '중지 · 미기동', dot: 'idle', tone: 'neutral' },
}

export function keeperGroup(
  keeper: Keeper,
  composite: Parameters<typeof deriveKeeperOperationalState>[0]['composite'],
): RegistryKeeperGroupId {
  return deriveKeeperOperationalState({ keeper, composite }).kind
}

export function groupRegistryKeepers(
  roster: readonly Keeper[],
  compositeByKeeperKey: ReturnType<typeof buildCompositeByKeeperKey>,
): Readonly<Record<RegistryKeeperGroupId, readonly RegistryKeeperRow[]>> {
  const rows = roster.map(keeper => ({
    keeper,
    state: deriveKeeperOperationalState({
      keeper,
      composite: compositeSnapshotForKeeper(keeper, compositeByKeeperKey),
    }),
  }))

  return {
    running: rows.filter(row => row.state.kind === 'running'),
    stuck: rows.filter(row => row.state.kind === 'stuck'),
    paused: rows.filter(row => row.state.kind === 'paused'),
    offline: rows.filter(row => row.state.kind === 'offline'),
  }
}

function runtimeLabel(keeper: Keeper): string | null {
  return keeperDisplayRuntime(keeper)?.value ?? null
}

function configuredOnly(state: KeeperOperationalState): boolean {
  return state.kind === 'offline' && state.cause === 'unbooted'
}

/**
 * Persona layer. Create/edit/delete and keeper spawn all live in
 * [PersonaBrowser], which owns its own load, permission gating, and confirm
 * dialogs. Registry mounts it rather than re-listing personas read-only: two
 * surfaces for the same records is what split persona writes away from this
 * route in the first place.
 */
function PersonaLayer() {
  return html`
    <div class="reg-layer reg-personas">
      <h3 style="margin:0 0 8px;">Persona</h3>
      <p style="margin:0 0 12px;opacity:.7;font-size:12px;">
        페르소나를 만들고 편집합니다. <strong>키퍼 시작</strong>은 그 페르소나의 기본 지시사항으로
        키퍼를 생성하고 곧바로 부팅합니다 — 설정만 해두는 경로는 아직 없습니다.
        목표는 생성 후 키퍼 상세에서 연결합니다.
      </p>
      <${PersonaBrowser} />
    </div>
  `
}

export function RegistrySurface() {
  // Keeper update/delete are not reimplemented here. The row opens the existing
  // keeper detail route, which already hosts the config panel (write) and the
  // purge flow (delete). `baseAgentDirectoryRoute` keeps 'registry' as the
  // return tab, so the drill-down does not bounce the operator to Monitoring.
  const keeperParam = route.value.params.keeper as string | undefined

  const roster = keepers.value
  const fleetSnapshot = fleetCompositeSnapshot.value
  const compositeByKeeperKey = useMemo(
    () => buildCompositeByKeeperKey(fleetSnapshot),
    [fleetSnapshot],
  )
  const grouped = useMemo(
    () => groupRegistryKeepers(roster, compositeByKeeperKey),
    [roster, compositeByKeeperKey],
  )

  if (keeperParam) {
    return html`<${KeeperDetailPage} />`
  }

  return html`
    <section class="reg-surface" style="padding:16px;display:flex;flex-direction:column;gap:20px;">
      <${PersonaLayer} />

      <div class="reg-layer reg-keepers">
        <h3 style="margin:0 0 8px;">Keeper <${Pill} tone="info">${roster.length}<//></h3>
        ${Object.values(KEEPER_GROUPS).map(group => html`
          <div key=${group.id} class="reg-kgroup" style="margin-bottom:12px;">
            <h4 style="margin:0 0 6px;display:flex;align-items:center;gap:6px;">
              <${Dot} state=${group.dot} /> ${group.label}
              <${Pill} tone=${group.tone} count>${grouped[group.id].length}<//>
            </h4>
            ${grouped[group.id].length === 0
              ? html`<p style="margin:0;opacity:.5;">없음</p>`
              : html`
                  <ul style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:4px;">
                    ${grouped[group.id].map(row => {
                      const runtime = runtimeLabel(row.keeper)
                      return html`
                        <li key=${row.keeper.name} class="reg-keeper-row">
                          <button
                            type="button"
                            class="reg-keeper-open"
                            data-testid="registry-keeper-open"
                            title="${row.keeper.name} 상세 · 설정 편집 · 삭제"
                            onClick=${() => openKeeperDetail(row.keeper)}
                            style="display:flex;align-items:center;gap:8px;width:100%;padding:4px;
                                   background:none;border:0;cursor:pointer;text-align:left;color:inherit;"
                          >
                            <${KeeperBadge} id=${row.keeper.name} variant="full" size="sm" />
                            <span style="opacity:.7;font-size:12px;">
                              ${runtime ?? '런타임 없음'}
                            </span>
                            ${configuredOnly(row.state) ? html`<${Pill} tone="neutral">configured<//>` : null}
                          </button>
                        </li>
                      `
                    })}
                  </ul>
                `}
          </div>
        `)}
      </div>
    </section>
  `
}
