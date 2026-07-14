// MASC v2 — Registry surface (A4 skeleton).
// The operator's home for the three layers of a keeper's being:
//   이데아 (Persona · 형상) → 실재 (Keeper · 인스턴스) → 런타임 (Runtime · 바인딩)
// A persona is a SEED: its text is copied into a keeper at instantiation, then
// the two are independent — editing a persona never reaches back into a live
// keeper (server-side persona overlay retirement is tracked separately, A2).
//
// Skeleton scope (WO-A4-1/2a first slice): read-only three-layer roster.
//   · personas — fetched on mount via masc_persona_list (no refresh-task lane)
//   · keepers  — the store `keepers` signal, hydrated by the execution
//     snapshot (tab-refresh plan + dashboard-ws execution slice subscription)
//   · runtime  — each keeper row shows its runtime binding when known
// Create/edit/deregister dialogs land with the full keeper-v2 registry port.

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import type { Keeper } from '../../types'
import { callMcpTool } from '../../api/mcp'
import { keepers } from '../../store'
import { asString, isRecord } from '../common/normalize'
import { createAsyncResource, isFailed, getData } from '../../lib/async-state'
import { KeeperBadge } from '../keeper-badge'
import { Dot, Pill, type DotState } from '../v2/primitives-v2'

export interface RegistryPersona {
  persona_name: string
  display_name: string
  trait: string | null
  has_keeper_defaults: boolean
}

// Defensive normalize on the shared helper idiom (asString/isRecord — the
// same building blocks keeper-spawn-state's persona pipeline uses; full
// unification onto that pipeline is deferred until the spawn panel is
// replaced by the registry wizard, after #24340 lands on this domain).
// masc_persona_list returns { count, personas } where each entry is either
// a summary object (detailed) or a bare name string. A schema mismatch
// (no `personas` array) returns null — the caller surfaces it as an error
// instead of rendering a fake empty roster; per-entry junk is skipped.
export function normalizeRegistryPersonas(json: unknown): RegistryPersona[] | null {
  if (!isRecord(json)) return null
  const personas = json.personas
  if (!Array.isArray(personas)) return null
  return personas.flatMap((entry): RegistryPersona[] => {
    if (typeof entry === 'string') {
      return [{ persona_name: entry, display_name: entry, trait: null, has_keeper_defaults: false }]
    }
    if (!isRecord(entry)) return []
    const name = asString(entry.persona_name)
    if (!name) return []
    return [{
      persona_name: name,
      display_name: asString(entry.display_name) ?? name,
      trait: asString(entry.trait) ?? null,
      has_keeper_defaults: entry.has_keeper_defaults === true,
    }]
  })
}

// Registry-scoped resource: the spawn panel's shared personasResource calls
// masc_persona_list without `detailed`, drops bare-name entries, and lacks
// has_keeper_defaults — retargeting it would change behaviour for its 15+
// consumers while #24340 is rewriting that domain. One resource, one fetch
// shape, per surface until the wizard unifies them.
export const registryPersonas = createAsyncResource<RegistryPersona[]>()

export async function loadRegistryPersonas(): Promise<void> {
  await registryPersonas.load(async () => {
    const raw = await callMcpTool('masc_persona_list', { detailed: true })
    const parsed = normalizeRegistryPersonas(JSON.parse(raw))
    if (parsed === null) throw new Error('masc_persona_list: unexpected response shape')
    return parsed
  })
}

type KeeperGroupId = 'run' | 'pause' | 'off'

const KEEPER_GROUPS: ReadonlyArray<readonly [KeeperGroupId, string]> = [
  ['run', '실행 중'],
  ['pause', '대기 · 일시정지'],
  ['off', '중지 · 미기동'],
]

// Grouping is a projection of live signals, not a new state machine: a keeper
// with a running keepalive fiber is 'run', a paused-but-registered one is
// 'pause', everything else (configured-only, dead, unregistered) is 'off'.
export function keeperGroup(k: Keeper): KeeperGroupId {
  if (k.paused === true) return 'pause'
  if (k.keepalive_running === true) return 'run'
  return 'off'
}

function groupDot(group: KeeperGroupId): DotState {
  switch (group) {
    case 'run':
      return 'ok'
    case 'pause':
      return 'warn'
    case 'off':
      return 'idle'
  }
}

export function RegistrySurface() {
  useEffect(() => {
    void loadRegistryPersonas()
  }, [])

  const personaState = registryPersonas.state.value
  const personas = getData(personaState) ?? null
  const personaError = isFailed(personaState) ? personaState.message : null

  const roster = keepers.value
  const grouped = useMemo(() => {
    const map: Record<KeeperGroupId, Keeper[]> = { run: [], pause: [], off: [] }
    for (const k of roster) map[keeperGroup(k)].push(k)
    return map
  }, [roster])

  return html`
    <section class="reg-surface" style="padding:16px;display:flex;flex-direction:column;gap:20px;">
      <header>
        <h2 style="margin:0;">Registry</h2>
        <p style="margin:4px 0 0;opacity:.7;">이데아(Persona) → 실재(Keeper) → 런타임 바인딩</p>
      </header>

      <div class="reg-layer reg-personas">
        <h3 style="margin:0 0 8px;">이데아 · Persona <${Pill} tone="info">${personas?.length ?? '…'}<//></h3>
        ${personaError
          ? html`<p class="reg-error" style="color:var(--color-bad,#e5534b);">persona 목록 로드 실패: ${personaError}</p>`
          : personas === null
            ? html`<p style="opacity:.6;">불러오는 중…</p>`
            : personas.length === 0
              ? html`<p style="opacity:.6;">등록된 persona가 없습니다.</p>`
              : html`
                  <ul style="list-style:none;margin:0;padding:0;display:flex;flex-wrap:wrap;gap:8px;">
                    ${personas.map(p => html`
                      <li key=${p.persona_name} class="reg-persona-card"
                          style="border:1px solid var(--color-border,#333);border-radius:8px;padding:8px 12px;">
                        <strong>${p.display_name}</strong>
                        ${p.trait ? html`<span style="opacity:.7;"> · ${p.trait}</span>` : null}
                        ${p.has_keeper_defaults ? html` <${Pill} tone="neutral">keeper.*<//>` : null}
                      </li>
                    `)}
                  </ul>
                `}
      </div>

      <div class="reg-layer reg-keepers">
        <h3 style="margin:0 0 8px;">실재 · Keeper <${Pill} tone="info">${roster.length}<//></h3>
        ${KEEPER_GROUPS.map(([group, label]) => html`
          <div key=${group} class="reg-kgroup" style="margin-bottom:12px;">
            <h4 style="margin:0 0 6px;display:flex;align-items:center;gap:6px;">
              <${Dot} state=${groupDot(group)} /> ${label}
              <span style="opacity:.6;">${grouped[group].length}</span>
            </h4>
            ${grouped[group].length === 0
              ? html`<p style="margin:0;opacity:.5;">없음</p>`
              : html`
                  <ul style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:4px;">
                    ${grouped[group].map(k => html`
                      <li key=${k.name} class="reg-keeper-row"
                          style="display:flex;align-items:center;gap:8px;">
                        <${KeeperBadge} id=${k.name} variant="full" size="sm" />
                        <span style="opacity:.7;font-size:12px;">
                          ${k.runtime_id ?? k.runtime_canonical ?? '런타임 미바인딩'}
                        </span>
                        ${k.registered === false ? html`<${Pill} tone="neutral">configured<//>` : null}
                      </li>
                    `)}
                  </ul>
                `}
          </div>
        `)}
      </div>
    </section>
  `
}
