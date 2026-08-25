// MASC v2 — Registry surface (design: registry.jsx RegistrySurface).
// Rebuilt onto the design's `.reg-*`/`.rk-*`/`.rp-*` vocabulary so the vendored
// keeper-v2/registry.css skin has markup to land on.
//
// What is intentionally NOT built here (mark-don't-fake — no live signal):
// - Persona (AGENT.md) library panel + editor (`reg-persona`, `rp-desc`,
//   `rp-traits`, `reg-input`, ...): the backend exposes no prompt-file roster —
//   `/api/v1/prompts` lists system prompt keys, not keeper AGENT.md files.
// - Keeper create wizard (`reg-wizard`, `rw-*`): no keeper-create API exists in
//   api/keeper-lifecycle.ts (boot/shutdown/reset/clear/pause/resume/wake/purge).
// - `rk-tps` tok/s badge: tok/s only exists as per-keeper detail telemetry
//   (KeeperMetricPoint.wall_tokens_per_second), not as a roster-level signal.
// - `reg-cols`: the design's two-column grid exists to lay the persona panel
//   next to the keeper panel; with one panel it would leave an empty track.
//
// Update/delete are not reimplemented: the menu's "keeper 설정" opens the
// existing keeper detail route (config panel write path), and "등록 해제"
// opens RegistryDeregister (drain + purge against the real control plane).

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import type { Keeper } from '../../types'
import { navigate, route } from '../../router'
import {
  buildCompositeByKeeperKey,
  fleetCompositeSnapshot,
} from '../../composite-signals'
import { compositeSnapshotForKeeper } from '../../lib/keeper-composite-lookup'
import {
  deriveKeeperOperationalState,
  KEEPER_STATUS_LABEL_KO,
  type KeeperOperationalState,
} from '../../lib/keeper-operational-state'
import { keeperDisplayRuntime } from '../../lib/keeper-runtime-display'
import { keepers } from '../../store'
import { KeeperDetailPage } from '../keeper-detail-page'
import { openKeeperDetail } from '../keeper-detail-state'
import { KeeperBadge } from '../keeper-badge'
import { Dot, Pill, type DotState, type PillTone } from '../v2/primitives-v2'
import { RegistryDeregister } from './registry-deregister'

export type RegistryKeeperGroupId = KeeperOperationalState['kind']

interface RegistryKeeperRow {
  readonly keeper: Keeper
  readonly state: KeeperOperationalState
}

interface RegistryKeeperGroup {
  readonly id: RegistryKeeperGroupId
  readonly label: string
  /** `.reg-kgroup` modifier for the group header dot (keeper-v2/registry.css). */
  readonly cls: string
  readonly dot: DotState
  readonly tone: PillTone
}

// Group labels come from the canonical KEEPER_STATUS_LABEL_KO SSOT so the
// registry groups read identically to the monitoring band chip and the
// keeper-workspace roster groups. The design has three groups (run/pause/off);
// the dashboard's canonical model adds `stuck`, whose dot rule is a recorded
// live-only addition in keeper-v2/registry.css.
const KEEPER_GROUPS: Readonly<Record<RegistryKeeperGroupId, RegistryKeeperGroup>> = {
  running: { id: 'running', label: KEEPER_STATUS_LABEL_KO.running, cls: 'run', dot: 'ok', tone: 'ok' },
  stuck: { id: 'stuck', label: KEEPER_STATUS_LABEL_KO.stuck, cls: 'stuck', dot: 'bad', tone: 'bad' },
  paused: { id: 'paused', label: KEEPER_STATUS_LABEL_KO.paused, cls: 'pause', dot: 'warn', tone: 'warn' },
  offline: { id: 'offline', label: KEEPER_STATUS_LABEL_KO.offline, cls: 'off', dot: 'idle', tone: 'neutral' },
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

export function RegistrySurface() {
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

  const [menu, setMenu] = useState<string | null>(null)
  const [deregister, setDeregister] = useState<RegistryKeeperRow | null>(null)

  useEffect(() => {
    if (!menu) return
    const close = () => setMenu(null)
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setMenu(null)
    }
    window.addEventListener('click', close)
    window.addEventListener('keydown', onKey)
    return () => {
      window.removeEventListener('click', close)
      window.removeEventListener('keydown', onKey)
    }
  }, [menu])

  if (keeperParam) {
    return html`<${KeeperDetailPage} />`
  }

  return html`
    <main class="reg">
      <div class="reg-scroll">
        <header class="reg-head">
          <div>
            <span class="reg-eyebrow">레지스트리</span>
            <h1>프롬프트 · Keeper · 런타임</h1>
            <p class="reg-sub">AGENT.md 를 골라 keeper 를 만들고, 런타임에 바인딩합니다.</p>
          </div>
        </header>

        <div class="reg-spine">
          <div class="reg-station idea">
            <div class="rs-tag"><span class="rs-node"></span>AGENT.md</div>
            <div class="rs-name">프롬프트 파일</div>
            <div class="rs-gloss">keeper 프롬프트 전체가 담긴 한 장. 여러 keeper 가 공유할 수 있다.</div>
          </div>
          <div class="reg-arrow">→</div>
          <div class="reg-station actual">
            <div class="rs-tag"><span class="rs-node"></span>KEEPER</div>
            <div class="rs-name">Keeper</div>
            <div class="rs-gloss">파일을 참조하는 실제 에이전트. TOML 은 운영 설정만.</div>
          </div>
          <div class="reg-arrow">→</div>
          <div class="reg-station runtime">
            <div class="rs-tag"><span class="rs-node"></span>RUNTIME</div>
            <div class="rs-name">런타임</div>
            <div class="rs-gloss">keeper가 도는 모델·파이버. 언제든 교체.</div>
          </div>
        </div>

        <section class="reg-panel actual">
          <div class="reg-panel-h">
            <span class="rp-layer"></span>
            <h2>Keeper</h2>
            <span class="rp-kr">에이전트</span>
            <span class="rp-count">${roster.length}</span>
            <span class="rp-spacer"></span>
          </div>
          <div class="reg-keepers">
            ${Object.values(KEEPER_GROUPS).map(group => {
              const rows = grouped[group.id]
              if (!rows.length) return null
              return html`
                <div key=${group.id}>
                  <div class=${`reg-kgroup ${group.cls}`}>
                    <span class="rg-dot"></span>${group.label}<span class="rg-n">${rows.length}</span>
                  </div>
                  <div class="reg-kgrid">
                    ${rows.map(row => {
                      const { keeper, state } = row
                      const runtime = runtimeLabel(keeper)
                      return html`
                        <div
                          key=${keeper.name}
                          class=${`reg-keeper ${state.kind === 'offline' ? 'is-off' : ''}`}
                        >
                          <div class="rk-top">
                            <${KeeperBadge} id=${keeper.name} size="lg" />
                            <div class="rk-id">
                              <div class="rk-name">${keeper.name}</div>
                              <div class="rk-phase">
                                <${Dot} state=${group.dot} />${group.label}
                                ${configuredOnly(state) ? html`<${Pill} tone="neutral">configured<//>` : null}
                              </div>
                            </div>
                            <button
                              type="button"
                              class="rk-menu-btn"
                              data-testid="registry-keeper-menu"
                              title="명령"
                              onClick=${(e: Event) => {
                                e.stopPropagation()
                                setMenu(menu === keeper.name ? null : keeper.name)
                              }}
                            >⋯</button>
                            ${menu === keeper.name
                              ? html`
                                  <div class="rk-menu" onClick=${(e: Event) => e.stopPropagation()}>
                                    <button
                                      class="rk-menu-i"
                                      data-testid="registry-keeper-open"
                                      onClick=${() => {
                                        openKeeperDetail(keeper)
                                        setMenu(null)
                                      }}
                                    ><span class="g">⚙</span> keeper 설정</button>
                                    <button
                                      class="rk-menu-i"
                                      data-testid="registry-keeper-chat"
                                      onClick=${() => {
                                        navigate('keepers', { keeper: keeper.name })
                                        setMenu(null)
                                      }}
                                    ><span class="g">◈</span> 대화 열기</button>
                                    <div class="rk-menu-sep"></div>
                                    <button
                                      class="rk-menu-i danger"
                                      data-testid="registry-keeper-deregister"
                                      onClick=${() => {
                                        setDeregister(row)
                                        setMenu(null)
                                      }}
                                    ><span class="g">⊘</span> 등록 해제</button>
                                  </div>
                                `
                              : null}
                          </div>
                          <div class="rk-facet prov" title="참조하는 프롬프트 파일">
                            <span class="rk-f-lyr"></span>
                            <span class="rk-f-arrow">←</span>
                            <span class="rk-f-val">${keeper.agent_name ?? '직접 정의'}</span>
                          </div>
                          <div class="rk-facet rt" title="바인딩된 런타임">
                            <span class="rk-f-lyr"></span>
                            <span class="rk-f-val">${runtime ?? '런타임 없음'}</span>
                          </div>
                        </div>
                      `
                    })}
                  </div>
                </div>
              `
            })}
            ${roster.length === 0
              ? html`<div class="reg-empty">등록된 keeper가 없습니다.</div>`
              : null}
          </div>
        </section>
      </div>

      ${deregister
        ? html`<${RegistryDeregister}
            keeper=${deregister.keeper}
            state=${deregister.state}
            onClose=${() => setDeregister(null)}
          />`
        : null}
    </main>
  `
}
