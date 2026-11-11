import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { captureDashboardCredentialOwner, dashboardCredentialOwnerIsCurrent, type DashboardCredentialOwner } from '../../api/core'
import { previewKeeperQueue, queueCounts, queueRowKey, type KeeperQueueFilter, type KeeperQueuePreview, type KeeperQueueRow } from '../../api/keeper-event-queue'
import { executionWorkspaceAuthority, shellAuthSummary, type ExecutionWorkspaceAuthority } from '../../store'
import { storedTokenRevision } from '../../api/token-revision'
import { dashboardActorRevision, managedDashboardActorRevision, managedDashboardAuthRevision, managedDashboardUnverified } from '../../lib/dashboard-session-actor'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { executeKeeperQueuePlan, keeperQueueOperation, keeperQueuePlanIsCurrent, readbackKeeperQueueOperation, stopKeeperQueueResponse, type KeeperQueuePlan } from '../../lib/keeper-queue-operation'
import { ActionButton } from '../common/button'
import { formatElapsedCompact } from '../../lib/format-time'

interface Owner { authority: ExecutionWorkspaceAuthority; credentials: DashboardCredentialOwner }
interface Reading { owner: Owner; filterKey: string; preview: KeeperQueuePreview }
const inputClass = 'rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1 text-xs'

function ownerIsCurrent(owner: Owner): boolean {
  return executionWorkspaceAuthority.peek() === owner.authority && dashboardCredentialOwnerIsCurrent(owner.credentials)
}
function age(row: KeeperQueueRow): string {
  const now = Date.now() / 1000
  return row.first_admitted_at === null || row.first_admitted_at > now
    ? '입장 시각 미확인' : formatElapsedCompact(now - row.first_admitted_at)
}
function groupLabel(rows: readonly KeeperQueueRow[], key: 'keeper_name' | 'source'): string {
  return Object.entries(queueCounts(rows, key)).map(([name, count]) => `${name} ${count}건`).join(' · ')
}

export function KeeperEventQueuePanel() {
  const authority = executionWorkspaceAuthority.value
  const access = dashboardAuthAccess(shellAuthSummary.value, 'admin')
  // Credential/actor changes withdraw a retained preview even before a click.
  const credentialRevision = storedTokenRevision.value
  const actorRevision = dashboardActorRevision.value
  const managedRevision = managedDashboardActorRevision.value
  const managedAuthRevision = managedDashboardAuthRevision.value
  const unverified = managedDashboardUnverified.value
  const [keeper, setKeeper] = useState('')
  const [source, setSource] = useState('')
  const [reading, setReading] = useState<Reading | null>(null)
  const [selectedKeys, setSelectedKeys] = useState<ReadonlySet<string>>(new Set())
  const [reason, setReason] = useState('')
  const [plan, setPlan] = useState<KeeperQueuePlan | null>(null)
  const [confirmed, setConfirmed] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const requestVersion = useRef(0)
  const readController = useRef<AbortController | null>(null)
  const operation = keeperQueueOperation.value
  const sending = operation.kind === 'sending'
  const filter: KeeperQueueFilter = {
    ...(keeper.trim() ? { keepers: [keeper.trim()] } : {}),
    ...(source.trim() ? { sources: [source.trim()] } : {}),
  }
  const filterKey = JSON.stringify(filter)
  const currentReading = reading !== null && reading.filterKey === filterKey && ownerIsCurrent(reading.owner) ? reading : null
  const rows = currentReading?.preview.rows ?? []
  const selected = rows.filter(row => selectedKeys.has(queueRowKey(row)))
  const currentPlan = plan !== null && keeperQueuePlanIsCurrent(plan) && currentReading !== null ? plan : null
  const ownsOperation = operation.kind !== 'idle' && authority !== null
    && operation.attempt.plan.authority.workspaceRoot === authority.workspaceRoot
    && dashboardCredentialOwnerIsCurrent(operation.attempt.plan.credentials)

  function invalidate() {
    requestVersion.current++
    readController.current?.abort()
    setLoading(false); setReading(null); setSelectedKeys(new Set()); setPlan(null); setConfirmed(false); setError(null)
  }
  useEffect(() => {
    invalidate()
    return () => { requestVersion.current++; readController.current?.abort() }
  }, [authority, credentialRevision, actorRevision, managedRevision, managedAuthRevision, unverified])

  async function load() {
    if (authority === null || !access.allowed || loading || sending) return
    invalidate()
    const version = requestVersion.current
    const owner: Owner = { authority, credentials: captureDashboardCredentialOwner() }
    const controller = new AbortController()
    readController.current = controller
    setLoading(true)
    const current = () => version === requestVersion.current && ownerIsCurrent(owner) && !controller.signal.aborted
    try {
      const preview = await previewKeeperQueue(authority.workspaceRoot, filter, controller.signal)
      if (current()) setReading({ owner, filterKey, preview })
    } catch {
      if (current()) setError('대기열을 읽지 못했습니다. 권한과 서버 연결을 확인한 뒤 다시 조회하세요.')
    } finally { if (current()) setLoading(false) }
  }
  function choose(key: string, checked: boolean) {
    setSelectedKeys(previous => { const next = new Set(previous); if (checked) next.add(key); else next.delete(key); return next })
    setPlan(null); setConfirmed(false)
  }
  function prepare() {
    if (currentReading === null || selected.length === 0 || reason.trim() === '' || sending) return
    setPlan({ ...currentReading.owner, filter, rows: selected, reason: reason.trim() })
    setConfirmed(false)
  }
  async function execute() {
    if (currentPlan === null || !confirmed || sending) return
    const submitted = currentPlan
    setPlan(null); setConfirmed(false); setSelectedKeys(new Set()); setReading(null)
    await executeKeeperQueuePlan(submitted)
  }
  const readback = operation.kind === 'settled' || operation.kind === 'unknown' ? operation.readback : undefined
  const remaining = readback?.kind === 'ready'
    ? new Set(readback.preview.rows.map(queueRowKey)) : null

  return html`<section class="grid gap-3 text-xs" aria-label="Keeper 대기열 취소">
    <p>저장된 대기 이벤트를 확인하고 선택한 항목을 취소합니다. 실행 중인 턴·임대 상태는 이 목록에서 관측하지 않습니다.</p>
    <div class="flex flex-wrap items-end gap-2">
      <label>Keeper 이름<input aria-label="Keeper 이름 필터" class=${inputClass} value=${keeper} disabled=${sending}
        onInput=${(event: Event) => { invalidate(); setKeeper((event.currentTarget as HTMLInputElement).value) }} /></label>
      <label>이벤트 종류<input aria-label="이벤트 종류 필터" class=${inputClass} value=${source} disabled=${sending}
        placeholder="예: bootstrap" onInput=${(event: Event) => { invalidate(); setSource((event.currentTarget as HTMLInputElement).value) }} /></label>
      <${ActionButton} variant="ghost" size="sm" disabled=${authority === null || !access.allowed || loading || sending}
        onClick=${() => { void load() }}>${loading ? '조회 중…' : '대기열 조회'}<//>
    </div>
    ${authority === null ? html`<p role="status">현재 작업 공간을 확인한 뒤 조회할 수 있습니다.</p>` : null}
    ${!access.allowed ? html`<p role="status">관리자 권한이 필요합니다. ${access.reason}</p>` : null}
    ${error ? html`<p role="alert">${error}</p>` : null}
    ${currentReading ? html`
      <p>현재 필터의 대기 ${rows.length}건 · 가장 오래 대기한 시간 ${currentReading.preview.oldest_age_seconds === null ? '미확인' : formatElapsedCompact(currentReading.preview.oldest_age_seconds)}</p>
      <div class="max-h-[30rem] overflow-auto"><table class="w-full text-left"><caption class="sr-only">취소 대상을 선택할 수 있는 저장 대기열</caption>
        <thead><tr><th><input type="checkbox" aria-label="조회한 항목 모두 선택" disabled=${sending || rows.length === 0}
          checked=${rows.length > 0 && selected.length === rows.length} onChange=${(event: Event) => {
            setSelectedKeys((event.currentTarget as HTMLInputElement).checked ? new Set(rows.map(queueRowKey)) : new Set())
            setPlan(null); setConfirmed(false)
          }} /></th><th>Keeper</th><th>종류</th><th>상태</th><th>대기 시간</th><th>대상 식별자</th></tr></thead>
        <tbody>${rows.map(row => html`<tr key=${queueRowKey(row)} class="border-t border-[var(--color-border-subtle)] align-top">
          <td><input type="checkbox" aria-label=${`${row.keeper_name} ${row.source_ref} ${row.source_incarnation} 선택`}
            checked=${selectedKeys.has(queueRowKey(row))} disabled=${sending}
            onChange=${(event: Event) => choose(queueRowKey(row), (event.currentTarget as HTMLInputElement).checked)} /></td>
          <td>${row.keeper_name}</td><td>${row.source}</td><td>대기</td><td>${age(row)}</td>
          <td><code class="break-all">${row.source_ref}</code><div>버전 ${row.source_incarnation}</div></td>
        </tr>`)}</tbody></table></div>
      ${rows.length === 0 ? html`<p>현재 필터에 저장된 대기 항목이 없습니다.</p>` : null}
      <label>취소 사유<input aria-label="취소 사유" class=${inputClass} value=${reason} disabled=${sending}
        onInput=${(event: Event) => { setReason((event.currentTarget as HTMLInputElement).value); setPlan(null); setConfirmed(false) }} /></label>
      <${ActionButton} variant="ghost" size="sm" disabled=${sending || selected.length === 0 || reason.trim() === ''}
        onClick=${prepare}>선택 ${selected.length}건 취소 내용 확인<//>
    ` : null}
    ${currentPlan ? html`<div class="grid gap-2 rounded border border-[var(--color-border-default)] p-3" role="group" aria-label="취소 내용 확인">
      <p>취소할 대기 항목 ${currentPlan.rows.length}건</p>
      <p>${groupLabel(currentPlan.rows, 'keeper_name')}</p><p>${groupLabel(currentPlan.rows, 'source')}</p>
      <p>사유: ${currentPlan.reason}</p><p>확인한 식별자와 버전만 취소합니다. 이후 새로 들어온 항목은 포함하지 않습니다.</p>
      <p>대상 기록은 실행 전에 서버에 저장됩니다. 이 기록으로 원래 이벤트 전체를 복원할 수는 없습니다.</p>
      <label><input type="checkbox" aria-label="선택한 대기 항목 취소 확인" checked=${confirmed}
        onChange=${(event: Event) => setConfirmed((event.currentTarget as HTMLInputElement).checked)} />선택한 대기 항목을 취소하겠습니다.</label>
      <${ActionButton} variant="danger" size="sm" disabled=${!confirmed || sending}
        onClick=${() => { void execute() }}>확인한 ${currentPlan.rows.length}건 취소<//>
    </div>` : null}
    ${sending ? html`<div role="status"><p>취소 결과를 확인하고 있습니다. 화면을 이동해도 이 탭에서 결과를 보관합니다.</p>
      <${ActionButton} variant="ghost" size="sm" onClick=${stopKeeperQueueResponse}>응답 확인 중단<//></div>` : null}
    ${operation.kind !== 'idle' && !ownsOperation ? html`<p role="status">다른 작업 공간 또는 인증으로 보낸 취소 요청 기록이 있습니다. 해당 환경에서 결과를 확인하세요.</p>` : null}
    ${ownsOperation && operation.kind === 'unknown' ? html`<p role="alert">${operation.message}</p>` : null}
    ${ownsOperation && operation.kind === 'settled' ? html`<div role="status">
      <p>취소 완료 ${operation.report.cancelled}건 · 취소 저장 후 마무리 미완료 ${operation.report.committed_followup_failed}건 · 처리 실패 ${operation.report.failed}건</p>
      <p>작업 ${operation.report.operation_id}</p><p>대상 기록: ${operation.report.backup_path}</p>
      <ul>${operation.report.results.map(result => html`<li key=${queueRowKey(result.row)}>
        ${result.row.keeper_name} · <code class="break-all">${result.row.source_ref}</code> · 버전 ${result.row.source_incarnation}:
        ${result.status === 'cancelled' ? '취소 완료' : result.status === 'failed' ? `처리 실패: ${result.error}` : `취소는 저장됨 · ${result.result.stage} 마무리 실패: ${result.result.detail}`}
      </li>`)}</ul></div>` : null}
    ${ownsOperation && remaining ? html`<p>재조회: 확인한 대상 중 ${operation.attempt.plan.rows.filter(row => remaining.has(queueRowKey(row))).length}건이 같은 버전으로 대기 중입니다. 대기열에서 사라졌다는 사실만으로 취소 원인을 확정하지 않습니다.</p>` : null}
    ${ownsOperation && readback?.kind === 'unavailable' ? html`<p role="alert">${readback.message}</p>` : null}
    ${ownsOperation && readback?.kind === 'loading' ? html`<p role="status">취소 요청 이후 대기열을 다시 확인하고 있습니다.</p>` : null}
    ${ownsOperation && (operation.kind === 'settled' || operation.kind === 'unknown') ? html`<${ActionButton} variant="ghost" size="sm"
      disabled=${readback?.kind === 'loading'} onClick=${() => { void readbackKeeperQueueOperation() }}>요청 대상 재조회<//>` : null}
  </section>`
}
