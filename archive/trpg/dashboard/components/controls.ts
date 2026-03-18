// TRPG controls — Interactive control panels for game management

import { html } from 'htm/preact'
import { Card } from '../common/card'
import { showToast } from '../common/toast'
import { trpgRoom, refreshTrpg } from '../../store'
import {
  runTrpgRound,
  rollTrpgDice,
  advanceTrpgTurn,
  spawnTrpgActor,
  claimTrpgActor,
  fetchTrpgJoinEligibility,
  requestTrpgMidJoin,
} from '../../api'
import type { TrpgState, TrpgEvent } from '../../types'
import {
  selectedActorId,
  diceAction,
  diceStatValue,
  diceDc,
  diceRawD20,
  runStatus,
  lastRoundRun,
  joinActorId,
  joinKeeper,
  joinRole,
  joinActorName,
  joinStatus,
  joinEligibility,
  spawnActorId,
  spawnActorName,
  spawnRole,
  spawnKeeper,
  spawnPortrait,
  spawnBackground,
  spawnHp,
  spawnMaxHp,
  spawnStatsJson,
  spawnStatus,
  ensureUnlocked,
  confirmRiskAction,
  relockControl,
  isControlLocked,
  controlRemainingSeconds,
  unlockControl,
  isRecord,
  recString,
  recNumber,
  recBool,
  parseSpawnStats,
  clampSpawnHpToMax,
} from './helpers'

export function ControlBox({ state, nowMs }: { state: TrpgState; nowMs: number }) {
  const room = trpgRoom.value || state.session?.room || ''
  const status = runStatus.value
  const actors = state.party ?? []
  const selectedActor = actors.find(a => a.id === selectedActorId.value)
  if (!selectedActor && actors.length > 0) {
    const firstActor = actors[0]
    if (firstActor) selectedActorId.value = firstActor.id
  }

  const handleRunRound = async () => {
    if (!room) { showToast('Room ID가 비어 있습니다.', 'error'); return }
    if (!ensureUnlocked(nowMs)) return
    const phase = state.current_round?.phase ?? state.session?.status ?? 'unknown'
    if (!confirmRiskAction('라운드 실행', room, phase)) return
    runStatus.value = 'running'
    try {
      const result = await runTrpgRound(room)
      lastRoundRun.value = result
      runStatus.value = 'ok'
      const summary = isRecord(result.summary) ? result.summary : null
      const advanced = summary ? recBool(summary, 'advanced', false) : false
      const reason = summary ? recString(summary, 'progress_reason', '') : ''
      showToast(
        advanced ? '라운드가 정상 진행되었습니다.' : `라운드가 정체되었습니다${reason ? `: ${reason}` : ''}`,
        advanced ? 'success' : 'warning',
      )
      refreshTrpg()
    } catch (err) {
      lastRoundRun.value = null
      runStatus.value = 'error'
      const message = err instanceof Error ? err.message : '라운드 실행에 실패했습니다.'
      showToast(message, 'error')
    } finally {
      relockControl()
    }
  }

  const handleAdvanceTurn = async () => {
    if (!room) return
    if (!ensureUnlocked(nowMs)) return
    const phase = state.current_round?.phase ?? state.session?.status ?? 'unknown'
    if (!confirmRiskAction('턴 강제 진행', room, phase)) return
    try {
      await advanceTrpgTurn(room)
      showToast('턴을 다음 단계로 이동했습니다.', 'success')
      refreshTrpg()
    } catch {
      showToast('턴 이동에 실패했습니다.', 'error')
    } finally {
      relockControl()
    }
  }

  const handleRollDice = async () => {
    if (!room) return
    if (!ensureUnlocked(nowMs)) return
    const actorId = selectedActorId.value.trim()
    if (!actorId) {
      showToast('먼저 Actor를 선택하세요.', 'warning')
      return
    }
    const statValue = Number.parseInt(diceStatValue.value, 10)
    const dc = Number.parseInt(diceDc.value, 10)
    if (Number.isNaN(statValue) || Number.isNaN(dc)) {
      showToast('stat/dc는 숫자여야 합니다.', 'warning')
      return
    }
    const rawParsed = Number.parseInt(diceRawD20.value, 10)
    const rawD20 = diceRawD20.value.trim() === '' || Number.isNaN(rawParsed)
      ? undefined
      : rawParsed
    try {
      await rollTrpgDice({
        roomId: room,
        actorId,
        action: diceAction.value.trim() || 'ability_check',
        statValue,
        dc,
        rawD20,
      })
      showToast('주사위 판정을 기록했습니다.', 'success')
      refreshTrpg()
    } catch {
      showToast('주사위 판정 기록에 실패했습니다.', 'error')
    }
  }

  return html`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${room}
            onInput=${(e: Event) => { trpgRoom.value = (e.target as HTMLInputElement).value }}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${selectedActorId.value}
            onChange=${(e: Event) => { selectedActorId.value = (e.target as HTMLSelectElement).value }}
          >
            <option value="">Actor 선택</option>
            ${actors.map(a => html`<option value=${a.id}>${a.name} (${a.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${diceAction.value}
              onInput=${(e: Event) => { diceAction.value = (e.target as HTMLInputElement).value }}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${diceStatValue.value}
              onInput=${(e: Event) => { diceStatValue.value = (e.target as HTMLInputElement).value }}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${diceDc.value}
              onInput=${(e: Event) => { diceDc.value = (e.target as HTMLInputElement).value }}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${diceRawD20.value}
              onInput=${(e: Event) => { diceRawD20.value = (e.target as HTMLInputElement).value }}
              onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') handleRollDice() }}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${handleRollDice}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${handleRunRound}
              disabled=${status === 'running'}
            >
              ${status === 'running' ? '실행 중...' : 'Run Round'}
            </button>
            <button class="trpg-run-btn secondary" onClick=${handleAdvanceTurn}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${status !== 'idle'
        ? html`<div class="trpg-run-status ${status}">${status === 'running' ? '처리 중...' : status === 'ok' ? '완료' : '실패'}</div>`
        : null}
    </div>
  `
}

export function ActorSpawnPanel({ state }: { state: TrpgState }) {
  const room = trpgRoom.value || state.session?.room || ''
  const status = spawnStatus.value

  const handleSpawnActor = async () => {
    if (!room) {
      showToast('Room ID가 비어 있습니다.', 'warning')
      return
    }

    const actorIdInput = spawnActorId.value.trim()
    const name = spawnActorName.value.trim()
    if (!name && !actorIdInput) {
      showToast('이름 또는 Actor ID를 입력하세요.', 'warning')
      return
    }

    const hpRaw = Number.parseInt(spawnHp.value.trim(), 10)
    const maxHpRaw = Number.parseInt(spawnMaxHp.value.trim(), 10)
    const maxHp = Number.isFinite(maxHpRaw) ? Math.max(1, maxHpRaw) : 20
    const hp = Number.isFinite(hpRaw) ? Math.max(0, Math.min(maxHp, hpRaw)) : maxHp

    let stats: Record<string, number> = {}
    try {
      stats = parseSpawnStats(spawnStatsJson.value)
    } catch (err) {
      showToast(err instanceof Error ? err.message : '능력치 JSON 오류', 'error')
      return
    }

    spawnStatus.value = 'spawning'
    try {
      const idempotencyKey =
        typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
          ? `trpg_spawn_${crypto.randomUUID()}`
          : `trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`
      const spawnRes = await spawnTrpgActor(room, {
        actor_id: actorIdInput || undefined,
        name: name || undefined,
        role: spawnRole.value,
        idempotencyKey,
        portrait: spawnPortrait.value.trim() || undefined,
        background: spawnBackground.value.trim() || undefined,
        hp,
        max_hp: maxHp,
        alive: hp > 0,
        stats: Object.keys(stats).length > 0 ? stats : undefined,
      })
      const actorId = typeof spawnRes.actor_id === 'string' ? spawnRes.actor_id.trim() : ''
      if (!actorId) {
        throw new Error('생성 응답에 actor_id가 없습니다.')
      }

      const keeper = spawnKeeper.value.trim()
      if (keeper) {
        await claimTrpgActor(room, actorId, keeper)
      }

      selectedActorId.value = actorId
      joinActorId.value = actorId
      if (!actorIdInput) spawnActorId.value = ''
      spawnStatus.value = 'ok'
      showToast(`Actor 생성 완료: ${actorId}`, 'success')
      await refreshTrpg()
    } catch (err) {
      spawnStatus.value = 'error'
      showToast(err instanceof Error ? err.message : 'Actor 생성에 실패했습니다.', 'error')
    }
  }

  return html`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${spawnActorName.value}
            onInput=${(e: Event) => { spawnActorName.value = (e.target as HTMLInputElement).value }}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${spawnRole.value}
            onChange=${(e: Event) => { spawnRole.value = (e.target as HTMLSelectElement).value as 'player' | 'npc' | 'dm' }}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Keeper (optional)</label>
          <input
            id="trpg-spawn-keeper-input"
            name="trpg-spawn-keeper-input"
            type="text"
            value=${spawnKeeper.value}
            onInput=${(e: Event) => { spawnKeeper.value = (e.target as HTMLInputElement).value }}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${handleSpawnActor} disabled=${status === 'spawning'}>
              ${status === 'spawning' ? 'Spawning...' : 'Spawn Actor'}
            </button>
          </div>
        </div>
      </div>

      <details class="trpg-control-details">
        <summary>상세 입력 (선택)</summary>
        <div class="trpg-control-grid">
          <div class="trpg-control-field">
            <label>Actor ID (optional)</label>
            <input
              id="trpg-spawn-actor-id-input"
              name="trpg-spawn-actor-id-input"
              type="text"
              value=${spawnActorId.value}
              onInput=${(e: Event) => { spawnActorId.value = (e.target as HTMLInputElement).value }}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${spawnPortrait.value}
              onInput=${(e: Event) => { spawnPortrait.value = (e.target as HTMLInputElement).value }}
              placeholder="https://.../portrait.png"
            />
          </div>
          <div class="trpg-control-field">
            <label>HP</label>
            <input
              id="trpg-spawn-hp-input"
              name="trpg-spawn-hp-input"
              type="number"
              min="0"
              value=${spawnHp.value}
              onInput=${(e: Event) => { spawnHp.value = (e.target as HTMLInputElement).value }}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field">
            <label>Max HP</label>
            <input
              id="trpg-spawn-max-hp-input"
              name="trpg-spawn-max-hp-input"
              type="number"
              min="1"
              value=${spawnMaxHp.value}
              onInput=${(e: Event) => {
                const nextValue = (e.target as HTMLInputElement).value
                spawnMaxHp.value = nextValue
                clampSpawnHpToMax(nextValue)
              }}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${spawnBackground.value}
              onInput=${(e: Event) => { spawnBackground.value = (e.target as HTMLInputElement).value }}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${spawnStatsJson.value}
              onInput=${(e: Event) => { spawnStatsJson.value = (e.target as HTMLInputElement).value }}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${status !== 'idle'
        ? html`<div class="trpg-run-status ${status === 'spawning' ? 'running' : status}">${status === 'spawning' ? '생성 중...' : status === 'ok' ? '생성 완료' : '생성 실패'}</div>`
        : null}
    </div>
  `
}

export function JoinGatePanel({ state, nowMs }: { state: TrpgState; nowMs: number }) {
  const room = trpgRoom.value || state.session?.room || ''
  const gate = state.join_gate
  const eligibilityRaw = joinEligibility.value
  const eligibility = isRecord(eligibilityRaw) ? eligibilityRaw : null
  const joinCandidates = (state.party ?? []).filter(actor => actor.role !== 'dm')
  const selectedJoinActorId = joinActorId.value.trim()
  const hasJoinCandidate = joinCandidates.some(actor => actor.id === selectedJoinActorId)
  const joinActorSelectValue = hasJoinCandidate
    ? selectedJoinActorId
    : (selectedJoinActorId ? '__manual__' : '')

  const checkEligibility = async () => {
    const actorId = joinActorId.value.trim()
    const keeper = joinKeeper.value.trim()
    if (!room || !actorId) {
      showToast('Room/Actor가 필요합니다.', 'warning')
      return
    }
    joinStatus.value = 'checking'
    try {
      const res = await fetchTrpgJoinEligibility(room, actorId, keeper || undefined)
      joinEligibility.value = res as unknown as Record<string, unknown>
      joinStatus.value = 'ok'
      showToast('참가 가능 여부를 갱신했습니다.', 'success')
    } catch (err) {
      joinStatus.value = 'error'
      const message = err instanceof Error ? err.message : '참가 가능 여부 확인에 실패했습니다.'
      showToast(message, 'error')
    }
  }

  const requestMidJoin = async () => {
    const actorId = joinActorId.value.trim()
    const keeper = joinKeeper.value.trim()
    const name = joinActorName.value.trim()
    if (!room || !actorId || !keeper) {
      showToast('Room/Actor/Keeper가 필요합니다.', 'warning')
      return
    }
    if (!ensureUnlocked(nowMs)) return
    const phase = state.current_round?.phase ?? state.session?.status ?? 'unknown'
    if (!confirmRiskAction('Mid-Join 승인 요청', room, phase)) return
    joinStatus.value = 'requesting'
    try {
      const result = await requestTrpgMidJoin({
        room_id: room,
        actor_id: actorId,
        keeper_name: keeper,
        role: joinRole.value,
        ...(name ? { name } : {}),
      })
      joinEligibility.value = result
      const granted = isRecord(result) ? recBool(result, 'granted', false) : false
      const reasonCode = isRecord(result) ? recString(result, 'reason_code', '') : ''
      if (granted) {
        showToast('Mid-Join이 승인되었습니다.', 'success')
      } else {
        showToast(`Mid-Join이 거절되었습니다${reasonCode ? `: ${reasonCode}` : ''}`, 'warning')
      }
      joinStatus.value = granted ? 'ok' : 'error'
      refreshTrpg()
    } catch (err) {
      joinStatus.value = 'error'
      const message = err instanceof Error ? err.message : 'Mid-Join 요청에 실패했습니다.'
      showToast(message, 'error')
    } finally {
      relockControl()
    }
  }

  return html`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${gate?.phase_open ? 'OPEN' : 'CLOSED'}</strong>
        ${gate?.window ? html`<span style="margin-left:8px;">(${gate.window})</span>` : null}
        <span style="margin-left:8px;">Required: ${gate?.min_points ?? 3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${joinActorSelectValue}
            onChange=${(e: Event) => {
              const value = (e.target as HTMLSelectElement).value
              if (value === '__manual__') {
                if (hasJoinCandidate || !selectedJoinActorId) joinActorId.value = ''
                return
              }
              joinActorId.value = value
            }}
          >
            <option value="">Actor 선택</option>
            ${joinCandidates.map(actor => html`
              <option value=${actor.id}>${actor.name} (${actor.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${joinActorSelectValue === '__manual__'
            ? html`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${joinActorId.value}
                onInput=${(e: Event) => { joinActorId.value = (e.target as HTMLInputElement).value }}
                placeholder="player-xyz"
                style="margin-top:6px;"
              />
            `
            : null}
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${joinKeeper.value}
            onInput=${(e: Event) => { joinKeeper.value = (e.target as HTMLInputElement).value }}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${joinRole.value}
            onChange=${(e: Event) => { joinRole.value = (e.target as HTMLSelectElement).value as 'player' | 'npc' | 'dm' }}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Name (optional)</label>
          <input
            id="trpg-join-name-input"
            name="trpg-join-name-input"
            type="text"
            value=${joinActorName.value}
            onInput=${(e: Event) => { joinActorName.value = (e.target as HTMLInputElement).value }}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${checkEligibility} disabled=${joinStatus.value === 'checking' || joinStatus.value === 'requesting'}>
              ${joinStatus.value === 'checking' ? 'Checking...' : 'Check'}
            </button>
            <button class="trpg-run-btn recommend" onClick=${requestMidJoin} disabled=${joinStatus.value === 'checking' || joinStatus.value === 'requesting'}>
              ${joinStatus.value === 'requesting' ? 'Requesting...' : 'Request Join'}
            </button>
          </div>
        </div>
      </div>
      ${eligibility
        ? html`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${recBool(eligibility, 'eligible', false) ? 'YES' : 'NO'}</strong>
            <span style="margin-left:8px;">Score ${recNumber(eligibility, 'effective_score', 0)}/${recNumber(eligibility, 'required_points', 0)}</span>
            ${recString(eligibility, 'reason_code', '') ? html`<span style="margin-left:8px;">Reason: ${recString(eligibility, 'reason_code', '')}</span>` : null}
          </div>
        `
        : null}
    </div>
  `
}

export function ContributionLedger({ state }: { state: TrpgState }) {
  const rows = [...(state.contribution_ledger ?? [])]
    .sort((a, b) => (b.score ?? 0) - (a.score ?? 0))
    .slice(0, 8)
  if (rows.length === 0) {
    return html`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`
  }
  return html`
    <div class="trpg-round-list">
      ${rows.map(row => html`
        <div class="trpg-round-item active">
          <span>${row.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${row.score}</span>
          ${row.last_reason
            ? html`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${row.last_reason}</div>`
            : null}
        </div>
      `)}
    </div>
  `
}

export function NextAction({ state }: { state: TrpgState }) {
  const round = state.current_round
  if (!round) return null

  return html`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${round.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${round.phase}</div>
      ${round.events.length > 0
        ? html`<div class="trpg-next-action-target">
            Last: ${(round.events[round.events.length - 1] as TrpgEvent).content?.slice(0, 80)}
          </div>`
        : null}
    </div>
  `
}

export function RoundRunInsight() {
  const result = lastRoundRun.value
  if (!result) {
    return html`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`
  }

  const summaryRaw = result.summary
  const summary = isRecord(summaryRaw) ? summaryRaw : null
  const statusesRaw = Array.isArray(result.statuses) ? result.statuses : []
  const statuses = statusesRaw.filter(isRecord).slice(-8)
  const canonRaw = result.canon_check
  const canon = isRecord(canonRaw) ? canonRaw : null
  const canonWarnings = canon && Array.isArray(canon.warnings)
    ? canon.warnings.filter((w): w is string => typeof w === 'string').slice(0, 3)
    : []
  const canonViolations = canon && Array.isArray(canon.violations)
    ? canon.violations.filter((v): v is string => typeof v === 'string').slice(0, 3)
    : []

  const advanced = summary ? recBool(summary, 'advanced', false) : false
  const progressReason = summary ? recString(summary, 'progress_reason', '') : ''
  const progressDetail = summary ? recString(summary, 'progress_detail', '') : ''
  const playerSuccess = summary ? recNumber(summary, 'player_successes', 0) : 0
  const playerRequired = summary ? recNumber(summary, 'player_required_successes', 0) : 0
  const dmSuccess = summary ? recBool(summary, 'dm_success', false) : false
  const timeouts = summary ? recNumber(summary, 'timeouts', 0) : 0
  const unavailable = summary ? recNumber(summary, 'unavailable', 0) : 0
  const reprompts = summary ? recNumber(summary, 'reprompts', 0) : 0
  const npcAttacks = summary ? recNumber(summary, 'npc_attacks', 0) : 0
  const keeperTimeout = summary ? recNumber(summary, 'keeper_timeout_sec', 0) : 0
  const rollAudit = summary ? recNumber(summary, 'roll_audit_count', 0) : 0

  return html`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${advanced ? 'active' : 'failed'}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${advanced ? 'ADVANCED' : 'STALLED'}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${result.turn_before ?? 0} → ${result.turn_after ?? 0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${dmSuccess ? 'DM ok' : 'DM stalled'} / players ${playerSuccess}/${playerRequired}
          </span>
        </div>
        ${progressReason
          ? html`<div style="margin-top:4px; font-size:12px;">${progressReason}</div>`
          : null}
        ${progressDetail
          ? html`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${progressDetail}</div>`
          : null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${timeouts}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${unavailable}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${reprompts}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${npcAttacks}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${keeperTimeout || 0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${rollAudit}</div></div>
      </div>

      ${statuses.length > 0
        ? html`
          <div class="trpg-round-list">
            ${statuses.map(s => {
              const status = recString(s, 'status', 'unknown')
              const actorId = recString(s, 'actor_id', '-')
              const role = recString(s, 'role', '-')
              const reason = recString(s, 'reason', '')
              const actionType = recString(s, 'action_type', '')
              const reply = recString(s, 'reply', '')
              return html`
                <div class="trpg-round-item ${status.includes('fallback') || status.includes('timeout') ? 'failed' : 'active'}">
                  <span>${actorId} (${role})</span>
                  <span style="margin-left:auto; font-size:11px;">${status}</span>
                  ${actionType ? html`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${actionType}</div>` : null}
                  ${reason ? html`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${reason}</div>` : null}
                  ${reply ? html`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${reply.slice(0, 120)}</div>` : null}
                </div>
              `
            })}
          </div>`
        : null}

      ${canon
        ? html`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${recString(canon, 'status', 'unknown')}</strong>
            </div>
            ${canonViolations.length > 0
              ? html`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${canonViolations.map(v => html`<div>violation: ${v}</div>`)}
                </div>`
              : null}
            ${canonWarnings.length > 0
              ? html`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${canonWarnings.map(w => html`<div>warning: ${w}</div>`)}
                </div>`
              : null}
          </div>
        `
        : null}
    </div>
  `
}

export function ControlSafetyPanel({ state, nowMs }: { state: TrpgState; nowMs: number }) {
  const room = trpgRoom.value || state.session?.room || ''
  const phase = state.current_round?.phase ?? state.session?.status ?? 'unknown'
  const locked = isControlLocked(nowMs)
  const remains = controlRemainingSeconds(nowMs)

  return html`
    <${Card} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${locked ? 'locked' : 'unlocked'}">
        <div class="trpg-control-lock-title">
          ${locked ? '잠금 상태: 관전 전용' : '잠금 해제됨'}
        </div>
        <div class="trpg-control-lock-desc">
          ${locked
            ? '조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.'
            : `위험 액션 실행 또는 ${remains}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${room || '-'} · phase: ${phase || '-'}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${locked
            ? html`<button class="trpg-run-btn recommend" onClick=${() => unlockControl(room, phase)}>잠금 해제 (120초)</button>`
            : html`<button class="trpg-run-btn secondary" onClick=${() => { relockControl(); showToast('조작 잠금으로 전환했습니다.', 'success') }}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `
}
