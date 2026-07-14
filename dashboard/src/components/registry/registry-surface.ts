// MASC v2 — Registry surface (A4 skeleton).
// The operator's home for the three layers of a keeper's being:
//   이데아 (Persona · 형상) → 실재 (Keeper · 인스턴스) → 런타임 (Runtime · 바인딩)
// A persona is a SEED: its text is copied into a keeper at instantiation, then
// the two are independent — editing a persona never reaches back into a live
// keeper (server-side persona overlay retirement is tracked separately, A2).
//
// Skeleton scope (WO-A4-1/2a first slice): read-only three-layer roster.
//   · personas — fetched on mount via masc_persona_list (no refresh-task lane).
//     Name/display/description parsing is delegated to keeper-spawn-state's
//     normalizePersonaSummary (the SSOT for the masc_persona_list entry
//     shape, shared by 15+ spawn-panel consumers) — see
//     normalizeRegistryPersonas below for what Registry adds on top and why.
//   · keepers  — the store `keepers` signal, hydrated by the execution
//     snapshot (tab-refresh plan + dashboard-ws execution slice subscription)
//   · runtime  — each keeper row shows its runtime binding when known
// Create/edit/deregister dialogs land with the full keeper-v2 registry port.

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import type { Keeper } from '../../types'
import { callMcpTool } from '../../api/mcp'
import { keepers } from '../../store'
import { isRecord } from '../common/normalize'
import { createAsyncResource, isFailed, getData } from '../../lib/async-state'
import { normalizePersonaSummary } from '../keeper-spawn/keeper-spawn-state'
import { KeeperBadge } from '../keeper-badge'
import { Dot, Pill, type DotState } from '../v2/primitives-v2'

export interface RegistryPersona {
  persona_name: string
  display_name: string
  trait: string | null
  has_keeper_defaults: boolean
}

// masc_persona_list returns { count, personas } where each entry is either a
// detailed summary object or (only when called with detailed:false, which no
// dashboard caller does today) a bare name string.
//
// Name/display/description parsing is delegated to normalizePersonaSummary
// (keeper-spawn-state.ts) — the shared pipeline 15+ spawn-panel consumers
// already rely on — so there is exactly one place that knows the
// persona_name/name and display_name/displayName/name fallback rules; this
// function no longer re-derives them. Registry adds only the two things that
// shared pipeline doesn't provide:
//
// 1. has_keeper_defaults. It's on the wire in every masc_persona_list
//    response (see keeper_tool_persona_runtime.ml:persona_summary_to_json —
//    always included, unconditional on `detailed`), but PersonaSummary
//    doesn't carry it. Extending PersonaSummary would be the cleaner fix;
//    it's deferred here specifically to avoid touching keeper-spawn-state.ts
//    while #24340 is rewriting that file (cross-conflict risk) — NOT because
//    of a real fetch-shape difference. masc_persona_list defaults `detailed`
//    to true server-side (keeper_persona.ml:persona_list_handler), so
//    keeper-spawn-state's `{}` call and Registry's explicit
//    `{ detailed: true }` call below already hit the identical response
//    shape; an earlier version of this comment claimed otherwise and was
//    wrong.
// 2. Distinguishing a schema mismatch (null, surfaced as an error) from a
//    genuinely empty roster ([]). normalizePersonaSummaries always returns
//    [] (extractArray swallows a non-array/absent `personas` into []), so
//    that distinction has to live here — it is not something the shared
//    pipeline's "error channel" resolves for us.
export function normalizeRegistryPersonas(json: unknown): RegistryPersona[] | null {
  if (!isRecord(json) || !Array.isArray(json.personas)) return null
  return json.personas.flatMap((entry): RegistryPersona[] => {
    if (typeof entry === 'string') {
      return [{ persona_name: entry, display_name: entry, trait: null, has_keeper_defaults: false }]
    }
    const summary = normalizePersonaSummary(entry)
    if (!summary) return []
    return [{
      persona_name: summary.name,
      display_name: summary.displayName ?? summary.name,
      trait: summary.description ?? null,
      has_keeper_defaults: isRecord(entry) && entry.has_keeper_defaults === true,
    }]
  })
}

// Registry keeps its own resource rather than importing keeper-spawn-state's
// personas/personasLoading/personasError signals directly: those signals are
// PersonaSummary[], which carries neither has_keeper_defaults nor the
// null-vs-[] distinction above, and widening that shared type touches the
// same file #24340 is mid-rewrite on. One extra fetch of an already-cheap
// read_state tool is the accepted cost of not touching that file now; full
// unification (single resource, single fetch) is tracked for when the
// registry wizard replaces the spawn panel (A4-3a, after #24340 lands).
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
