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
  sendKeeperMessage,
} from '../api'
import { invalidateDashboardCache, keepers, refreshDashboard, serverStatus } from '../store'
import type { LodgeCheckinResult, LodgeRuntimeStatus, LodgeTickResult } from '../types'
import { showToast } from './common/toast'

const AGENT_NAME_KEY = 'masc_dashboard_agent_name'

type KeeperTranscript = {
  keeper: string
  prompt: string
  reply: string
  isError: boolean
  at: string
}

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
const selectedKeeperName = signal('')
const keeperPrompt = signal('')
const keeperTranscript = signal<KeeperTranscript | null>(null)
const pokeResult = signal<LodgeTickResult | null>(null)
const pokeError = signal<string | null>(null)
const sending = signal(false)
const creatingTask = signal(false)
const joining = signal(false)
const leaving = signal(false)
const pinging = signal(false)
const keeperSending = signal(false)
const poking = signal(false)
const joined = signal(false)

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === 'boolean' ? value : undefined
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => asString(item))
    .filter((item): item is string => Boolean(item))
}

function normalizeCheckin(raw: unknown): LodgeCheckinResult | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    trigger: asString(raw.trigger),
    outcome: asString(raw.outcome),
    summary: asString(raw.summary),
    reason: asString(raw.reason),
  }
}

function normalizeNameRows(raw: unknown, key: 'summary' | 'reason'): Array<{ name: string; summary?: string; reason?: string }> {
  if (!Array.isArray(raw)) return []
  const rows: Array<{ name: string; summary?: string; reason?: string }> = []
  for (const item of raw) {
    if (!isRecord(item)) continue
    const name = asString(item.name)
    if (!name) continue
    const detail = asString(item[key])
    if (key === 'summary') rows.push({ name, summary: detail })
    else rows.push({ name, reason: detail })
  }
  return rows
}

function normalizeLodgeTickResult(raw: unknown): LodgeTickResult | null {
  if (!isRecord(raw)) return null
  return {
    hour: asNumber(raw.hour),
    checked: asNumber(raw.checked) ?? 0,
    acted: asNumber(raw.acted) ?? 0,
    acted_names: asStringArray(raw.acted_names),
    activity_report: asString(raw.activity_report),
    quiet_hours_overridden: asBoolean(raw.quiet_hours_overridden),
    skipped_reason: asString(raw.skipped_reason),
    acted_rows: normalizeNameRows(raw.acted_rows, 'summary').map(row => ({ name: row.name, summary: row.summary })),
    passed_rows: normalizeNameRows(raw.passed_rows, 'reason').map(row => ({ name: row.name, reason: row.reason })),
    skipped_rows: normalizeNameRows(raw.skipped_rows, 'reason').map(row => ({ name: row.name, reason: row.reason })),
    checkins: Array.isArray(raw.checkins)
      ? raw.checkins.map(normalizeCheckin).filter((row): row is LodgeCheckinResult => row !== null)
      : [],
  }
}

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

async function submitKeeperDirectMessage() {
  const keeper = selectedKeeperName.value.trim()
  const prompt = keeperPrompt.value.trim()
  if (!keeper) {
    showToast('Select a keeper first', 'warning')
    return
  }
  if (!prompt) return
  keeperSending.value = true
  try {
    const reply = await sendKeeperMessage(keeper, prompt)
    keeperTranscript.value = {
      keeper,
      prompt,
      reply: reply.trim() || '(empty reply)',
      isError: false,
      at: new Date().toISOString(),
    }
    keeperPrompt.value = ''
    await refreshDashboardState()
    showToast(`Reply received from ${keeper}`, 'success')
  } catch (err) {
    const message =
      err instanceof Error ? err.message : `Failed to send direct message to ${keeper}`
    keeperTranscript.value = {
      keeper,
      prompt,
      reply: message,
      isError: true,
      at: new Date().toISOString(),
    }
    showToast(message, 'error')
  } finally {
    keeperSending.value = false
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
    const message = err instanceof Error ? err.message : 'Failed to run Lodge poke'
    pokeError.value = message
    showToast(message, 'error')
  } finally {
    poking.value = false
  }
}

function KeeperTranscriptBox() {
  const transcript = keeperTranscript.value
  if (!transcript) {
    return html`<div class="control-status-copy">No direct keeper response yet.</div>`
  }

  return html`
    <div class=${`control-transcript ${transcript.isError ? 'is-error' : 'is-success'}`}>
      <div class="control-transcript-meta">
        <span>Keeper: ${transcript.keeper}</span>
        <span>${new Date(transcript.at).toLocaleTimeString()}</span>
      </div>
      <div class="control-transcript-label">Prompt</div>
      <pre class="control-transcript-text">${transcript.prompt}</pre>
      <div class="control-transcript-label">${transcript.isError ? 'Error' : 'Reply'}</div>
      <pre class="control-transcript-text">${transcript.reply}</pre>
    </div>
  `
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
      <div class="control-status-copy">
        Last acted: ${formatActedNames(result.acted_names)}
      </div>
      ${result.skipped_reason
        ? html`<div class="control-status-copy">${result.skipped_reason}</div>`
        : null}
      ${result.activity_report
        ? html`<pre class="control-transcript-text">${result.activity_report}</pre>`
        : null}
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

export function ControlDock() {
  const keeperOptions = keepers.value.map(keeper => keeper.name)
  const lodge = serverStatus.value?.lodge ?? null

  useEffect(() => {
    void joinRoom()
  }, [])

  useEffect(() => {
    const firstKeeper = keeperOptions[0] ?? ''
    if (!selectedKeeperName.value && firstKeeper) {
      selectedKeeperName.value = firstKeeper
      return
    }
    if (selectedKeeperName.value && !keeperOptions.includes(selectedKeeperName.value)) {
      selectedKeeperName.value = firstKeeper
    }
  }, [keeperOptions.join('|')])

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
            onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') submitBroadcast() }}
            disabled=${sending.value}
          />
          <button
            class="control-btn"
            onClick=${submitBroadcast}
            disabled=${sending.value || message.value.trim() === '' || agentName.value.trim() === ''}
          >
            ${sending.value ? 'Sending...' : 'Send'}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Keeper Direct Message</h4>
          <p class="control-help">This sends a 1:1 message through <code>masc_keeper_msg</code> and keeps the actual reply in the dock so you can see whether the keeper answered.</p>
        </div>

        <label class="control-label" for="dock-keeper">Keeper</label>
        <select
          id="dock-keeper"
          class="control-input"
          value=${selectedKeeperName.value}
          onInput=${(e: Event) => { selectedKeeperName.value = (e.target as HTMLSelectElement).value }}
          disabled=${keeperOptions.length === 0 || keeperSending.value}
        >
          ${keeperOptions.length === 0
            ? html`<option value="">No keepers available</option>`
            : keeperOptions.map(name => html`<option value=${name}>${name}</option>`)}
        </select>

        <textarea
          class="control-textarea"
          placeholder=${keeperOptions.length === 0 ? 'No keeper is active yet' : 'Direct prompt for the selected keeper'}
          value=${keeperPrompt.value}
          onInput=${(e: Event) => { keeperPrompt.value = (e.target as HTMLTextAreaElement).value }}
          disabled=${keeperOptions.length === 0 || keeperSending.value}
        ></textarea>

        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${() => { void submitKeeperDirectMessage() }}
            disabled=${keeperSending.value || keeperPrompt.value.trim() === '' || selectedKeeperName.value.trim() === ''}
          >
            ${keeperSending.value ? 'Waiting...' : 'Send Direct Message'}
          </button>
        </div>

        <${KeeperTranscriptBox} />
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
          onClick=${submitTask}
          disabled=${creatingTask.value || taskTitle.value.trim() === ''}
        >
          ${creatingTask.value ? 'Creating...' : 'Create Task'}
        </button>
      </div>
    </section>
  `
}
