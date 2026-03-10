import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type {
  ChainHistoryEventSummary,
  CommandPlaneChainOverlay,
  CommandPlaneChainRunNode,
  CommandPlaneDetachmentCard,
  CommandPlaneOperationCard,
} from '../../types'
import {
  clearCommandPlaneChainRun,
  commandPlaneChainError,
  commandPlaneChainFocusOperationId,
  commandPlaneChainLoading,
  commandPlaneChainRun,
  commandPlaneChainRunError,
  commandPlaneChainRunLoading,
  commandPlaneChainSummary,
  commandPlaneSnapshot,
  focusCommandPlaneChainOperation,
  loadCommandPlaneChainRun,
  pauseCommandPlaneOperation,
  recallCommandPlaneOperation,
  resumeCommandPlaneOperation,
  setCommandPlaneSurface,
} from '../../command-store'
import { navigate } from '../../router'
import { PanelSemanticDetails } from '../common/semantic-layer'
import {
  actionDisabled,
  chainStatusTone,
  deadlineLabel,
  expiryTone,
  fire,
  formatElapsed,
  formatPercent,
  getMermaid,
  historySummary,
  incrementMermaidRenderCount,
  relativeTime,
  toneClass,
} from './helpers'

function MermaidGraph({ source }: { source: string }) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const host = hostRef.current
    if (!host) return undefined
    host.innerHTML = ''
    setError(null)

    const render = async () => {
      try {
        const mermaid = await getMermaid()
        const { svg } = await mermaid.render(`command-chain-${incrementMermaidRenderCount()}`, source)
        if (cancelled || !hostRef.current) return
        hostRef.current.innerHTML = svg
      } catch (err) {
        if (cancelled) return
        setError(err instanceof Error ? err.message : 'Mermaid render failed')
      }
    }

    void render()
    return () => {
      cancelled = true
      if (hostRef.current) hostRef.current.innerHTML = ''
    }
  }, [source])

  return html`
    <div class="command-chain-graph-shell">
      ${error ? html`<div class="empty-state error">${error}</div>` : null}
      <div class="command-chain-graph" ref=${hostRef}></div>
    </div>
  `
}

function ChainOperationListItem(
  { overlay, selected, onSelect }: { overlay: CommandPlaneChainOverlay; selected: boolean; onSelect: () => void },
) {
  const chain = overlay.operation.chain
  const runtime = overlay.runtime
  return html`
    <button class="command-chain-item ${selected ? 'selected' : ''}" onClick=${onSelect}>
      <div class="command-card-head">
        <div>
          <strong>${overlay.operation.objective}</strong>
          <div class="command-card-sub">${overlay.operation.operation_id}</div>
        </div>
        <span class="command-chip ${chainStatusTone(chain?.status)}">${chain?.status ?? overlay.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${chain?.kind ?? 'chain_dsl'}</span>
        ${chain?.chain_id ? html`<span class="command-tag">${chain.chain_id}</span>` : null}
        ${runtime ? html`<span class="command-tag ${chainStatusTone(chain?.status)}">${formatPercent(runtime.progress)} progress</span>` : null}
      </div>
      <div class="command-card-sub">${historySummary(overlay.history)}</div>
    </button>
  `
}

function ChainHistoryRow({ item }: { item: ChainHistoryEventSummary }) {
  return html`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${item.chain_id ?? 'unknown-chain'}</strong>
        <span class="command-chip ${chainStatusTone(item.event)}">${item.event}</span>
      </div>
      <div class="command-card-sub">${relativeTime(item.timestamp)}</div>
      <div class="command-card-sub">${historySummary(item)}</div>
    </article>
  `
}

function ChainRunNodeRow({ node }: { node: CommandPlaneChainRunNode }) {
  return html`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${node.id}</strong>
        <span class="command-chip ${chainStatusTone(node.status)}">${node.status ?? 'unknown'}</span>
      </div>
      <div class="command-card-sub">
        ${node.type ?? 'node'}
        ${typeof node.duration_ms === 'number' ? ` · ${node.duration_ms}ms` : ''}
      </div>
      ${node.error ? html`<div class="command-card-sub error-text">${node.error}</div>` : null}
    </article>
  `
}

function OperationCard({ card }: { card: CommandPlaneOperationCard }) {
  const op = card.operation
  const pauseKey = `pause:${op.operation_id}`
  const resumeKey = `resume:${op.operation_id}`
  const recallKey = `recall:${op.operation_id}`
  const chain = op.chain
  const runId = chain?.run_id ?? null
  return html`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${op.objective}</strong>
          <div class="command-card-sub">${op.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(op.status === 'active' ? 'ok' : op.status === 'paused' ? 'warn' : op.status === 'failed' ? 'bad' : 'ok')}">${op.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${card.assigned_unit_label ?? op.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${op.trace_id}</span>
        <span>Autonomy</span><span>${op.autonomy_level ?? 'n/a'}</span>
        <span>Budget</span><span>${op.budget_class ?? 'standard'}</span>
        <span>Source</span><span>${op.source ?? 'managed'}</span>
        <span>Updated</span><span>${relativeTime(op.updated_at)}</span>
      </div>
      ${chain
        ? html`
            <div class="command-tag-row">
              <span class="command-tag">${chain.kind}</span>
              <span class="command-tag ${chainStatusTone(chain.status)}">${chain.status}</span>
              ${chain.chain_id ? html`<span class="command-tag">${chain.chain_id}</span>` : null}
              ${chain.run_id ? html`<span class="command-tag">run ${chain.run_id}</span>` : null}
            </div>
          `
        : null}
      ${op.checkpoint_ref
        ? html`<div class="command-card-foot">Checkpoint ${op.checkpoint_ref}</div>`
        : null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${() => {
            setCommandPlaneSurface('swarm')
            navigate('command', {
              surface: 'swarm',
              operation_id: op.operation_id,
              ...(runId ? { run_id: runId } : {}),
            })
          }}
        >
          Swarm Live
        </button>
        ${chain
          ? html`
              <button
                class="control-btn ghost"
                onClick=${() => {
                  focusCommandPlaneChainOperation(op.operation_id)
                  setCommandPlaneSurface('chains')
                  navigate('command', { surface: 'chains', operation: op.operation_id })
                }}
              >
                Open Chain
              </button>
            `
          : null}
        ${op.source === 'managed' && op.status === 'active'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(pauseKey)} onClick=${() => fire(() => pauseCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(pauseKey) ? 'Pausing…' : 'Pause'}
              </button>
              <button class="control-btn ghost" disabled=${actionDisabled(recallKey)} onClick=${() => fire(() => recallCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(recallKey) ? 'Recalling…' : 'Recall'}
              </button>
            `
          : null}
        ${op.source === 'managed' && op.status === 'paused'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(resumeKey)} onClick=${() => fire(() => resumeCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(resumeKey) ? 'Resuming…' : 'Resume'}
              </button>
            `
          : null}
      </div>
    </article>
  `
}

function DetachmentCard({ card }: { card: CommandPlaneDetachmentCard }) {
  const detachment = card.detachment
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${detachment.detachment_id}</strong>
          <div class="command-card-sub">${card.operation?.objective ?? detachment.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(detachment.status)}">${detachment.status ?? 'active'}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${card.assigned_unit_label ?? detachment.assigned_unit_id}</span>
        <span>Leader</span><span>${detachment.leader_id ?? 'unassigned'}</span>
        <span>Roster</span><span>${detachment.roster.length}</span>
        <span>Session</span><span>${detachment.session_id ?? 'none'}</span>
        <span>Runtime</span><span>${detachment.runtime_kind ?? 'managed'}</span>
        <span>Runtime Ref</span><span>${detachment.runtime_ref ?? 'n/a'}</span>
        <span>Progress</span><span>${relativeTime(detachment.last_progress_at)}</span>
        <span>Heartbeat</span><span>${deadlineLabel(detachment.heartbeat_deadline)}</span>
        <span>Updated</span><span>${relativeTime(detachment.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${detachment.heartbeat_deadline
          ? html`<span class="command-tag ${expiryTone(detachment.heartbeat_deadline)}">
              deadline ${detachment.heartbeat_deadline}
            </span>`
          : null}
      </div>
    </article>
  `
}

export function OperationsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${PanelSemanticDetails} panelId="command.operations" compact=${true} />
        </div>
        ${snapshot && snapshot.operations.operations.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.operations.operations.map(card => html`<${OperationCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${PanelSemanticDetails} panelId="command.operations" compact=${true} />
        </div>
        ${snapshot && snapshot.detachments.detachments.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.detachments.detachments.map(card => html`<${DetachmentCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `
}

export function ChainsSurface() {
  const summary = commandPlaneChainSummary.value
  const overlays = summary?.operations ?? []
  const focusedOperationId = commandPlaneChainFocusOperationId.value
  const selectedOverlay =
    overlays.find(item => item.operation.operation_id === focusedOperationId)
    ?? overlays[0]
    ?? null
  const selectedRunId = selectedOverlay?.operation.chain?.run_id ?? null
  const run = commandPlaneChainRun.value?.run ?? selectedOverlay?.preview_run ?? null
  const isPreviewRun = !commandPlaneChainRun.value?.run && !!selectedOverlay?.preview_run

  useEffect(() => {
    if (selectedRunId) {
      void loadCommandPlaneChainRun(selectedRunId)
    } else {
      clearCommandPlaneChainRun()
    }
  }, [selectedRunId])

  return html`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${PanelSemanticDetails} panelId="command.chains" compact=${true} />
        </div>
        <article class="command-guide-card ${chainStatusTone(summary?.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${chainStatusTone(summary?.connection.status)}">${summary?.connection.status ?? 'disconnected'}</span>
          </div>
          <p>${summary?.connection.message ?? 'Chain summary is aggregated through the MASC proxy.'}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${summary?.connection.base_url ?? 'n/a'}</span>
            <span>Linked Ops</span><span>${summary?.summary?.linked_operations ?? 0}</span>
            <span>Active Chains</span><span>${summary?.summary?.active_chains ?? 0}</span>
            <span>Recent Failures</span><span>${summary?.summary?.recent_failures ?? 0}</span>
            <span>Last Event</span><span>${relativeTime(summary?.summary?.last_history_event_at)}</span>
          </div>
        </article>

        ${commandPlaneChainError.value
          ? html`<div class="empty-state error">${commandPlaneChainError.value}</div>`
          : null}

        ${commandPlaneChainLoading.value && !summary
          ? html`<div class="empty-state">Loading chain overlays…</div>`
          : overlays.length > 0
            ? html`
                <div class="command-chain-list">
                  ${overlays.map(overlay => html`
                    <${ChainOperationListItem}
                      overlay=${overlay}
                      selected=${selectedOverlay?.operation.operation_id === overlay.operation.operation_id}
                      onSelect=${() => focusCommandPlaneChainOperation(overlay.operation.operation_id)}
                    />
                  `)}
                </div>
              `
            : html`<div class="empty-state">No chain-backed operations yet.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>Recent history</strong>
            <span class="command-chip">${summary?.recent_history.length ?? 0}</span>
          </div>
          ${summary && summary.recent_history.length > 0
            ? html`
                <div class="command-card-stack">
                  ${summary.recent_history.slice(0, 6).map(item => html`<${ChainHistoryRow} item=${item} />`)}
                </div>
              `
            : html`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${PanelSemanticDetails} panelId="command.chains" compact=${true} />
        </div>
        ${selectedOverlay
          ? html`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${selectedOverlay.operation.objective}</strong>
                    <div class="command-card-sub">${selectedOverlay.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${chainStatusTone(selectedOverlay.operation.chain?.status)}">
                    ${selectedOverlay.operation.chain?.status ?? selectedOverlay.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${selectedOverlay.operation.chain?.kind ?? 'chain_dsl'}</span>
                  <span>Chain ID</span><span>${selectedOverlay.operation.chain?.chain_id ?? 'goal-driven'}</span>
                  <span>Run ID</span><span>${selectedRunId ?? 'not materialized'}</span>
                  <span>Progress</span><span>${formatPercent(selectedOverlay.runtime?.progress)}</span>
                  <span>Elapsed</span><span>${formatElapsed(selectedOverlay.runtime?.elapsed_sec)}</span>
                  <span>Updated</span><span>${relativeTime(selectedOverlay.operation.chain?.last_sync_at ?? selectedOverlay.operation.updated_at)}</span>
                </div>
                ${selectedOverlay.operation.chain?.goal
                  ? html`<div class="command-card-foot">${selectedOverlay.operation.chain.goal}</div>`
                  : null}
              </article>

              ${selectedOverlay.mermaid
                ? html`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${selectedOverlay.operation.chain?.chain_id ?? 'graph'}</span>
                      </div>
                      <${MermaidGraph} source=${selectedOverlay.mermaid} />
                    </div>
                  `
                : html`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${run?.success === false ? 'bad' : 'ok'}">
                    ${run
                      ? (run.success === false ? 'failed' : isPreviewRun ? 'preview' : 'captured')
                      : 'pending'}
                  </span>
                </div>
                ${commandPlaneChainRunLoading.value
                  ? html`<div class="empty-state">Loading run detail…</div>`
                  : commandPlaneChainRunError.value
                    ? html`<div class="empty-state error">${commandPlaneChainRunError.value}</div>`
                    : run && run.nodes.length > 0
                      ? html`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${run.chain_id}</span>
                            <span>Run</span><span>${run.run_id ?? 'preview only'}</span>
                            <span>Duration</span><span>${run.duration_ms != null ? `${run.duration_ms}ms` : 'n/a'}</span>
                            <span>Nodes</span><span>${run.nodes.length}</span>
                          </div>
                          ${isPreviewRun
                            ? html`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`
                            : null}
                          <div class="command-card-stack">
                            ${run.nodes.map(node => html`<${ChainRunNodeRow} node=${node} />`)}
                          </div>
                        `
                      : html`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `
          : html`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `
}
