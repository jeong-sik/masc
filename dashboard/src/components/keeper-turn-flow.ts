import { html } from 'htm/preact'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import type { TurnRecordEntry, ToolCallEntry } from '../api/dashboard'
import { decodeBoardActionEvidence, fetchKeeperToolCallsByExecutionIds,
  type BoardActionEvidence } from '../api/dashboard-keeper-tool-calls'
import { ApiRequestError } from '../api/core'
import { ADMIN_REQUIRED_MESSAGE, isAdminRequired } from '../api/admin-required'
import { RouteLink } from './common/route-link'
import { boardRouteTarget } from './board/board-route'
import {
  fetchTurnFlow, type TurnFlow, type TurnIntake,
} from '../api/keeper-turn-flow'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { projectSkillAsyncEvidence } from '../lib/skill-async-evidence'
import { skillAsyncOccurrenceIdentity, skillAsyncResultDeliverySha256 } from '../api/dashboard-tools-prompts'
import { fetchPhysicalSkillEvidence, type PhysicalSkillEvidence } from '../api/keeper-physical-skill-evidence'
import type { TurnSourceOutcomes, SourceOutcome, SourceReceiptKind } from '../api/keeper-turn-source-outcomes'

type FlowRecord = Pick<TurnRecordEntry,
  'keeper' | 'trace_id' | 'absolute_turn' | 'turn_ref' | 'execution_ids' | 'blocks'>

function completeBoardTurn(record: FlowRecord): boolean {
  return record.keeper.trim().length > 0 && record.trace_id.trim().length > 0
    && record.turn_ref === `${record.trace_id}#${record.absolute_turn}`
    && Number.isSafeInteger(record.absolute_turn) && record.absolute_turn >= 0
}

export function turnToolEvidence(record: FlowRecord, entries: readonly ToolCallEntry[]) {
  const byId = new Map<string, ToolCallEntry | null>()
  for (const entry of entries) {
    if (entry.execution_id !== undefined) {
      byId.set(entry.execution_id, byId.has(entry.execution_id) ? null : entry)
    }
  }
  return record.execution_ids.map(id => {
    const entry = byId.get(id)
    const belongs = entry?.keeper === record.keeper
      && (entry.trace_id === undefined || entry.trace_id === record.trace_id)
      && (entry.keeper_turn_id === undefined || entry.keeper_turn_id === record.absolute_turn)
    return { id, entry: belongs && entry ? entry : undefined }
  })
}

/** Board authorship requires the complete recorded turn identity. Ordinary
 * tool evidence intentionally retains its separate legacy association rule. */
function boardJoinIdentity(entry: ToolCallEntry) {
  return entry.board_action_identity ?? entry
}

export function turnBoardActionEvidence(record: FlowRecord, entries: readonly ToolCallEntry[]) {
  const byId = new Map<string, ToolCallEntry | null>()
  for (const entry of entries) {
    const identity = boardJoinIdentity(entry)
    if (identity.execution_id?.trim()) {
      byId.set(identity.execution_id, byId.has(identity.execution_id) ? null : entry)
    }
  }
  const requested = new Map<string, number>()
  for (const id of record.execution_ids) requested.set(id, (requested.get(id) ?? 0) + 1)
  const completeTurn = completeBoardTurn(record)
  return [...requested].map(([id, count]) => {
    const entry = byId.get(id)
    const identity = entry ? boardJoinIdentity(entry) : undefined
    const belongs = completeTurn && id.trim().length > 0 && count === 1
      && identity?.keeper === record.keeper && identity.trace_id === record.trace_id
      && identity.keeper_turn_id === record.absolute_turn
    return { id, entry: belongs && entry ? entry : undefined }
  })
}

function BoardAction({ evidence }: { evidence: BoardActionEvidence }) {
  if (evidence.kind === 'invalid') return html`<p>Board 행동 기록 확인 불가</p>`
  const post = boardRouteTarget({ post: evidence.post_id })
  const commentId = evidence.kind === 'comment_added' ? evidence.comment_id
    : evidence.target_type === 'comment' ? evidence.target_id : null
  const comment = commentId === null ? null : boardRouteTarget({ post: evidence.post_id, comment: commentId })
  const parent = evidence.kind === 'comment_added' && evidence.parent_id !== null
    ? boardRouteTarget({ post: evidence.post_id, comment: evidence.parent_id }) : null
  return html`
    <p>${evidence.kind === 'comment_added' ? `댓글 작성 · ${evidence.author}`
      : `${evidence.reacted ? '반응 추가' : '반응 제거'} · ${evidence.emoji} · ${evidence.user_id}`}</p>
    <div class="flex flex-wrap gap-2">
      <${RouteLink} tab=${post.tab} params=${post.params}>Board 글 ${evidence.post_id}</${RouteLink}>
      ${comment && html`<${RouteLink} tab=${comment.tab} params=${comment.params}>댓글 ${commentId}</${RouteLink}>`}
      ${parent && evidence.kind === 'comment_added' && html`
        <${RouteLink} tab=${parent.tab} params=${parent.params}>부모 댓글 ${evidence.parent_id}</${RouteLink}>`}
    </div>
  `
}

function BoardActions({ record, entries, error }: {
  record: FlowRecord; entries: readonly ToolCallEntry[]; error: string | null
}) {
  const targetKey = JSON.stringify([record.keeper, record.trace_id, record.absolute_turn,
    record.turn_ref, record.execution_ids])
  const lookup = useManagedAsyncResource<{ targetKey: string; entries: ToolCallEntry[] }>(null)
  const selection = useRef<{
    targetKey: string; resource: object; record: FlowRecord
    ambiguous: Set<string>; started: boolean
  } | null>(null)
  if (selection.current === null || selection.current.targetKey !== targetKey || selection.current.resource !== lookup) {
    selection.current = { targetKey, resource: lookup, record: { ...record,
      execution_ids: [...record.execution_ids] }, ambiguous: new Set(), started: false }
  }
  const selected = selection.current
  const selectedIds = new Set(record.execution_ids)
  const suppliedCounts = new Map<string, number>()
  for (const entry of entries) {
    const id = boardJoinIdentity(entry).execution_id
    if (id !== undefined && selectedIds.has(id)) {
      suppliedCounts.set(id, (suppliedCounts.get(id) ?? 0) + 1)
    }
  }
  for (const [id, count] of suppliedCounts) {
    if (count > 1) {
      selected.ambiguous.add(id)
    }
  }
  useEffect(() => {
    const current = selection.current
    lookup.reset()
    if (!current || current.targetKey !== targetKey || current.resource !== lookup
      || !completeBoardTurn(current.record)) return () => { lookup.cancel() }
    current.started = true
    // A recent-tail match cannot establish uniqueness across the retained
    // ledger. Every selected identity is checked through the exact batch door.
    const requested = [...new Set(current.record.execution_ids)].filter(id => id.trim().length > 0)
    if (requested.length > 0) {
      void lookup.load(async signal => {
        try {
          const response = await fetchKeeperToolCallsByExecutionIds(current.record.keeper, requested, { signal })
          return { targetKey, entries: response.entries }
        } catch (failure) {
          if (isAdminRequired(failure)) throw new Error(ADMIN_REQUIRED_MESSAGE)
          if (failure instanceof ApiRequestError) {
            throw new Error(failure.detail ?? '선택한 실행 기록을 조회할 수 없습니다.')
          }
          throw failure
        }
      })
    }
    return () => { lookup.cancel() }
    // Tail refreshes can reveal ambiguity, but do not start another request
    // for this selection. The resource also changes with the credential.
  }, [targetKey, lookup])
  const lookupState = lookup.state.value
  const lookupLoading = selected.started && lookupState.loading
  const lookupError = selected.started ? lookupState.error : null
  const loaded = selected.started && lookupState.data?.targetKey === targetKey ? lookupState.data.entries : []
  const loadedCounts = new Map<string, number>()
  for (const entry of loaded) {
    const id = boardJoinIdentity(entry).execution_id
    if (id !== undefined) {
      loadedCounts.set(id, (loadedCounts.get(id) ?? 0) + 1)
    }
  }
  for (const [id, count] of loadedCounts) {
    if (count > 1) {
      selected.ambiguous.add(id)
    }
  }
  const resolved = loaded.filter(entry => {
    // Any observed ambiguity stays unknown for this selection, including
    // after the recent tail changes. Only exact lookup rows can be positive.
    const id = boardJoinIdentity(entry).execution_id
    return id !== undefined && !selected.ambiguous.has(id)
  })
  const tools = turnBoardActionEvidence(record, resolved)
  const unconfirmed = tools.filter(tool => tool.entry === undefined).length
  const unrecorded = tools.filter(tool => tool.entry !== undefined
    && (tool.entry.tool === 'masc_board_comment' || tool.entry.tool === 'masc_board_reaction')
    && tool.entry.board_action_evidence === undefined).length
  const rows = tools.flatMap(({ id, entry }) => {
    if (!entry) return []
    const evidence = decodeBoardActionEvidence(entry.tool, entry.board_action_evidence)
    return evidence === undefined ? [] : [{ id, entry, evidence }]
  })
  return html`
    <section aria-label="같은 턴의 Board 댓글·반응">
      <h4>같은 턴의 Board 댓글·반응</h4>
      <p class="rt-note">같은 턴에 기록된 행동입니다. 각 입력 자극에 대한 응답인지는 확정하지 않습니다.</p>
      ${error && html`<p class="rt-note">도구 기록 조회 실패: ${error}</p>`}
      ${lookupLoading && html`<p class="rt-note">선택한 실행 기록 조회 중…</p>`}
      ${lookupError && html`<p class="rt-note">선택한 실행 기록 조회 실패: ${lookupError}</p>`}
      ${unconfirmed > 0 && html`<p class="rt-note">정확한 턴·실행 기록 미확인 ${unconfirmed}개</p>`}
      ${unrecorded > 0 && html`<p class="rt-note">Board 댓글·반응 미기록 실행 ${unrecorded}개</p>`}
      ${rows.length === 0 && !lookupLoading && !lookupError && !error
        && html`<p class="rt-note">이 턴에서 확인할 수 있는 Board 행동 기록이 없습니다.</p>`}
      <ol>${rows.map(({ id, entry, evidence }) => html`<li key=${id} class="rt-note break-all mb-3">
        <p class="font-mono">${record.turn_ref} · ${id}</p>
        <${BoardAction} evidence=${evidence} />
        <p>도구 응답 ${entry.wire_outcome} · 처리 상태 ${entry.disposition ?? '미기록'}</p>
      </li>`)}</ol>
      <p class="rt-note">기록이 없으면 댓글·반응 여부와 무응답 이유를 알 수 없습니다.</p>
    </section>
  `
}

const receiptLabels: Record<SourceReceiptKind, string> = {
  ack_turn_completed: '턴 완료 후 ACK',
  ack_fusion_terminal: 'Fusion 종단 ACK', ack_hitl_terminal: 'HITL 종단 ACK',
  cancelled: '취소', transferred: '이관',
}

function Receipts({ source }: { source: SourceOutcome | undefined }) {
  if (!source) return html`처리 결과 미확인`
  if (source.receipts.length === 0) return html`일치하는 처리 기록 관측 없음. 현재 대기 상태인지는 확정할 수 없습니다.`
  return html`
    ${source.receipts.length > 1 && html`<p>서로 다른 처리 영수증이 있어 최종 상태를 확정하지 않습니다.</p>`}
    ${source.receipts.map((receipt, index) => html`<div key=${index}>
      ${receiptLabels[receipt.kind]} · ${new Date(receipt.appliedAt * 1000).toLocaleString()}
      <div class="font-mono">${receipt.transitionId} · ${receipt.eventId}</div>
    </div>`)}
  `
}

function Intake({ intake, outcomes }: { intake: TurnIntake; outcomes: TurnSourceOutcomes }) {
  switch (intake.state) {
    case 'not_recorded':
      return html`<p class="rt-note">${intake.reason}. 자극이 없었다는 뜻은 아닙니다.</p>`
    case 'unavailable':
      return html`<p class="rt-note">${intake.reason}. 입력 자극을 확정하지 않습니다.</p>`
    case 'ambiguous':
      return html`<p class="rt-note">같은 턴 참조에 시작 기록을 ${intake.starts}개 이상 관측했습니다. 어느 시도의 입력인지 확정할 수 없습니다.</p>`
    case 'observed':
      return html`
        <p class="rt-note">선택 채널: ${intake.channel ?? '기록 없음'} · ${intake.sources.length}개</p>
        ${outcomes.state === 'unavailable'
          ? html`<p class="rt-note">${outcomes.reason}</p>`
          : html`<p class="rt-note">처리 원장 조회 ${new Date(outcomes.observedAt * 1000).toLocaleString()} · ${outcomes.coverage.rowsInspected}행 읽음
              · 손상 ${outcomes.coverage.invalidJsonRows + outcomes.coverage.invalidLedgerRows}행
              ${outcomes.coverage.storageError ? ' · 저장소 읽기 오류' : ''}
              ${outcomes.coverage.state === 'partial' ? ' · 일부 기록만 확인' : ''}
            </p>`}
        ${intake.sources.length === 0
          ? html`<p class="rt-note">턴 시작 시 관측한 큐 자극이 없습니다. 직접 입력은 메시지 탭에서 확인하세요.</p>`
          : html`<ol class="space-y-3">${intake.sources.map(source => html`
              <li key=${`${source.stimulusId}:${source.admittedRevision}`} class="ti-kv break-all">
                <span class="k">종류</span><span class="v">${source.sourceKind ?? '기록 없음'}</span>
                <span class="k">자극 ID</span><span class="v font-mono">${source.stimulusId}</span>
                <span class="k">원본 참조</span><span class="v font-mono">${source.snapshotRef}</span>
                <span class="k">선택 버전</span><span class="v">${source.admittedRevision}</span>
                <span class="k">최초 선택</span><span class="v">${source.firstAdmittedAt === null
                  ? '기록 없음' : new Date(source.firstAdmittedAt * 1000).toISOString()}</span>
                <span class="k">큐 처리</span><span class="v"><${Receipts} source=${outcomes.state === 'observed'
                  ? outcomes.sources.find(item => item.stimulusId === source.stimulusId
                    && item.snapshotRef === source.snapshotRef && item.admittedRevision === source.admittedRevision)
                  : undefined} /></span>
              </li>
            `)}</ol>`}
      `
  }
}

function Skills({ data, turnRef }: { data: PhysicalSkillEvidence; turnRef: string }) {
  const frames = data.origins.flatMap(origin => origin.activations.map(item => ({ origin, item })))
  const deliveries = data.origins.flatMap(origin => origin.async_result_deliveries.map(item => ({ origin, item })))
  const asyncEvidence = projectSkillAsyncEvidence({
    async_result_deliveries: deliveries.map(row => row.item),
    async_actions: data.origins.flatMap(origin => origin.async_actions),
  })
  const byDelivery = new Map(deliveries.map(row => [skillAsyncResultDeliverySha256(row.item), row]))
  const coverage = data.coverage
  const scopeLabel = {
    complete_retained_trace_snapshot: '보존된 모든 원장 확인',
    incomplete_retained_trace_snapshot: '일부 원장 확인 불가',
    trace_store_unavailable: '원장 저장소 확인 불가',
  }[coverage.scope]
  return html`
    <p class="rt-note">${scopeLabel} · trace ${coverage.sessionsInspected}개 조회 · 원장 ${coverage.ledgersLoaded}개 읽음</p>
    ${coverage.scope !== 'complete_retained_trace_snapshot' && html`<p class="rt-note">관측된 사실만 표시합니다. 결과가 비어 있어도 수신·사용이 없었다고 확정할 수 없습니다.</p>`}
    ${coverage.gaps.map((gap, index) => html`<p class="rt-note break-all" key=${index}>
      ${gap.code} ${typeof gap.trace_id === 'string' ? gap.trace_id : ''}
      ${typeof gap.detail === 'string' ? gap.detail : ''}
    </p>`)}
    <p class="rt-note">이 턴의 호출 ${frames.filter(row => row.item.turn_ref === turnRef).length}개 · 이 턴에서 받은 비동기 결과 ${deliveries.length}개 · 비동기 결과 사용 ${asyncEvidence.actions.length}건 · 인과 연결 ${asyncEvidence.actionLinkCount}개</p>
    ${frames.map(({ origin, item }) => html`
      <div key=${`${origin.traceId}:${item.skill_tool_use_id}`} class="ti-kv mb-3 break-all">
        <span class="k">Skill</span><span class="v">${item.identity.source_id}/${item.identity.package_id}:${item.identity.name}@${item.content_revision}</span>
        <span class="k">원래 턴</span><span class="v font-mono">${item.turn_ref}</span>
        <span class="k">원장 버전</span><span class="v font-mono">${origin.ledgerRevision}</span>
        <span class="k">호출 ID</span><span class="v font-mono">${item.skill_tool_use_id}</span>
        <span class="k">호출 종류</span><span class="v">${item.invocation.kind}</span>
        <span class="k">원래 전달</span><span class="v">${item.delivery?.boundary.kind ?? '전달 관측 없음'}</span>
        <span class="k">원래 사용</span><span class="v">${item.actions.map(action => action.tool_name).join(', ') || '관측 없음'}</span>
      </div>
    `)}
    ${deliveries.map(({ item }) => html`<p class="rt-note break-all" key=${skillAsyncResultDeliverySha256(item)}>
      비동기 결과 원래 턴 ${item.original_turn_ref} → 수신 턴 ${item.physical_turn_ref} · 요청 ${item.request_id} · ${item.presentation}
    </p>`)}
    ${asyncEvidence.actions.map(group => html`<div key=${skillAsyncOccurrenceIdentity(group.first)}>
      <p class="rt-note">비동기 결과 사용 ${group.first.tool_name} · ${group.first.occurrence.kind}</p>
      ${[group.first, ...group.additionalLinks].map(link => {
        const source = byDelivery.get(link.delivery_sha256)
        return html`<p class="rt-note break-all" key=${link.delivery_sha256}>
          원래 턴 ${source?.item.original_turn_ref ?? '미확인'} · 요청 ${source?.item.request_id ?? '미확인'}
          · 연결된 결과 ${link.delivery_sha256} · ${link.observed_at}
        </p>`
      })}
    </div>`)}
  `
}

export function KeeperTurnFlow({ record, toolEntries, toolCallError, onMessages, onContext }: {
  record: FlowRecord
  toolEntries: readonly ToolCallEntry[]
  toolCallError: string | null
  onMessages: () => void
  onContext: () => void
}) {
  const target = useMemo(() => ({
    keeper: record.keeper, traceId: record.trace_id,
    absoluteTurn: record.absolute_turn, turnRef: record.turn_ref,
  }), [record.keeper, record.trace_id, record.absolute_turn, record.turn_ref])
  const flow = useManagedAsyncResource<TurnFlow>(null)
  const skills = useManagedAsyncResource<PhysicalSkillEvidence>(null)
  useEffect(() => {
    flow.reset()
    skills.reset()
    // Independent evidence doors load concurrently and fail independently.
    void flow.load(signal => fetchTurnFlow(target, { signal }))
    void skills.load(signal => fetchPhysicalSkillEvidence(target.turnRef, { signal }))
    return () => { flow.cancel(); skills.cancel() }
  }, [target, flow, skills])
  const flowState = flow.state.value
  const skillState = skills.state.value
  const tools = turnToolEvidence(record, toolEntries)
  return html`
    <div class="space-y-5">
      <p class="rt-note break-all">${record.turn_ref}</p>
      <section aria-label="입력 자극">
        <h4>입력 자극</h4>
        ${flowState.error ? html`<p class="rt-note">자극·선택 기록 조회 실패: ${flowState.error}</p>`
          : flowState.data ? html`<${Intake} intake=${flowState.data.intake} outcomes=${flowState.data.outcomes} />`
            : html`<p class="rt-note">자극·선택 기록 조회 중…</p>`}
        <p class="rt-note">ACK는 큐 처리 기록입니다. 실제 요청 전송과 PR 승인 같은 업무 결과는 해당 증거에서 확인하세요.</p>
      </section>
      <${BoardActions} record=${record} entries=${toolEntries} error=${toolCallError} />
      <section aria-label="실제 입력 확인">
        <h4>프롬프트와 실제 입력</h4>
        <p class="rt-note">이 턴의 프롬프트 블록 ${record.blocks.length}개. 요청 캡처의 메시지와 도구 스키마를 같은 턴 기준으로 확인합니다.</p>
        <div class="flex gap-2">
          <button class="ti-tab" onClick=${onMessages}>실제 메시지 열기</button>
          <button class="ti-tab" onClick=${onContext}>System·도구 스키마 열기</button>
        </div>
      </section>
      <section aria-label="런타임 선택과 진행">
        <h4>런타임 선택과 진행</h4>
        ${flowState.data && html`
          <p class="rt-note">반환 ${flowState.data.trace.manifest_returned_rows}행 / 관측 ${flowState.data.trace.manifest_total_rows}행 · ${flowState.data.trace.health}</p>
          ${flowState.data.trace.manifest_scan_diagnostics.state === 'unavailable'
            ? html`<p class="rt-note">기록 검사 상태 미확인: ${flowState.data.trace.manifest_scan_diagnostics.error}</p>`
            : html`<p class="rt-note">지원하지 않는 행 ${flowState.data.trace.manifest_scan_diagnostics.unsupported_event_count}개 · 손상 행 ${flowState.data.trace.manifest_scan_diagnostics.invalid_manifest_row_count + flowState.data.trace.manifest_scan_diagnostics.invalid_json_row_count}개</p>`}
          <ol>${flowState.data.events.map((event, index) => html`
            <li key=${index} class="rt-note break-all">
              ${event.event} · ${event.status}
              ${event.runtimeId ? ` · ${event.runtimeId}` : ''}
              ${event.routingAction ? ` · ${event.routingAction}` : ''}
              ${event.routingReason ? ` · ${event.routingReason}` : ''}
            </li>
          `)}</ol>
        `}
        <p class="rt-note">모델 내부 판단은 추정하지 않습니다. 여기에는 런타임이 기록한 선택과 실행 경계만 표시합니다.</p>
      </section>
      <section aria-label="Skill 호출과 사용">
        <h4>Skill 호출과 사용</h4>
        ${skillState.error ? html`<p class="rt-note">Skill 기록 조회 실패: ${skillState.error}</p>`
          : skillState.data ? html`<${Skills} data=${skillState.data} turnRef=${record.turn_ref} />`
            : html`<p class="rt-note">Skill 기록 조회 중…</p>`}
      </section>
      <section aria-label="도구 실행 결과">
        <h4>도구 실행 결과</h4>
        ${toolCallError && html`<p class="rt-note">도구 기록 조회 실패: ${toolCallError}</p>`}
        <p class="rt-note">이 턴의 실행 ID ${tools.length}개 · 최근 도구 목록에서 일치 ${tools.filter(tool => tool.entry).length}개</p>
        <ol>${tools.map(({ id, entry }) => html`<li key=${id} class="rt-note break-all">
          ${entry ? `${entry.tool} · ${entry.wire_outcome}` : '최근 목록에 실행 상세 없음'} · ${id}
        </li>`)}</ol>
        <p class="rt-note">도구 반환 상태입니다. PR 승인·병합 같은 외부 결과의 성공을 대신하지 않습니다.</p>
      </section>
    </div>
  `
}
