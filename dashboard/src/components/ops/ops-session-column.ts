// Ops — Session column: session list, selected session digest, session actions

import { signal } from '@preact/signals'
import { html } from 'htm/preact'
import { JsonViewerCard } from '../common/json-viewer'
import { CARD_STANDARD } from '../common/card'
import { ActionButton } from '../common/button'
import {
  fetchAutoresearchStatus,
  injectAutoresearchHypothesis,
  runAutoresearchCycle,
  stopAutoresearchLoop,
} from '../../api'
import {
  operatorActionBusy,
  operatorSessionDigest,
  operatorSnapshot,
  refreshOperatorSessionDigest,
  refreshOperatorSnapshot,
} from '../../operator-store'
import {
  actionTypeLabel,
  displayStatus,
  guidanceFreshnessLabel,
  guidanceLayerLabel,
  guidanceLayerTone,
  isSessionTerminal,
  deliveryModeLabel,
  pickPreferredSession,
  
  runtimeJudgeLabel,
  selectedSessionId,
  sessionActionLabel,
  sessionHealthLabel,
  sessionOutcomeLabel,
  submitTeamStop,
  submitTeamTurn,
  targetTypeLabel,
  teamMessage,
  teamSpawnBatchJson,
  teamStopReason,
  teamTaskDescription,
  teamTaskPriority,
  teamTaskTitle,
  teamTurnKind,
  logEntryBorderClass,
} from './helpers'

const autoresearchHypothesis = signal('')
const autoresearchBusy = signal(false)
const autoresearchError = signal<string | null>(null)

export function OpsSessionColumn() {
  const snapshot = operatorSnapshot.value
  const sessionDigest = operatorSessionDigest.value
  const sessions = snapshot?.sessions ?? []
  const liveSessions = sessions.filter(session => !isSessionTerminal(session))
  const archivedSessions = sessions.filter(isSessionTerminal)
  const availableSessionActions = (snapshot?.available_actions ?? []).filter(action => action.target_type === 'team_session')
  const selectedSession =
    sessions.find(session => session.session_id === selectedSessionId.value)
    ?? pickPreferredSession(sessions)
  const selectedSessionActionable = selectedSession ? !isSessionTerminal(selectedSession) : false
  const activeSummary = sessionDigest?.active_summary
  const guidanceLayer = sessionDigest?.active_guidance_layer ?? 'fallback'
  const judgeRuntime = sessionDigest?.operator_judge_runtime ?? snapshot?.operator_judge_runtime
  const linkedAutoresearch =
    selectedSessionActionable ? selectedSession?.linked_autoresearch ?? null : null
  const busy = operatorActionBusy.value || autoresearchBusy.value
  const activeRecommendedActions =
    sessionDigest?.active_recommended_actions?.length
      ? sessionDigest.active_recommended_actions
      : sessionDigest?.recommended_actions ?? []

  const refreshSelectedSession = async () => {
    await refreshOperatorSnapshot({ force: true })
    if (selectedSession?.session_id) {
      await refreshOperatorSessionDigest(selectedSession.session_id, { force: true })
    }
  }

  const runAutoresearchAction = async (
    effect: () => Promise<Record<string, unknown>>,
  ) => {
    autoresearchBusy.value = true
    autoresearchError.value = null
    try {
      await effect()
      await refreshSelectedSession()
    } catch (err) {
      autoresearchError.value = err instanceof Error ? err.message : '오토리서치 액션 실패'
    } finally {
      autoresearchBusy.value = false
    }
  }

  const refreshAutoresearch = async () => {
    if (!linkedAutoresearch?.loop_id) return
    await runAutoresearchAction(() => fetchAutoresearchStatus(linkedAutoresearch.loop_id!))
  }

  const injectHypothesis = async () => {
    if (!linkedAutoresearch?.loop_id || !autoresearchHypothesis.value.trim()) return
    const hypothesis = autoresearchHypothesis.value.trim()
    await runAutoresearchAction(() =>
      injectAutoresearchHypothesis(linkedAutoresearch.loop_id!, hypothesis),
    )
    autoresearchHypothesis.value = ''
  }

  const cycleAutoresearch = async () => {
    if (!linkedAutoresearch?.loop_id) return
    await runAutoresearchAction(() => runAutoresearchCycle(linkedAutoresearch.loop_id!))
  }

  const stopAutoresearch = async () => {
    if (!linkedAutoresearch?.loop_id) return
    await runAutoresearchAction(() =>
      stopAutoresearchLoop(linkedAutoresearch.loop_id!, 'dashboard stop request'),
    )
  }

  const renderSessionCard = (
    session: typeof sessions[number],
    archived = false,
  ) => html`
    <button type="button"
      key=${session.session_id}
      class="ops-entity-card p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] text-inherit text-left cursor-pointer ${selectedSession?.session_id === session.session_id ? 'active' : ''}"
      onClick=${() => { selectedSessionId.value = session.session_id }}
    >
      <div class="flex justify-between items-center gap-3 max-[880px]:flex-col max-[880px]:items-start">
        <strong>${session.session_id}</strong>
        <span class="border border-solid border-[var(--card-border)] ${session.status ?? 'idle'} ${session.status === 'offline' ? 'text-[var(--text-dim)]' : ''}">${displayStatus(session.status)}</span>
      </div>
      <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
        <span>${Math.round(session.progress_pct ?? 0)}%</span>
        <span>${sessionOutcomeLabel(session)}</span>
        <span>${archived ? '종료 세션' : `팀 상태 ${sessionHealthLabel(session)}`}</span>
      </div>
    </button>
  `

  if (sessions.length === 0) {
    return html`
      <div class="flex flex-col gap-4 min-w-0">
        <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0 ops-lane-panel">
          <div class="pb-2 border-b border-[var(--card-border)] mb-1">
            <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Session 개입</h3>
          </div>
          <div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">활성 세션이 없습니다. keeper가 독립 운영 중입니다.</div>
        </section>
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-4 min-w-0">
      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0 ops-lane-panel">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Session 개입</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">지금 개입 가능한 세션만 위에 두고, 종료된 세션은 아래에 접어 둡니다.</p>

        <div class="flex flex-col gap-2">
          <div class="flex items-center justify-between gap-3 text-[var(--fs-sm)] text-[var(--text-muted)]">
            <strong>${'개입 가능한 세션'}</strong>
            <span>${liveSessions.length}</span>
          </div>
          <div class="flex items-center justify-between gap-3 text-[var(--fs-sm)] text-[var(--text-muted)]">
            ${liveSessions.length === 0
              ? html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">지금 바로 개입할 live 세션이 없습니다.</div>`
              : liveSessions.map(session => renderSessionCard(session))}
          </div>
        </div>

        ${archivedSessions.length > 0 ? html`
          <details class="ops-archive-panel">
            <summary class="cursor-pointer text-[var(--text-muted)] text-[var(--fs-sm)] list-none">최근 종료 세션 ${archivedSessions.length}</summary>
            <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">완료/중단된 세션은 읽기 전용 참고용입니다. 새 노트, 작업, 중지는 위 live 세션에만 적용하세요.</p>
            <div class="flex items-center justify-between gap-3 text-[var(--fs-sm)] text-[var(--text-muted)]">
              ${archivedSessions.slice(0, 8).map(session => renderSessionCard(session, true))}
            </div>
          </details>
        ` : null}
      </section>

      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">선택한 Session 요약</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${selectedSession && sessionDigest ? html`
          <article class="ops-guidance-card p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-2 ${guidanceLayerTone(guidanceLayer)}">
            <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
              <strong>${guidanceLayerLabel(guidanceLayer)}</strong>
              <span>${runtimeJudgeLabel(judgeRuntime)}</span>
            </div>
            <div class="text-[var(--text-strong)] leading-[1.5]">
              ${activeSummary?.summary ?? '현재 이 session에 대한 operator guidance가 없습니다. fallback digest를 표시합니다.'}
            </div>
            <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
              <span>authoritative ${sessionDigest.authoritative_judgment_available ? 'yes' : 'no'}</span>
              <span>${guidanceFreshnessLabel(activeSummary)}</span>
              ${judgeRuntime?.model_used ? html`<span>${judgeRuntime.model_used}</span>` : null}
            </div>
          </article>
          ${activeRecommendedActions.length > 0 ? html`
            <div class="flex flex-col gap-2">
              ${activeRecommendedActions.map(item => html`
                <article key=${`${item.action_type}:${item.target_type}:${item.target_id ?? 'session'}`} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)] ${logEntryBorderClass(item.severity)}">
                  <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                    <strong>${actionTypeLabel(item.action_type)}</strong>
                    <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                  </div>
                  <div class="mt-1.5 whitespace-pre-wrap break-words">${item.reason}</div>
                </article>
              `)}
            </div>
          ` : null}
          <div class="flex flex-col gap-2">
            ${sessionDigest.attention_items.length > 0 ? sessionDigest.attention_items.map(item => html`
              <article key=${`${item.kind}:${item.target_id ?? 'session'}`} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)] ${logEntryBorderClass(item.severity)}">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${item.kind}</strong>
                  <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">${item.summary}</div>
              </article>
            `) : html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">이 세션의 attention item은 없습니다.</div>`}
            ${sessionDigest.worker_cards.length > 0 ? sessionDigest.worker_cards.map(card => html`
              <article key=${`${card.actor ?? card.spawn_role ?? 'worker'}:${card.spawn_agent ?? card.runtime_pool ?? 'runtime'}`} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)]">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${card.actor ?? card.spawn_role ?? 'worker'}</strong>
                  <span>${displayStatus(card.status)}</span>
                  ${card.spawn_agent || card.runtime_pool ? html`<span>${card.spawn_agent ?? card.runtime_pool}</span>` : null}
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">
                  ${(card.worker_class ?? 'worker')}${card.lane_id ? ` · ${card.lane_id}` : ''}${card.routing_reason ? ` · ${card.routing_reason}` : ''}
                </div>
              </article>
            `) : null}
          </div>
        ` : html`
          <div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">세션을 고르면 세부 요약을 불러옵니다.</div>
        `}
      </section>

      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0 ops-lane-panel">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">선택한 Session 상태</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">
          ${selectedSessionActionable
            ? '기본은 읽기만 하고, 실제 세션 개입은 아래 고급 패널에서만 합니다.'
            : '종료된 세션은 여기서 읽기만 하고, 실제 개입은 위 live 세션을 다시 골라서 진행합니다.'}
        </p>

        ${selectedSession ? html`
          <div class="flex flex-col gap-2">
            <div class="mt-1.5 whitespace-pre-wrap break-words">${selectedSession.session_id}</div>
            <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
              <span>상태: ${displayStatus(selectedSession.status)}</span>
              <span>경과: ${selectedSession.elapsed_sec ?? 0}초</span>
              <span>남은 시간: ${selectedSession.remaining_sec ?? 0}초</span>
              <span>${selectedSessionActionable ? `팀 상태: ${sessionHealthLabel(selectedSession)}` : '종료 세션'}</span>
            </div>
            ${selectedSession.linked_autoresearch ? html`
              <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                <span>오토리서치: ${String(selectedSession.linked_autoresearch.status ?? 'unknown')}</span>
                <span>루프: ${String(selectedSession.linked_autoresearch.loop_id ?? 'n/a')}</span>
                <span>사이클: ${String(selectedSession.linked_autoresearch.current_cycle ?? 0)}</span>
                <span>최고 점수: ${String(selectedSession.linked_autoresearch.best_score ?? 'n/a')}</span>
              </div>
              <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                <span>파일: ${selectedSession.linked_autoresearch.target_file ?? 'n/a'}</span>
                <span>최근 결정: ${selectedSession.linked_autoresearch.last_decision ?? 'n/a'}</span>
                <span>세션 연결: ${selectedSession.linked_autoresearch.session_id ?? selectedSession.session_id}</span>
                ${selectedSession.linked_autoresearch.operation_id
                  ? html`<span>작전: ${selectedSession.linked_autoresearch.operation_id}</span>`
                  : null}
              </div>
              ${selectedSession.linked_autoresearch.program_note
                ? html`<div class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">프로그램 노트: ${selectedSession.linked_autoresearch.program_note}</div>`
                : null}
              ${selectedSession.linked_autoresearch.queued_hypothesis
                ? html`<div class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">대기 가설: ${selectedSession.linked_autoresearch.queued_hypothesis}</div>`
                : null}
              ${selectedSession.linked_autoresearch.warnings && selectedSession.linked_autoresearch.warnings.length > 0
                ? html`<div class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">경고: ${selectedSession.linked_autoresearch.warnings.join(', ')}</div>`
                : null}
              ${selectedSession.linked_autoresearch.error
                ? html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">${selectedSession.linked_autoresearch.error}</div>`
                : null}
            ` : null}
            ${selectedSession.recent_events && selectedSession.recent_events.length > 0 ? html`
              <${JsonViewerCard} data=${selectedSession.recent_events.slice(-3)} title="Recent Events" />
            ` : null}
          </div>
        ` : html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">먼저 세션을 하나 고르세요.</div>`}

        ${selectedSession && !selectedSessionActionable ? html`
          <div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">이 세션은 이미 종료돼서 새 노트, 작업, 중지를 보내지 않습니다. 위의 live 세션을 선택하세요.</div>
        ` : null}

        <details class="ops-control-disclosure mt-0.5 border border-[var(--white-8)] rounded-xl bg-[var(--white-2)]">
          <summary class="ops-control-summary list-none cursor-pointer grid gap-1 p-3 px-3.5">
            <span class="text-[var(--ok-20)] text-[var(--fs-2xs)] tracking-[0.08em] uppercase">고급 세션 개입</span>
            <strong>${selectedSessionActionable ? '노트, 방송, 작업 주입, worker 교체, 중지' : '읽기 전용 세션은 여기서도 실행되지 않습니다.'}</strong>
            <span>${selectedSessionActionable ? '선택한 live 세션에만 적용합니다.' : '실제 개입은 위 live 세션을 다시 선택한 뒤 진행하세요.'}</span>
          </summary>

          <div class="grid gap-3 px-3.5 pb-3.5 border-t border-[var(--white-8)]">
            ${availableSessionActions.length > 0 ? html`
              <div class="text-[12px] text-[var(--text-muted)] leading-[1.45]">
                지원 액션:
                ${availableSessionActions.map(action => `${actionTypeLabel(action.action_type)} (${deliveryModeLabel(action.confirm_required)})`).join(', ')}
              </div>
            ` : null}

            ${linkedAutoresearch?.loop_id ? html`
              <label class="control-label" for="ops-autoresearch-hypothesis">Autoresearch 제어</label>
              <div class="control-row items-stretch">
                <${ActionButton} variant="ghost" size="lg" onClick=${() => { void refreshAutoresearch() }} disabled=${busy}>
                  상태 새로고침
                <//>
                <${ActionButton} variant="primary" size="lg" onClick=${() => { void cycleAutoresearch() }} disabled=${busy}>
                  1 cycle 실행
                <//>
                <${ActionButton} variant="ghost" size="lg" onClick=${() => { void stopAutoresearch() }} disabled=${busy}>
                  loop 중지
                <//>
              </div>
              <textarea
                id="ops-autoresearch-hypothesis"
                class="control-textarea"
                rows=${2}
                placeholder="다음 cycle에 넣을 hypothesis"
                value=${autoresearchHypothesis.value}
                onInput=${(event: Event) => { autoresearchHypothesis.value = (event.target as HTMLTextAreaElement).value }}
                disabled=${busy}
              ></textarea>
              <div class="control-row items-stretch">
                <${ActionButton} variant="primary" size="lg" onClick=${() => { void injectHypothesis() }} disabled=${busy || !autoresearchHypothesis.value.trim()}>
                  hypothesis 주입
                <//>
                <span class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">canonical control은 MCP tool이고, 이 화면은 그 상태를 읽고 이어서 제어합니다.</span>
              </div>
              ${autoresearchError.value ? html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">${autoresearchError.value}</div>` : null}
            ` : null}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row items-stretch">
              <select
                id="ops-turn-kind"
                class="control-input min-w-[92px]"
                value=${teamTurnKind.value}
                onChange=${(event: Event) => { teamTurnKind.value = (event.target as HTMLSelectElement).value as typeof teamTurnKind.value }}
                disabled=${busy || !selectedSessionActionable}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
                <option value="worker_spawn_batch">worker 교체</option>
              </select>
              <${ActionButton} variant="primary" size="lg" onClick=${() => { void submitTeamTurn() }} disabled=${busy || !selectedSessionActionable}>
                적용
              <//>
            </div>
            <div class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">현재 선택: ${sessionActionLabel(teamTurnKind.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${teamMessage.value}
              onInput=${(event: Event) => { teamMessage.value = (event.target as HTMLTextAreaElement).value }}
              disabled=${busy || !selectedSessionActionable}
            ></textarea>

            ${teamTurnKind.value === 'task' ? html`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${teamTaskTitle.value}
                onInput=${(event: Event) => { teamTaskTitle.value = (event.target as HTMLInputElement).value }}
                disabled=${busy || !selectedSessionActionable}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${teamTaskDescription.value}
                onInput=${(event: Event) => { teamTaskDescription.value = (event.target as HTMLTextAreaElement).value }}
                disabled=${busy || !selectedSessionActionable}
              ></textarea>
              <select
                class="control-input min-w-[92px]"
                value=${teamTaskPriority.value}
                onChange=${(event: Event) => { teamTaskPriority.value = (event.target as HTMLSelectElement).value }}
                disabled=${busy || !selectedSessionActionable}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
            ` : teamTurnKind.value === 'worker_spawn_batch' ? html`
              <textarea
                class="control-textarea"
                rows=${6}
                placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
                value=${teamSpawnBatchJson.value}
                onInput=${(event: Event) => { teamSpawnBatchJson.value = (event.target as HTMLTextAreaElement).value }}
                disabled=${busy || !selectedSessionActionable}
              ></textarea>
            ` : null}

            <div class="control-row items-stretch">
              <input
                class="control-input"
                type="text"
                value=${teamStopReason.value}
                onInput=${(event: Event) => { teamStopReason.value = (event.target as HTMLInputElement).value }}
                disabled=${busy || !selectedSessionActionable}
              />
              <${ActionButton} variant="ghost" size="lg" onClick=${() => { void submitTeamStop() }} disabled=${busy || !selectedSessionActionable}>
                세션 중지
              <//>
            </div>
          </div>
        </details>
      </section>
    </div>
  `
}
