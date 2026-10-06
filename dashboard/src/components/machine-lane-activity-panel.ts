import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { executionWorkspaceAuthority } from '../store'
import { machineLaneActivitySessionFor } from '../lib/machine-lane-activity-session'
import { readMachineActivity, type MachineActivityLane } from '../lib/machine-lane-activity'
import { runtimeConfigCommitReceiptNotice } from '../lib/runtime-config-receipt'

const button = 'rounded border border-[var(--color-border-default)] px-3 py-2 disabled:opacity-50'
const label = (enabled: boolean) => enabled ? '켜짐' : '꺼짐'

export function MachineLaneActivityPanel({ lane, title }: { lane: MachineActivityLane; title: string }) {
  const authority = executionWorkspaceAuthority.value
  const session = authority === null ? null : machineLaneActivitySessionFor(authority, lane)
  const open = session?.expanded.value ?? false
  const state = session?.state.value
  useEffect(() => {
    if (open && session && authority) void session.read(authority)
  }, [open, session, authority])
  if (!session || !authority || !state) return html`<p>작업공간을 확인한 뒤 활동 설정을 열 수 있습니다.</p>`
  const busy = state.phase !== 'idle', ready = session.ready(authority), uncertain = state.uncertain !== null
  const current = state.current ? readMachineActivity(state.current.source_text, lane) : null
  const observed = state.observation.kind === 'observed' ? state.observation : null
  const conflict = state.draft && state.current && (state.draft.base.source_revision !== state.current.source_revision
    || state.draft.base.source_path !== state.current.source_path)
  const changedPath = state.draft && state.current && state.draft.base.source_path !== state.current.source_path
  return html`<section class="rounded border border-[var(--color-border-default)] p-3 space-y-3" aria-label=${`${title} 활동 설정`}>
    <button type="button" class=${button} aria-expanded=${open} onClick=${() => { session.expanded.value = !open }}>
      ${open ? '활동 설정 닫기' : '활동 설정 열기'}${session.modified() ? ' · 미저장 초안' : ''}
    </button>
    ${open ? html`<div class="space-y-3">
      <p>끄면 새 실행과 입력을 받지 않습니다. 기계 상태와 checkpoint는 보존하며, 이미 접수한 작업과 상태 확인·저장·해제는 계속할 수 있습니다.</p>
      <p>켜도 기계를 불러오거나 checkpoint를 복구하지 않습니다.</p>
      <p role="status">${current ? `파일 설정: ${label(current.enabled)}`
        : state.phase === 'reading' ? '현재 설정을 읽고 있습니다.' : '현재 파일 설정 미확인'}</p>
      <p role="status">서버 활동 (마지막 조회): ${observed
        ? observed.activity === 'on' ? '켜짐' : observed.activity === 'off' ? '꺼짐' : '미확인'
        : '미확인'}</p>
      ${observed ? html`<p>조회 시각: ${new Date(observed.at * 1000).toISOString()}</p>` : null}
      ${state.observation.kind === 'failed' ? html`<p role="alert">${state.observation.error}</p>` : null}
      ${current && observed && observed.activity !== 'unobserved'
        && current.enabled !== (observed.activity === 'on')
        ? html`<p role="status">파일 설정과 마지막 서버 활동이 다릅니다. 현재 설정 읽기로 다시 확인하세요.</p>` : null}
      ${uncertain ? html`<p role="alert">이전 저장 결과는 미확정입니다. 현재 파일을 확인하고 활동 값만 다시 적용하거나 초안을 버리세요.</p>` : null}
      ${state.draft ? html`<div class="space-y-2">
        <button type="button" class=${button} role="switch" aria-checked=${state.draft.enabled}
          aria-label=${`${title} 활동 초안`} disabled=${!ready || !!changedPath}
          onClick=${() => session.toggle(authority)}>활동 초안: ${label(state.draft.enabled)}</button>
        ${conflict ? html`<p role="alert">파일이 바뀌었습니다. 초안은 보관했습니다. 활동 값만 현재 설정에 다시 적용하거나 초안을 버리세요.</p>` : null}
        ${changedPath ? html`<p role="alert">설정 파일 경로가 바뀌었습니다. 새 파일을 편집하려면 먼저 초안을 버리세요.</p>` : null}
      </div>` : null}
      <div class="flex flex-wrap gap-2">
        <button type="button" class=${button} disabled=${!ready || !session.modified() || !!conflict || uncertain}
          onClick=${() => session.save(authority)}>${state.phase === 'saving' ? '활동 설정 저장 중…' : '활동 설정 저장'}</button>
        <button type="button" class=${button} disabled=${busy} onClick=${() => session.read(authority)}>현재 설정 읽기</button>
        ${(conflict || uncertain) && !changedPath ? html`<button type="button" class=${button} disabled=${!ready}
          onClick=${() => session.reapply(authority)}>활동 값만 다시 적용</button>` : null}
        <button type="button" class=${button} disabled=${busy || !state.draft} onClick=${() => session.discard(authority)}>초안 버리기</button>
      </div>
      ${state.error ? html`<p role="alert">${state.error}</p>` : null}
      ${state.notice ? html`<p role="status">${state.notice}</p>` : null}
      ${state.receipt ? html`<p role="status">${runtimeConfigCommitReceiptNotice(state.receipt)}</p>` : null}
      ${state.followupError ? html`<p role="alert">${state.followupError}</p>` : null}
      <details><summary>설정 파일과 저장 기준</summary>
        <p class="break-all">${state.current?.source_path ?? state.draft?.base.source_path ?? '미확인'}</p>
        <p class="break-all">초안 기준: ${state.draft?.base.source_revision ?? '미확인'}</p>
        <p class="break-all">현재 파일: ${state.current?.source_revision ?? '미확인'}</p>
      </details>
    </div>` : null}
  </section>`
}
