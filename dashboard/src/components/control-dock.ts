// Control dock — room broadcast, keeper direct message, and Lodge poke controls.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  addTaskFromDashboard,
  joinDashboardAgent,
  leaveDashboardAgent,
  runOperatorAction,
  sendAgentHeartbeat,
  sendBroadcast,
} from '../api'
import {
  activeKeeperName,
  normalizeLodgeTickResult,
  selectKeeper,
} from '../keeper-runtime'
import { invalidateDashboardCache, keepers, refreshDashboard, serverStatus } from '../store'
import type { Keeper, LodgeRuntimeStatus, LodgeTickResult } from '../types'
import { showToast } from './common/toast'
import {
  KeeperConversationPanel,
  KeeperDiagnosticSummary,
  KeeperRuntimeActions,
} from './keeper-shared'

const AGENT_NAME_KEY = 'masc_dashboard_agent_name'

function defaultAgentName(): string {
  const q = new URLSearchParams(window.location.search)
  const fromQuery = q.get('agent') ?? q.get('agent_name')
  const fromStorage = localStorage.getItem(AGENT_NAME_KEY)
  return fromQuery ?? fromStorage ?? 'dashboard'
}

const agentName = signal(defaultAgentName())
const message = signal('')
const taskTitle = signal('')
const taskDesc = signal('')
const pokeResult = signal<LodgeTickResult | null>(null)
const pokeError = signal<string | null>(null)
const sending = signal(false)
const creatingTask = signal(false)
const joining = signal(false)
const leaving = signal(false)
const pinging = signal(false)
const poking = signal(false)
const joined = signal(false)

function formatHour(hour?: number | null): string {
  if (typeof hour !== 'number' || !Number.isFinite(hour)) return '??:00'
  return `${String(Math.max(0, hour)).padStart(2, '0')}:00`
}

function formatInterval(seconds?: number | null): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds <= 0) return 'unknown'
  if (seconds < 60) return `${Math.round(seconds)}s`
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.round((seconds % 3600) / 60)
  return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`
}

function formatActedNames(names?: string[]): string {
  if (!names || names.length === 0) return 'none'
  return names.join(', ')
}

function describeLodgeStatus(lodge: LodgeRuntimeStatus | null | undefined): string {
  if (!lodge) return 'Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state.'
  if (!lodge.enabled) return 'Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.'
  if (lodge.quiet_active) {
    return `Quiet hours ${formatHour(lodge.quiet_start)}-${formatHour(lodge.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`
  }
  if (lodge.last_tick_ago_s == null) {
    return `Lodge is enabled and scheduled every ${formatInterval(lodge.interval_s)}, but no tick has run yet in this runtime.`
  }
  if (lodge.last_skip_reason) {
    return `Lodge last skipped work because ${lodge.last_skip_reason}. Scheduled ticks still run every ${formatInterval(lodge.interval_s)}.`
  }
  return `Lodge ticks every ${formatInterval(lodge.interval_s)}. Planner is ${lodge.use_planner ? 'on' : 'off'} and delegated LLM is ${lodge.delegate_llm ? 'on' : 'off'}.`
}

async function refreshDashboardState(): Promise<void> {
  invalidateDashboardCache()
  try {
    await refreshDashboard()
  } catch (err) {
    console.warn('[control-dock] dashboard refresh failed', err)
  }
}

function persistAgentName(value: string): void {
  const v = value.trim()
  agentName.value = v
  if (v) localStorage.setItem(AGENT_NAME_KEY, v)
}

function parseJoinedAgentName(text: string): string | null {
  const line = text.split('\n').find(l => l.includes(' joined')) ?? text
  const m = line.match(/✅\s+(\S+)\s+joined/i)
  return m?.[1] ?? null
}

async function joinRoom() {
  const agent = agentName.value.trim()
  if (!agent) return
  joining.value = true
  try {
    const resText = await joinDashboardAgent(agent)
    const joinedName = parseJoinedAgentName(resText)
    if (joinedName) persistAgentName(joinedName)
    joined.value = true
    await refreshDashboardState()
    showToast(`Joined as ${joinedName ?? agent}`, 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to join room'
    showToast(msg, 'error')
  } finally {
    joining.value = false
  }
}

async function leaveRoom() {
  const agent = agentName.value.trim()
  if (!agent) return
  leaving.value = true
  try {
    await leaveDashboardAgent(agent)
    joined.value = false
    await refreshDashboardState()
    showToast(`Left room (${agent})`, 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to leave room'
    showToast(msg, 'error')
  } finally {
    leaving.value = false
  }
}

async function resetIdentity() {
  const prev = agentName.value.trim()
  if (prev) {
    try {
      await leaveDashboardAgent(prev)
    } catch {
      // Ignore leave failure while resetting identity.
    }
  }

  localStorage.removeItem(AGENT_NAME_KEY)
  persistAgentName('dashboard')
  joined.value = false
  await joinRoom()
}

async function pingHeartbeat() {
  const agent = agentName.value.trim()
  if (!agent) return
  pinging.value = true
  try {
    await sendAgentHeartbeat(agent)
    await refreshDashboardState()
    showToast('Heartbeat sent', 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to send heartbeat'
    showToast(msg, 'error')
  } finally {
    pinging.value = false
  }
}

async function submitBroadcast() {
  const agent = agentName.value.trim()
  const text = message.value.trim()
  if (!agent || !text) return
  sending.value = true
  try {
    await sendBroadcast(agent, text)
    message.value = ''
    await refreshDashboardState()
    showToast('Broadcast sent', 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to send broadcast'
    showToast(msg, 'error')
  } finally {
    sending.value = false
  }
}

async function submitTask() {
  const title = taskTitle.value.trim()
  const desc = taskDesc.value.trim() || 'Created from dashboard'
  if (!title) return
  creatingTask.value = true
  try {
    await addTaskFromDashboard(title, desc, 1)
    taskTitle.value = ''
    taskDesc.value = ''
    await refreshDashboardState()
    showToast('Task created', 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to create task'
    showToast(msg, 'error')
  } finally {
    creatingTask.value = false
  }
}

async function submitLodgePoke() {
  const actor = agentName.value.trim() || 'dashboard'
  poking.value = true
  pokeError.value = null
  try {
    const response = await runOperatorAction({
      actor,
      action_type: 'lodge_tick',
      target_type: 'room',
      payload: {},
    })
    const normalized = normalizeLodgeTickResult(response.result)
    pokeResult.value = normalized
    await refreshDashboardState()
    if (normalized?.skipped_reason) {
      showToast(normalized.skipped_reason, 'warning')
    } else {
      showToast(
        normalized ? `Poke finished: ${normalized.acted}/${normalized.checked} acted` : 'Poke finished',
        normalized && normalized.acted > 0 ? 'success' : 'warning',
      )
    }
  } catch (err) {
    const text = err instanceof Error ? err.message : 'Failed to run Lodge poke'
    pokeError.value = text
    showToast(text, 'error')
  } finally {
    poking.value = false
  }
}

function LodgeResultBox({ runtime }: { runtime: LodgeRuntimeStatus | null | undefined }) {
  const result = pokeResult.value ?? runtime?.last_tick_result ?? null
  if (pokeError.value) {
    return html`<div class="control-result-box is-error">${pokeError.value}</div>`
  }
  if (!result) {
    return html`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`
  }

  const topSkips = result.skipped_rows?.slice(0, 3) ?? []
  const topPasses = result.passed_rows?.slice(0, 3) ?? []

  return html`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${result.checked} checked</span>
        <span class="pill">${result.acted} acted</span>
        ${result.quiet_hours_overridden ? html`<span class="pill">quiet hours bypassed</span>` : null}
      </div>
      <div class="control-status-copy">Last acted: ${formatActedNames(result.acted_names)}</div>
      ${result.skipped_reason ? html`<div class="control-status-copy">${result.skipped_reason}</div>` : null}
      ${result.activity_report ? html`<pre class="control-transcript-text">${result.activity_report}</pre>` : null}
      ${topSkips.length > 0
        ? html`
            <div class="control-result-list">
              ${topSkips.map(row => html`<div>${row.name}: ${row.reason ?? 'skipped'}</div>`)}
            </div>
          `
        : null}
      ${topPasses.length > 0
        ? html`
            <div class="control-result-list">
              ${topPasses.map(row => html`<div>${row.name}: ${row.reason ?? 'passed'}</div>`)}
            </div>
          `
        : null}
    </div>
  `
}

function currentKeeperSelection(keeperOptions: Keeper[]): Keeper | null {
  const byActive = keeperOptions.find(keeper => keeper.name === activeKeeperName.value)
  return byActive ?? keeperOptions[0] ?? null
}

export function ControlDock() {
  const keeperOptions = keepers.value
  const lodge = serverStatus.value?.lodge ?? null
  const selectedKeeper = currentKeeperSelection(keeperOptions)

  useEffect(() => {
    void joinRoom()
  }, [])

  useEffect(() => {
    const firstKeeper = keeperOptions[0]?.name ?? ''
    if (!activeKeeperName.value && firstKeeper) {
      selectKeeper(firstKeeper)
      return
    }
    if (activeKeeperName.value && !keeperOptions.some(keeper => keeper.name === activeKeeperName.value)) {
      selectKeeper(firstKeeper)
    }
  }, [keeperOptions.map(keeper => keeper.name).join('|')])

  return html`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Identity</h4>
          <p class="control-help">Broadcasts and operator actions use this agent name.</p>
        </div>

        <label class="control-label" for="dock-agent">Agent</label>
        <input
          id="dock-agent"
          class="control-input"
          type="text"
          value=${agentName.value}
          onInput=${(e: Event) => persistAgentName((e.target as HTMLInputElement).value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${() => { void joinRoom() }}
            disabled=${joining.value || agentName.value.trim() === ''}
          >
            ${joining.value ? 'Joining...' : joined.value ? 'Rejoin' : 'Join'}
          </button>
          <button
            class="control-btn ghost"
            onClick=${() => { void leaveRoom() }}
            disabled=${leaving.value || agentName.value.trim() === ''}
          >
            ${leaving.value ? 'Leaving...' : 'Leave'}
          </button>
          <button
            class="control-btn ghost"
            onClick=${() => { void resetIdentity() }}
            disabled=${joining.value || leaving.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${() => { void pingHeartbeat() }}
            disabled=${pinging.value || agentName.value.trim() === ''}
          >
            ${pinging.value ? 'Pinging...' : 'Heartbeat'}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Broadcast</h4>
          <p class="control-help">This is visible to the room and other agents. Use it for announcements, nudges, and @mentions, not private keeper prompts.</p>
        </div>

        <label class="control-label" for="dock-message">Broadcast</label>
        <div class="control-row">
          <input
            id="dock-message"
            class="control-input"
            type="text"
            placeholder="@agent or room-wide update"
            value=${message.value}
            onInput=${(e: Event) => { message.value = (e.target as HTMLInputElement).value }}
            onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitBroadcast() }}
            disabled=${sending.value}
          />
          <button
            class="control-btn"
            onClick=${() => { void submitBroadcast() }}
            disabled=${sending.value || message.value.trim() === '' || agentName.value.trim() === ''}
          >
            ${sending.value ? 'Sending...' : 'Send'}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Keeper Direct Message</h4>
          <p class="control-help">This sends a 1:1 message through <code>masc_keeper_msg</code> and keeps the actual reply thread in the dock so you can see whether the keeper answered.</p>
        </div>

        <label class="control-label" for="dock-keeper">Keeper</label>
        <select
          id="dock-keeper"
          class="control-input"
          value=${selectedKeeper?.name ?? ''}
          onInput=${(e: Event) => { selectKeeper((e.target as HTMLSelectElement).value) }}
          disabled=${keeperOptions.length === 0}
        >
          ${keeperOptions.length === 0
            ? html`<option value="">No keepers available</option>`
            : keeperOptions.map(keeper => html`<option value=${keeper.name}>${keeper.name}</option>`)}
        </select>

        <${KeeperDiagnosticSummary} keeper=${selectedKeeper} />
        <${KeeperRuntimeActions}
          actor=${agentName.value.trim() || 'dashboard'}
          keeper=${selectedKeeper}
          onPokeLodge=${() => { void submitLodgePoke() }}
        />
        <${KeeperConversationPanel}
          keeperName=${selectedKeeper?.name ?? ''}
          placeholder=${keeperOptions.length === 0 ? 'No keeper is active yet' : 'Direct prompt for the selected keeper'}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${describeLodgeStatus(lodge)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${lodge?.enabled ? 'enabled' : 'disabled'}</span>
          <span class="pill">every ${formatInterval(lodge?.interval_s)}</span>
          <span class="pill">quiet ${formatHour(lodge?.quiet_start)}-${formatHour(lodge?.quiet_end)} KST</span>
          <span class="pill">${lodge?.quiet_active ? 'quiet active' : 'quiet inactive'}</span>
          <span class="pill">${lodge?.use_planner ? 'planner on' : 'planner off'}</span>
          <span class="pill">${lodge?.delegate_llm ? 'delegate llm on' : 'delegate llm off'}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${lodge?.last_tick_ago ?? 'never'} · Total ticks: ${lodge?.total_ticks ?? 0} · Last acted: ${formatActedNames(lodge?.last_tick_result?.acted_names)}
        </div>
        ${lodge?.last_skip_reason
          ? html`<div class="control-status-copy">Last skip reason: ${lodge.last_skip_reason}</div>`
          : null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${() => { void submitLodgePoke() }}
            disabled=${poking.value}
          >
            ${poking.value ? 'Poking...' : 'Poke Now'}
          </button>
        </div>

        <${LodgeResultBox} runtime=${lodge} />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Quick Task</h4>
          <p class="control-help">Fast backlog injection for local follow-up work.</p>
        </div>

        <input
          id="dock-task"
          class="control-input"
          type="text"
          placeholder="Task title"
          value=${taskTitle.value}
          onInput=${(e: Event) => { taskTitle.value = (e.target as HTMLInputElement).value }}
          disabled=${creatingTask.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${taskDesc.value}
          onInput=${(e: Event) => { taskDesc.value = (e.target as HTMLTextAreaElement).value }}
          disabled=${creatingTask.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${() => { void submitTask() }}
          disabled=${creatingTask.value || taskTitle.value.trim() === ''}
        >
          ${creatingTask.value ? 'Creating...' : 'Create Task'}
        </button>
      </div>
    </section>
  `
}
