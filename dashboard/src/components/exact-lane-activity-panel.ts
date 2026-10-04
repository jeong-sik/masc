import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import type { StandaloneLaneSnapshotRow } from '../api/dashboard-standalone-lanes'
import { executionWorkspaceAuthority } from '../store'
import { exactLaneActivitySessionFor } from '../lib/exact-lane-activity-session'
import { readExactActivity } from '../lib/exact-lane-activity'
import { runtimeConfigCommitReceiptNotice } from '../lib/runtime-config-receipt'

const button = 'rounded border border-[var(--color-border-default)] px-3 py-2 disabled:opacity-50'
const label = (enabled: boolean) => enabled ? '켜짐' : '꺼짐'

export function ExactLaneActivityPanel({ lane }: { lane: StandaloneLaneSnapshotRow }) {
  const authority = executionWorkspaceAuthority.value
  const session = authority === null ? null : exactLaneActivitySessionFor(authority, lane)
  const open = session?.expanded.value ?? false
  const state = session?.state.value
  useEffect(() => {
    if (open && session && authority) void session.read(authority)
  }, [open, session, authority])
  if (!session || !authority || !state) return html`<p>작업공간을 확인한 뒤 활동 설정을 열 수 있습니다.</p>`
  const busy = state.phase !== 'idle', ready = session.ready(authority)
  const current = state.current ? readExactActivity(state.current.source_text, lane) : null
  const conflict = state.draft && state.current && (state.draft.base.source_revision !== state.current.source_revision
    || state.draft.base.source_path !== state.current.source_path)
  const changedPath = state.draft && state.current && state.draft.base.source_path !== state.current.source_path
  return html`<section class="rounded border border-[var(--color-border-default)] p-3 space-y-3" aria-label=${`${lane.label} 활동 설정`}>
    <button type="button" class=${button} aria-expanded=${open} onClick=${() => { session.expanded.value = !open }}>
      ${open ? '활동 설정 닫기' : '활동 설정 열기'}${session.modified() ? ' · 미저장 초안' : ''}
    </button>
    ${open ? html`<div class="space-y-3">
      <p>끄면 새 요청을 받지 않습니다. 이미 접수한 작업은 마무리하며 후보 설정은 보존합니다.</p>
      <p>관측 상태: ${lane.status} · ${lane.runningCount} 실행 중</p>
      <p role="status">${current ? `파일 설정: ${label(current.enabled)} · HTTP ${current.slots.length} / CLI ${current.cliSlots.length} 후보`
        : state.phase === 'reading' ? '현재 설정을 읽고 있습니다.' : '현재 파일 설정 미확인'}</p>
      ${state.draft ? html`<div class="space-y-2">
        <button type="button" class=${button} role="switch" aria-checked=${state.draft.enabled}
          aria-label=${`${lane.label} 활동 초안`} disabled=${!ready || !!changedPath || lane.required && state.draft.enabled}
          onClick=${() => session.toggle(authority)}>활동 초안: ${label(state.draft.enabled)}</button>
        ${lane.required ? html`<p>필수 Lane은 끌 수 없습니다.</p>` : null}
        ${conflict ? html`<p role="alert">파일이 바뀌었습니다. 초안은 보관했습니다. 활동 값만 현재 설정에 다시 적용하거나 초안을 버리세요.</p>` : null}
        ${changedPath ? html`<p role="alert">설정 파일 경로가 바뀌었습니다. 새 파일을 편집하려면 먼저 초안을 버리세요.</p>` : null}
      </div>` : null}
      <div class="flex flex-wrap gap-2">
        <button type="button" class=${button} disabled=${!ready || !session.modified() || !!conflict}
          onClick=${() => session.save(authority)}>${state.phase === 'saving' ? '활동 설정 저장 중…' : '활동 설정 저장'}</button>
        <button type="button" class=${button} disabled=${busy} onClick=${() => session.read(authority)}>현재 설정 읽기</button>
        ${conflict && !changedPath ? html`<button type="button" class=${button} disabled=${!ready}
          onClick=${() => session.reapply(authority)}>활동 값만 다시 적용</button>` : null}
        <button type="button" class=${button} disabled=${busy || !state.draft} onClick=${() => session.discard(authority)}>초안 버리기</button>
      </div>
      ${state.error ? html`<p role="alert">${state.error}</p>` : null}
      ${state.notice ? html`<p role="status">${state.notice}</p>` : null}
      ${state.receipt ? html`<p role="status">${runtimeConfigCommitReceiptNotice(state.receipt)}</p>` : null}
      ${state.setupResumeError ? html`<p role="alert">${state.setupResumeError}</p>` : null}
      ${state.followupError ? html`<p role="alert">${state.followupError}</p>` : null}
      <details><summary>설정 파일과 저장 기준</summary>
        <p class="break-all">${state.current?.source_path ?? state.draft?.base.source_path ?? '미확인'}</p>
        <p class="break-all">초안 기준: ${state.draft?.base.source_revision ?? '미확인'}</p>
        <p class="break-all">현재 파일: ${state.current?.source_revision ?? '미확인'}</p>
      </details>
    </div>` : null}
  </section>`
}
