import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'

import type { Keeper } from '../../types'
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
import type { AsyncState } from '../../lib/async-state'
import type { PersonaSummary } from '../../api/schemas/persona'
import { keepers } from '../../store'
import {
  loadPersonas,
  personasResource,
} from '../keeper-spawn/keeper-spawn-state'
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

function PersonaLayer({ state }: { state: AsyncState<readonly PersonaSummary[]> }) {
  if (state.status === 'idle' || state.status === 'loading') {
    return html`
      <div class="reg-layer reg-personas">
        <h3 style="margin:0 0 8px;">Persona <${Pill} tone="info">…<//></h3>
        <p style="opacity:.6;">불러오는 중…</p>
      </div>
    `
  }

  if (state.status === 'error') {
    return html`
      <div class="reg-layer reg-personas">
        <h3 style="margin:0 0 8px;">Persona <${Pill} tone="bad">오류<//></h3>
        <p class="reg-error" style="color:var(--color-status-err);">persona 목록 로드 실패: ${state.message}</p>
      </div>
    `
  }

  return html`
    <div class="reg-layer reg-personas">
      <h3 style="margin:0 0 8px;">Persona <${Pill} tone="info">${state.data.length}<//></h3>
      ${state.data.length === 0
        ? html`<p style="opacity:.6;">등록된 persona가 없습니다.</p>`
        : html`
            <ul style="list-style:none;margin:0;padding:0;display:flex;flex-wrap:wrap;gap:8px;">
              ${state.data.map(persona => html`
                <li key=${persona.persona_name} class="reg-persona-card"
                    style="border:1px solid var(--color-border-default);border-radius:8px;padding:8px 12px;">
                  <strong>${persona.display_name}</strong>
                  ${persona.trait ? html`<span style="opacity:.7;"> · ${persona.trait}</span>` : null}
                  ${persona.has_keeper_defaults ? html` <${Pill} tone="neutral">keeper defaults<//>` : null}
                </li>
              `)}
            </ul>
          `}
    </div>
  `
}

export function RegistrySurface() {
  useEffect(() => {
    void loadPersonas()
  }, [])

  const personaState = personasResource.state.value
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

  return html`
    <section class="reg-surface" style="padding:16px;display:flex;flex-direction:column;gap:20px;">
      <${PersonaLayer} state=${personaState} />

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
                        <li key=${row.keeper.name} class="reg-keeper-row"
                            style="display:flex;align-items:center;gap:8px;">
                          <${KeeperBadge} id=${row.keeper.name} variant="full" size="sm" />
                          <span style="opacity:.7;font-size:12px;">
                            ${runtime ?? '런타임 없음'}
                          </span>
                          ${configuredOnly(row.state) ? html`<${Pill} tone="neutral">configured<//>` : null}
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
