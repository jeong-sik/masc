import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  type KeeperCompositeSnapshot,
  type KeeperCompositeInvariants,
} from '../api/keeper'
import { keepers } from '../store'
import { compositeTick } from '../composite-signals'
import { EmptyState } from './common/empty-state'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { buildCompositeFsmSpec } from './keeper-fsm-specs'

/**
 * FSM Hub — architecture audit surface for the composite keeper lifecycle.
 *
 * Data source: `/api/v1/keepers/:name/composite` (RFC-0003 §7).
 * Rendered as four sub-FSM badges (KSM / KTC / KDP / KCL / KMC) plus the
 * five safety invariants from KeeperCompositeLifecycle.tla.
 *
 * This MVP shows the composite snapshot as structured rows rather than a
 * Cytoscape compound graph; the compound view is tracked as a follow-up
 * (docs/design/dashboard-fsm-redesign.md Phase 3 §2).
 */
export function FsmHub() {
  const [selected, setSelected] = useState<string | null>(null)
  const [snapshot, setSnapshot] = useState<KeeperCompositeSnapshot | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const keeperList = keepers.value
  const keeperNames = useMemo(
    () => keeperList.map(k => k.name).sort(),
    [keeperList],
  )

  // Pick the first keeper by default once the list is loaded.
  useEffect(() => {
    if (selected == null && keeperNames.length > 0) {
      const first = keeperNames[0]
      if (first) setSelected(first)
    }
  }, [keeperNames, selected])

  // Re-fetch composite snapshot whenever the selected keeper changes OR the
  // SSE envelope signals a registry mutation on it. [compositeTick.value.ts_unix]
  // advances monotonically; the name match guards against unrelated keeper
  // events triggering refetches.
  const tick = compositeTick.value
  const shouldRefetchForTick =
    selected != null && tick.name === selected ? tick.ts_unix : 0

  // Periodic polling (30s) keeps the hub current even when keepers are idle
  // and no SSE events fire. Without this the page freezes once activity stops.
  const [pollTick, setPollTick] = useState(0)
  useEffect(() => {
    const id = setInterval(() => setPollTick(t => t + 1), 30_000)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    if (!selected) return
    let cancelled = false
    setLoading(true)
    setError(null)

    const run = async () => {
      try {
        const data = await fetchKeeperComposite(selected)
        if (!cancelled) {
          setSnapshot(data)
          setLoading(false)
        }
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'composite fetch failed')
          setLoading(false)
        }
      }
    }

    run()

    return () => {
      cancelled = true
    }
  }, [selected, shouldRefetchForTick, pollTick])

  return html`
    <div class="flex flex-col gap-5">
      <${HubHeader} />
      <${KeeperPicker}
        names=${keeperNames}
        selected=${selected}
        onSelect=${setSelected}
      />

      ${selected == null ? html`
        <${EmptyState} message="관찰할 키퍼를 선택하세요" />
      ` : loading && !snapshot ? html`
        <div class="flex items-center justify-center gap-2 py-10 text-[11px] text-[var(--text-dim)]">
          <span class="inline-block h-3 w-3 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin"></span>
          composite 스냅샷 로딩중
        </div>
      ` : error ? html`
        <${EmptyState} message=${error} compact />
      ` : snapshot ? html`
        <${CompositeGraphPanel} snapshot=${snapshot} />
        <div class="grid gap-4 lg:grid-cols-2">
          <${SubFsmCard} label="KSM · Keeper lifecycle" value=${snapshot.phase} tone="accent" />
          <${SubFsmCard} label="KTC · Turn cycle" value=${snapshot.turn_phase} tone="indigo" />
          <${SubFsmCard} label="KDP · Decision pipeline" value=${snapshot.decision.stage} tone="indigo" />
          <${SubFsmCard} label="KCL · Cascade state" value=${snapshot.cascade.state} tone="indigo" />
          <${SubFsmCard} label="KMC · Memory compaction" value=${snapshot.compaction.stage} tone="amber" />
          <${MeasurementCard} snapshot=${snapshot} />
        </div>
        <${InvariantsPanel} invariants=${snapshot.invariants} />
        <${RecoveryStatePanel}
          dataRecord=${snapshot.recovery.data_record}
          fsmCondition=${snapshot.recovery.fsm_condition}
        />
        <${SnapshotMeta} snapshot=${snapshot} />
      ` : null}
    </div>
  `
}

function CompositeGraphPanel({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const spec = useMemo(() => buildCompositeFsmSpec({
    phase: snapshot.phase,
    turnPhase: snapshot.turn_phase,
    decisionStage: snapshot.decision.stage,
    cascadeState: snapshot.cascade.state,
    compactionStage: snapshot.compaction.stage,
  }), [
    snapshot.phase,
    snapshot.turn_phase,
    snapshot.decision.stage,
    snapshot.cascade.state,
    snapshot.compaction.stage,
  ])

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="mb-2 flex items-center justify-between">
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          Composite compound view — 5 sub-FSMs
        </div>
        <span class="text-[10px] text-[var(--text-dim)]">
          KeeperCompositeLifecycle.tla
        </span>
      </div>
      <${CytoscapeFsm} spec=${spec} height="360px" />
    </div>
  `
}

function HubHeader() {
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-4">
      <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-[var(--text-muted)]">
        FSM Hub — RFC-0003 Composite Lifecycle
      </div>
      <div class="mt-1 text-[11px] leading-[1.55] text-[var(--text-body)]">
        Decision · Cascade · Memory · Compaction 네 서브 FSM을 교차로 관찰합니다.
        Observer는 <code class="px-1 font-mono text-[var(--accent)]">Keeper_composite_observer.observe</code>
        를 통해 순수 투영만 수행합니다 — 상태 변경/라우팅은 이 페이지에서 일어나지 않습니다.
      </div>
    </div>
  `
}

function KeeperPicker({
  names,
  selected,
  onSelect,
}: {
  names: string[]
  selected: string | null
  onSelect: (n: string) => void
}) {
  if (names.length === 0) {
    return html`<${EmptyState} message="등록된 키퍼가 없습니다" compact />`
  }

  return html`
    <div class="flex flex-wrap items-center gap-2">
      <span class="text-[10px] uppercase tracking-[0.1em] text-[var(--text-muted)]">관찰 대상</span>
      ${names.map(name => {
        const active = name === selected
        const cls = active
          ? 'bg-[var(--accent-10)] border-[var(--accent-30)] text-[var(--accent)]'
          : 'bg-[var(--white-3)] border-[var(--white-8)] text-[var(--text-body)] hover:border-[var(--accent-30)]'
        return html`
          <button
            class=${`rounded-full border px-3 py-1 text-[11px] font-mono transition-colors ${cls}`}
            onClick=${() => onSelect(name)}
          >
            ${name}
          </button>
        `
      })}
    </div>
  `
}

function SubFsmCard({
  label,
  value,
  tone,
}: {
  label: string
  value: string
  tone: 'accent' | 'indigo' | 'amber'
}) {
  const toneCls =
    tone === 'accent'
      ? 'text-[var(--accent)]'
      : tone === 'indigo'
        ? 'text-[#818cf8]'
        : 'text-[#f59e0b]'

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-4">
      <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">${label}</div>
      <div class=${`mt-1.5 font-mono text-[18px] font-semibold ${toneCls}`}>${value}</div>
    </div>
  `
}

function MeasurementCard({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const m = snapshot.measurement
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-4">
      <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
        Shared measurement
      </div>
      ${m.captured && m.auto_rules ? html`
        <div class="mt-1.5 flex flex-col gap-1 text-[11px] text-[var(--text-body)]">
          <div class="flex gap-2 font-mono">
            <${Flag} label="reflect" on=${m.auto_rules.reflect} />
            <${Flag} label="plan" on=${m.auto_rules.plan} />
            <${Flag} label="compact" on=${m.auto_rules.compact} />
            <${Flag} label="handoff" on=${m.auto_rules.handoff} />
          </div>
          <div class="flex gap-2 font-mono">
            <${Flag} label="guardrail" on=${m.auto_rules.guardrail_stop} tone="warn" />
            <span class="text-[var(--text-dim)]">drift ${m.auto_rules.goal_drift.toFixed(2)}</span>
          </div>
          ${m.auto_rules.guardrail_reason ? html`
            <div class="text-[10px] text-[#f59e0b]">사유: ${m.auto_rules.guardrail_reason}</div>
          ` : null}
        </div>
      ` : html`
        <div class="mt-1.5 text-[11px] text-[var(--text-dim)]">
          아직 관측된 Context_measured 이벤트가 없습니다.
        </div>
      `}
    </div>
  `
}

function Flag({ label, on, tone = 'ok' }: { label: string; on: boolean; tone?: 'ok' | 'warn' }) {
  const offCls = 'text-[var(--text-dim)] border-[var(--white-8)]'
  const onCls =
    tone === 'warn'
      ? 'text-[#f59e0b] border-[rgba(251,191,36,0.3)] bg-[rgba(251,191,36,0.08)]'
      : 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
  return html`
    <span class=${`rounded-full border px-2 py-0.5 text-[10px] ${on ? onCls : offCls}`}>
      ${label}
    </span>
  `
}

const INVARIANT_LABELS: Record<keyof KeeperCompositeInvariants, string> = {
  phase_turn_alignment: 'PhaseTurnAlignment — phase=Compacting ⇔ turn=compacting',
  no_cascade_before_measurement: 'NoCascadeBeforeMeasurement — measurement 선행',
  compaction_atomicity: 'CompactionAtomicity — phase=Compacting ⇔ compaction_active',
  event_priority_monotone: 'EventPriorityMonotone — Compaction < Handoff < Context_measured',
  recovery_two_store_sync: 'RecoveryTwoStoreSync — data/fsm 저장소 동기',
}

function InvariantsPanel({ invariants }: { invariants: KeeperCompositeInvariants }) {
  const entries = Object.entries(invariants) as [keyof KeeperCompositeInvariants, boolean][]
  const allOk = entries.every(([, ok]) => ok)
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-4">
      <div class="flex items-center justify-between">
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          Safety invariants (KeeperCompositeLifecycle.tla)
        </div>
        <span class=${`rounded-full border px-2 py-0.5 text-[10px] font-mono ${
          allOk
            ? 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
            : 'text-[#ef4444] border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)]'
        }`}>
          ${allOk ? 'all green' : 'violation'}
        </span>
      </div>
      <ul class="mt-2 flex flex-col gap-1 text-[11px]">
        ${entries.map(([key, ok]) => html`
          <li class="flex items-center gap-2">
            <span class=${`h-2 w-2 rounded-full ${ok ? 'bg-[#22c55e]' : 'bg-[#ef4444]'}`}></span>
            <span class=${ok ? 'text-[var(--text-body)]' : 'text-[#f87171]'}>
              ${INVARIANT_LABELS[key]}
            </span>
          </li>
        `)}
      </ul>
    </div>
  `
}

function RecoveryStatePanel({
  dataRecord,
  fsmCondition,
}: {
  dataRecord: boolean
  fsmCondition: boolean
}) {
  const state =
    !dataRecord && !fsmCondition ? 'clean' :
    dataRecord && fsmCondition ? 'manual_reconcile_pending' :
    dataRecord && !fsmCondition ? 'drift: data set, fsm cleared' :
    'drift: fsm set, data cleared'
  const toneCls =
    state === 'clean'
      ? 'text-[#22c55e]'
      : state.startsWith('drift')
        ? 'text-[#ef4444]'
        : 'text-[#f59e0b]'
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-4">
      <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
        Recovery two-store (RFC-0003 §8)
      </div>
      <div class="mt-1.5 flex flex-wrap items-center gap-3 text-[11px]">
        <span class=${`font-mono ${toneCls}`}>${state}</span>
        <span class="text-[var(--text-dim)]">data_record <span class="font-mono text-[var(--text-body)]">${String(dataRecord)}</span></span>
        <span class="text-[var(--text-dim)]">fsm_condition <span class="font-mono text-[var(--text-body)]">${String(fsmCondition)}</span></span>
      </div>
    </div>
  `
}

function formatIdleDuration(seconds: number): string {
  if (seconds < 60) return `${Math.floor(seconds)}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${Math.floor(seconds % 60)}s`
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`
}

function SnapshotMeta({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const date = new Date(snapshot.ts * 1000)
  const nowSec = Date.now() / 1000
  const idleSec = snapshot.last_outcome
    ? nowSec - snapshot.last_outcome.ended_at
    : nowSec - snapshot.ts
  const isStale = idleSec > 300
  const liveClass = snapshot.is_live
    ? 'text-emerald-400 border-emerald-500/40'
    : isStale
      ? 'text-[#f59e0b] border-[rgba(245,158,11,0.3)]'
      : 'text-[var(--text-dim)] border-white/10'
  const liveLabel = snapshot.is_live
    ? '● LIVE'
    : `○ idle ${formatIdleDuration(idleSec)}`
  const lastOutcomeText = snapshot.last_outcome
    ? `last turn #${snapshot.last_outcome.turn_id} ended ${new Date(snapshot.last_outcome.ended_at * 1000).toLocaleTimeString()}`
    : 'no completed turn'
  return html`
    <div class="flex flex-wrap gap-2 text-[10px] text-[var(--text-dim)] font-mono items-center">
      <span class=${`px-1.5 py-0.5 border rounded ${liveClass}`}>
        ${liveLabel}
      </span>
      <span>correlation ${snapshot.correlation_id}</span>
      <span>run ${snapshot.run_id}</span>
      <span>ts ${date.toISOString()}</span>
      <span class="opacity-70">${lastOutcomeText}</span>
    </div>
  `
}
