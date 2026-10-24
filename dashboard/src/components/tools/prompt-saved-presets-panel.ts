import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import {
  fetchPromptPresetDetail, fetchPromptPresets, promptPresetReportNeedsAttention,
  type PreservedLaneSettings, type PromptPresetDetail, type PromptPresetListing,
  type PromptPresetReport,
} from '../../api/prompt-presets'
import { storedTokenRevision } from '../../api/token-revision'
import { executionWorkspaceAuthority, refreshExecution } from '../../store'
import { ownsPromptPresetRequest, promptPresetSessionFor, type PromptPresetOwner, type PromptPresetSession } from '../../lib/prompt-preset-session'
import { errorToString } from '../../lib/format-string'
import { ActionButton } from '../common/button'
import { TextInput } from '../common/input'

function PreservedSettings({ settings }: { settings: PreservedLaneSettings }) {
  if (settings.length === 0) return null
  return html`<div class="my-2 rounded-[var(--r-1)] border border-[var(--warn-border)] p-3" data-preset-preserved-settings>
    <p>저장본에 기록되지 않은 요청 설정은 현재 값을 유지합니다.</p>
    <details class="mt-1 text-xs"><summary>현재 값을 유지할 설정 ${settings.length}개 보기</summary>
      <ul>${settings.map(row => html`<li key=${`${row.lane}:${row.setting}`}><code>${row.lane}.${row.setting}</code></li>`)}</ul>
    </details>
  </div>`
}

function RestoreReport({ report }: { report: PromptPresetReport }) {
  return html`<div class="mt-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] p-3"
    role="status" data-preset-report data-needs-attention=${String(promptPresetReportNeedsAttention(report))}>
    <p>${report.restored} 복원 결과 · 직전 설정 백업: <code>${report.autosave}</code></p>
    ${promptPresetReportNeedsAttention(report) ? html`<p role="alert">일부 설정이 제외됐거나 적용 확인이 필요합니다. 아래 결과를 확인하세요.</p>` : null}
    ${[
      { label: '프롬프트 override', part: report.prompt_overrides }, { label: 'Keeper 지시문', part: report.instructions },
    ].map(({ label, part }) => {
      return html`<div class="mt-2"><p>${label}: 적용 ${part.applied.length} · 제외 ${part.skipped.length} · ${part.effect === 'immediate' ? '즉시 반영' : '각 Keeper의 다음 up/턴에 반영'}</p>
        ${part.skipped.map(row => html`<p class="text-xs" key=${row.key}>${row.key}: ${row.reason}</p>`)}</div>`
    })}
    ${report.runtime.status === 'failed'
      ? html`<p>Runtime 적용 실패: ${report.runtime.error}</p>`
      : report.runtime.status === 'unchanged'
        ? html`<p>Runtime: 파일 변경 없음.</p>`
        : html`<div>
          <p>Runtime: 파일 적용됨 · 디스크 저장 ${report.runtime.commit.durability === 'durable' ? '확인' : '내구성 미확인'}</p>
          ${report.runtime.commit.durability_detail ? html`<p>${report.runtime.commit.durability_detail}</p>` : null}
          ${report.runtime.commit.warnings.map(warning => html`<p key=${warning.code}>${warning.detail}</p>`)}
          <p>실행 레인: ${report.runtime.exact_output_registry.status === 'applied' ? '반영됨'
            : report.runtime.exact_output_registry.status === 'unpublished' ? '재시작 필요'
              : `기존 레인 유지 · ${report.runtime.exact_output_registry.reason}`}</p>
        </div>`}
    <p class="mt-2 text-xs">Keeper 지시문은 각 Keeper의 다음 up/턴부터 반영됩니다. 적용 제외와 Runtime 경고가 있으면 함께 확인하세요.</p>
    ${(report.skipped_lanes?.length || report.skipped_assignments?.length) ? html`<div class="my-2" data-preset-runtime-exclusions>
      <p>기존 설정 유지 · Runtime 배정 ${report.skipped_assignments?.length ?? 0}개 · 레인 ${report.skipped_lanes?.length ?? 0}개 복원 제외</p>
      <details class="mt-1 text-xs"><summary>제외한 설정과 사유 보기</summary>
        ${report.skipped_lanes?.map(row => html`<p class="mt-2 break-words" key=${row.lane}>레인 · <code>${row.lane}</code>: ${row.reason}</p>`)}
        ${report.skipped_assignments?.map(row => html`<p class="mt-2 break-words" key=${row.keeper}>Runtime 배정 · <code>${row.keeper}</code>: ${row.reason}</p>`)}
      </details>
    </div>` : null}
    <${PreservedSettings} settings=${report.preserved_lane_settings ?? []} />
  </div>`
}

type Props = {
  disabledReason?: string | null
  onRestored?: () => void
  onBusyChange?: (busy: boolean) => void
}

export function PromptSavedPresetsPanel(props: Props) {
  const authority = executionWorkspaceAuthority.value
  const credentialRevision = storedTokenRevision.value
  const [verifyError, setVerifyError] = useState<string | null>(null)
  async function verify() {
    setVerifyError(null)
    try { await refreshExecution({ force: true }) }
    catch (error) { setVerifyError(errorToString(error)) }
  }
  if (authority === null) return html`<section><p>작업공간을 확인한 뒤 저장 프리셋을 사용할 수 있습니다.</p>
    <${ActionButton} variant="ghost" size="sm" onClick=${() => { void verify() }}>작업공간 확인<//>
    ${verifyError ? html`<p role="alert">${verifyError}</p>` : null}</section>`
  return html`<${PromptSavedPresetsContent} key=${authority.workspaceRoot} ...${props}
    owner=${{ authority, credentialRevision }} session=${promptPresetSessionFor(authority)} />`
}

function PromptSavedPresetsContent({
  disabledReason = null, onRestored, onBusyChange,
  owner, session,
}: Props & { owner: PromptPresetOwner; session: PromptPresetSession }) {
  const [listing, setListing] = useState<PromptPresetListing | null>(null)
  const [reading, setReading] = useState(false)
  const [readError, setReadError] = useState<string | null>(null)
  const [selected, setSelected] = useState('')
  const [detail, setDetail] = useState<PromptPresetDetail | null>(null)
  const [detailError, setDetailError] = useState<string | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [refresh, setRefresh] = useState(0)
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [armed, setArmed] = useState<string | null>(null)
  const { operation: outcome, needsRead } = session.state.value
  const busy = outcome?.result.kind === 'pending'
  const [basis, setBasis] = useState(owner)
  const readGeneration = useRef(0)
  const reconcileDemand = useRef<number | null>(null)
  const mounted = useRef(true)

  async function load(preferred?: string, reconcile = false) {
    if (!ownsPromptPresetRequest(owner)) return
    const generation = ++readGeneration.current
    const uncertainty = session.state.peek().uncertainty
    setReading(true)
    setReadError(null)
    setArmed(null)
    try {
      const next = await fetchPromptPresets()
      if (!mounted.current || !ownsPromptPresetRequest(owner) || generation !== readGeneration.current) return
      setListing(next)
      if (reconcile && next.presets.length === 0 && next.unreadable.length === 0) session.reconcile(owner, uncertainty)
      reconcileDemand.current = reconcile ? uncertainty : null
      setSelected(current => {
        const candidate = preferred ?? current
        return next.presets.some(row => row.name === candidate) ? candidate : next.presets[0]?.name ?? ''
      })
      setRefresh(value => value + 1)
    } catch (error) {
      if (mounted.current && ownsPromptPresetRequest(owner) && generation === readGeneration.current) setReadError(errorToString(error))
    } finally {
      if (mounted.current && ownsPromptPresetRequest(owner) && generation === readGeneration.current) setReading(false)
    }
  }

  useEffect(() => {
    mounted.current = true
    setBasis(owner); setListing(null); setSelected(''); setDetail(null); setArmed(null); setName(''); setDescription('')
    void load()
    return () => { mounted.current = false; readGeneration.current += 1 }
  }, [owner.authority, owner.credentialRevision])

  useEffect(() => { onBusyChange?.(busy); return () => onBusyChange?.(false) }, [busy, onBusyChange])

  useEffect(() => {
    let active = true
    const uncertainty = reconcileDemand.current
    reconcileDemand.current = null
    setArmed(null)
    setDetail(null)
    setDetailError(null)
    if (!selected || basis.authority !== owner.authority || basis.credentialRevision !== owner.credentialRevision) { setDetailLoading(false); return }
    setDetailLoading(true)
    void fetchPromptPresetDetail(selected).then(value => {
      if (!active || !ownsPromptPresetRequest(owner)) return
      if (value.preset.name !== selected) throw new Error('선택한 프리셋과 상세 응답이 일치하지 않습니다.')
      setDetail(value)
      if (uncertainty !== null) session.reconcile(owner, uncertainty)
    }).catch(error => { if (active && ownsPromptPresetRequest(owner)) setDetailError(errorToString(error)) })
      .finally(() => { if (active && ownsPromptPresetRequest(owner)) setDetailLoading(false) })
    return () => { active = false }
  }, [selected, refresh, owner.authority, owner.credentialRevision, basis])

  async function mutate(action: 'save' | 'restore') {
    if (!ownsPromptPresetRequest(owner) || busy || disabledReason || needsRead || reading) return
    const target = action === 'save' ? name.trim() : selected
    if (!target || (action === 'restore' && (!detail || detailLoading || armed !== selected))) return
    if (action === 'save' && (!listing || [...listing.presets, ...listing.unreadable].some(row => row.name === target))) return
    setArmed(null)
    const result = await session.write(owner, action, target, description)
    if (result && mounted.current && ownsPromptPresetRequest(owner)) {
      if (result.result.kind === 'confirmed') {
        if (action === 'save') { setName(''); setDescription('') }
        else onRestored?.()
        void load(target)
      }
    }
  }

  const duplicate = listing !== null && [...listing.presets, ...listing.unreadable].some(row => row.name === name.trim())
  const blocked = busy || reading || disabledReason !== null || needsRead
  const viewed = detail?.preset.name === selected ? detail : null

  if (basis.authority !== owner.authority || basis.credentialRevision !== owner.credentialRevision) return html`<p role="status">현재 작업공간의 저장본을 다시 확인합니다…</p>`

  return html`<section class="mb-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] p-4" aria-label="저장한 프롬프트 설정" data-prompt-saved-presets>
    <div class="flex flex-wrap items-center justify-between gap-2">
      <h3 class="text-sm font-semibold">저장한 프롬프트 설정</h3>
      <${ActionButton} size="sm" variant="ghost" disabled=${busy || reading} onClick=${() => { void load(undefined, true) }} testId="prompt-presets-refresh">${reading ? '읽는 중…' : '새로고침'}<//>
    </div>
    <p class="my-2 text-xs text-[var(--color-fg-muted)]">프롬프트 override, Keeper 지시문, Runtime 배정과 레인 설정을 함께 저장·복원합니다. 기본 프롬프트 파일은 현재 버전을 사용합니다.</p>
    ${readError ? html`<p role="alert">목록 조회 실패${listing ? ' · 마지막 목록을 표시합니다' : ''}: ${readError}</p>` : null}
    ${listing && listing.presets.length === 0 ? html`<p>${listing.unreadable.length ? '저장본을 읽지 못했습니다. 아래 원인을 확인하세요.' : '저장한 설정이 없습니다.'}</p>` : null}
    ${listing?.unreadable.map(row => html`<p class="my-2 break-words text-xs" role="alert" key=${row.name}><strong>${row.name}</strong> · ${row.reason}</p>`)}
    ${listing && listing.presets.length > 0 ? html`
      <label class="block text-xs">저장본 선택
        <select class="mt-1 w-full rounded-md border border-border bg-[var(--color-bg-surface)] p-2" aria-label="저장본 선택" data-testid="prompt-presets-select"
          value=${selected} disabled=${busy} onChange=${(event: Event) => { setArmed(null); setSelected((event.target as HTMLSelectElement).value) }}>
          ${listing.presets.map(row => html`<option key=${row.name} value=${row.name}>${row.name} · ${row.created_at}</option>`)}
        </select>
      </label>
      ${detailLoading ? html`<p role="status">저장된 설정을 읽는 중…</p>` : null}
      ${detailError ? html`<p role="alert">상세 조회 실패: ${detailError}</p>` : null}
      ${viewed ? html`<div class="my-3 text-xs" data-preset-detail=${viewed.preset.name}>
        <p>${viewed.preset.description || '설명 없음'}</p>
        <p>현재 설정: ${viewed.saved_settings.status === 'unavailable' ? `비교 불가 · ${viewed.saved_settings.reason}`
          : viewed.saved_settings.status === 'matches' ? '저장본과 같음' : '저장본과 다름'}</p>
        <p>Override ${viewed.preset.prompt_overrides.length} · Keeper 지시문 ${viewed.preset.instructions.length} · Runtime 배정 ${viewed.preset.assignments.length} · 레인 ${viewed.preset.lanes.length}</p>
        <details class="my-2"><summary>바뀌는 설정 보기</summary>
          <p>Override: ${viewed.preset.prompt_overrides.map(row => row.key).join(', ') || '없음'}</p>
          <p>지시문: ${viewed.preset.instructions.map(row => row.keeper_file).join(', ') || '없음'}</p>
          <p>배정: ${viewed.preset.assignments.map(row => `${row.keeper} → ${row.runtime}`).join(', ') || '없음'}</p>
          <p>레인: ${viewed.preset.lanes.map(row => row.id).join(', ') || '없음'}</p>
          <p class="break-all">저장 위치: ${viewed.directory}</p>
        </details>
        ${viewed.default_prompts.status === 'differs' ? html`<p>기본 프롬프트 ${viewed.default_prompts.changes.length}개가 저장 당시와 다릅니다. 복원해도 현재 기본값을 사용합니다.</p>`
          : viewed.default_prompts.status === 'unknown' ? html`<p>저장 당시 기본 프롬프트의 비교 기준이 없습니다.</p>` : null}
        <${PreservedSettings} settings=${viewed.preset.preserved_lane_settings ?? []} />
        ${viewed.preset.skipped_lanes?.map(row => html`<p role="alert" key=${row.lane}>레인 복원 제외 · ${row.lane}: ${row.reason}</p>`)}
      </div>` : null}
      ${armed === selected ? html`<div class="my-2 rounded-[var(--r-1)] border border-[var(--warn-border)] p-3" data-preset-confirmation>
        <p>${selected}의 저장된 설정으로 복원합니다. 현재 설정은 _autosave에 먼저 백업됩니다. 다음 복원은 이 백업을 덮어씁니다.</p>
        <p class="mt-1 text-xs">Keeper 지시문은 각 Keeper의 다음 up/턴부터 반영됩니다.</p>
        <p class="mt-1 text-xs">현재 Runtime이 거절한 배정·레인은 기존 값을 유지하고 적용 제외로 보고합니다.</p>
        <${ActionButton} variant="primary" size="sm" disabled=${blocked || !viewed || detailLoading} testId="prompt-presets-confirm" onClick=${() => { void mutate('restore') }}>확인 · 복원<//>
        <${ActionButton} variant="ghost" size="sm" disabled=${busy} onClick=${() => setArmed(null)}>취소<//>
      </div>` : html`<${ActionButton} size="sm" variant="ghost" disabled=${blocked || !viewed || detailLoading || detailError !== null} testId="prompt-presets-restore" onClick=${() => setArmed(selected)}>이 저장본 복원…<//>`}
    ` : null}
    <form class="mt-3 grid gap-2" onSubmit=${(event: Event) => { event.preventDefault(); void mutate('save') }}>
      <label class="text-xs">새 저장본 이름<${TextInput} ariaLabel="새 저장본 이름" testId="prompt-presets-name" value=${name} disabled=${busy} onInput=${(event: Event) => setName((event.target as HTMLInputElement).value)} /></label>
      <label class="text-xs">설명<${TextInput} ariaLabel="저장본 설명" value=${description} disabled=${busy} onInput=${(event: Event) => setDescription((event.target as HTMLInputElement).value)} /></label>
      ${duplicate ? html`<p role="status" class="text-xs">이 이름의 저장본이 있습니다. 다른 이름으로 저장하세요.</p>` : null}
      <${ActionButton} type="submit" size="sm" variant="ghost" disabled=${blocked || !listing || duplicate || !name.trim()} testId="prompt-presets-save">현재 설정을 새 이름으로 저장<//>
    </form>
    ${disabledReason ? html`<p class="mt-2 text-xs">${disabledReason}</p>` : null}
    ${busy ? html`<p role="status">설정 작업 중…</p>` : null}
    ${outcome && !ownsPromptPresetRequest(outcome.owner) ? html`<p role="status">이전 연결에서 시작한 ${outcome.name} 작업의 진행·결과를 보관하고 있습니다.</p>` : null}
    ${outcome?.result.kind === 'refused' ? html`<p class="mt-2" role="alert">요청 거절: ${outcome.result.detail}</p>` : null}
    ${outcome?.result.kind === 'unconfirmed' ? html`<div class="mt-2" data-preset-write-unconfirmed>
      <p role="alert">${outcome.name} ${outcome.action === 'restore' ? '복원' : '저장'} 결과 미확인 · 이미 적용됐을 수 있습니다. 자동으로 다시 보내지 않습니다. 새로고침하여 현재 설정을 확인하세요.</p>
      <details class="mt-1 text-xs"><summary>응답 진단 보기</summary><pre class="overflow-auto whitespace-pre-wrap break-words">${outcome.result.detail}</pre></details>
    </div>` : null}
    ${needsRead && outcome?.result.kind !== 'unconfirmed' ? html`<p role="status">이전 작업 뒤 현재 설정을 다시 읽어야 새 작업을 시작할 수 있습니다.</p>` : null}
    ${outcome?.action === 'save' && outcome.result.kind === 'confirmed' ? html`<p class="mt-2" role="status">${outcome.name} 저장됨</p>` : null}
    ${outcome?.action === 'restore' && outcome.result.kind === 'confirmed' ? html`<${RestoreReport} report=${outcome.result.value} />` : null}
  </section>`
}
