import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import type { SkillEvidenceResponse } from '../api/dashboard-skills'

function recordedTime(value: number): string {
  const date = new Date(value * 1000)
  return Number.isFinite(date.getTime()) ? date.toISOString() : `${value} Unix seconds`
}

export function SkillRunHistory({ result, onSelect }: {
  result: SkillEvidenceResponse
  onSelect: (runId?: string) => void
}) {
  const outcome = useSignal('')
  const keeper = useSignal('')
  const search = useSignal('')
  const runs = result.composition_runs
  const selection = result.composition_selection
  if (runs === null) return html`<p role="status">Retained composition history is unavailable. A storage gap cannot establish absence.</p>`
  const query = search.value.trim().toLocaleLowerCase()
  const visible = runs.filter(run => (!outcome.value || run.disposition === outcome.value)
    && (!keeper.value || run.keeper === keeper.value)
    && (!query || run.composition_run_id.toLocaleLowerCase().includes(query)))
  return html`<section class="my-3 space-y-2" aria-label="Retained composition runs">
    <div class="flex flex-wrap items-center gap-2"><strong>Retained composition runs</strong>
      <button type="button" class="ss-btn" onClick=${() => onSelect()}>Latest retained</button></div>
    <p class="ss-muted text-3xs">Exact revision · each original run's latest retained result, newest recorded first. Earlier deferred-to-terminal transitions may have been replaced. Filters change this list; statistics still cover all retained runs.</p>
    ${selection.mode === 'exact_run' && result.composition === null
      ? html`<p role="status" class="text-[var(--color-status-warn)]">Requested run ${selection.composition_run_id} was not observed in this revision's retained coverage. No other run was substituted.</p>` : null}
    <div class="flex flex-wrap items-end gap-2">
      <label>Run ID<input class="ss-input" type="search" value=${search.value}
        onInput=${(event: Event) => { search.value = (event.currentTarget as HTMLInputElement).value }} /></label>
      <label>Run outcome<select class="ss-input" value=${outcome.value}
        onChange=${(event: Event) => { outcome.value = (event.currentTarget as HTMLSelectElement).value }}>
        <option value="">All outcomes</option><option value="completed">Completed</option>
        <option value="failed">Failed</option><option value="deferred">Deferred</option>
      </select></label>
      <label>Run Keeper<select class="ss-input" value=${keeper.value}
        onChange=${(event: Event) => { keeper.value = (event.currentTarget as HTMLSelectElement).value }}>
        <option value="">All Keepers</option>
        ${[...new Set(runs.map(run => run.keeper))].map(name => html`<option value=${name} key=${name}>${name}</option>`)}
      </select></label>
      <button type="button" class="ss-btn" onClick=${() => { search.value = ''; outcome.value = ''; keeper.value = '' }}>Clear run filters</button>
      <span role="status">${visible.length} of ${runs.length} retained runs</span>
    </div>
    ${visible.length === 0 ? html`<p>${runs.length === 0
      ? 'No original composition runs observed in this revision’s retained coverage.'
      : 'No retained runs match these filters.'}</p>` : html`
      <div class="overflow-x-auto"><table class="ss-table"><thead><tr>
        <th>Original run</th><th>Executor outcome</th><th>Recorded result · UTC</th><th>Executor duration</th><th>Keeper</th>
      </tr></thead><tbody>${visible.map(run => html`<tr key=${run.composition_run_id}
        aria-current=${result.composition?.composition_run_id === run.composition_run_id ? 'true' : undefined}>
        <td><button type="button" class="ss-btn mono text-3xs" onClick=${() => onSelect(run.composition_run_id)}>${run.composition_run_id}</button></td>
        <td>${run.disposition}</td><td>${recordedTime(run.recorded_at)}</td>
        <td>${run.duration_ms.toFixed(1)}ms</td><td>${run.keeper} · ${run.composition_execution}</td>
      </tr>`)}</tbody></table></div>`}
  </section>`
}
