import { html } from 'htm/preact'
import type { ExactSlotObservation, RetainedSlotObservation, SlotHttpBinding,
  SlotMatrixState, SlotObservationState, SlotOutcome } from '../api/exact-slot-observations'
import { formatDateTimeKo } from '../lib/format-time'

const card = 'rounded border border-[var(--color-border-default)] p-3 space-y-2'
function outcomeLabel(outcome: SlotOutcome): string {
  switch (outcome.kind) {
    case 'unresolved': return '결과 미확인'
    case 'accepted': return '수락'
    case 'semantic_rejected': return '의미 검증 거절'
    case 'admission_rejected': return `실행 전 거절 · ${outcome.cause}`
    case 'execution_failed': return `실행 실패${outcome.httpStatus === undefined ? '' : ` · HTTP ${outcome.httpStatus}`} · ${outcome.cause}`
    case 'cli_failed': return `클라이언트 실패 · ${outcome.cause}`
  }
}
function Binding({ value }: { value: SlotHttpBinding }) {
  return html`<div class="break-all">
    <p>${value.providerKind} · provider ${value.providerId ?? '미기록'} · model <code>${value.modelId}</code></p>
    <code>${value.endpoint}</code>
  </div>`
}
function Observation({ value, runId }: { value: ExactSlotObservation; runId?: string }) {
  const binding = value.binding
  return html`<div class="space-y-1">
    <p>${outcomeLabel(value.outcome)} · 단계 <code>${value.phase}</code></p>
    <p class="break-all">실행 설정 경로: <code>${value.laneKey ?? '미관측'}</code></p>
    ${binding.kind === 'http' ? html`<div aria-label="실행 당시 주소"><span>실행 당시 주소</span><${Binding} value=${binding.value} /></div>`
      : html`<p>${binding.kind === 'official_client' ? '공식 클라이언트 · 공급자 주소 미관측' : '실행 당시 HTTP 주소 미관측'}</p>`}
    <p>실행 진입: ${value.startedAt === null ? '시각 미관측' : formatDateTimeKo(value.startedAt)}
      · 실행 반환: ${value.finishedAt === null ? '시각 미관측' : formatDateTimeKo(value.finishedAt)}</p>
    <p>${binding.kind === 'official_client'
      ? `클라이언트 호출: ${value.generationDispatched ? '관측됨' : '미관측'} · 원격 POST 여부 미관측`
      : `생성 요청 전송 시작: ${value.generationDispatched ? '관측됨' : '미관측'}`}</p>
    ${runId === undefined ? null : html`<p class="break-all">원본 run: <code>${runId}</code></p>`}
    <details><summary>실행 식별자</summary><dl class="break-all">
      ${[['call', value.callId], ['flow', value.flowId], ['visit', value.visitOrdinal],
        ['plan SHA-256', value.planFingerprint], ['request body SHA-256', value.requestBodySha256],
        ['catalog generation', value.catalogGeneration], ['catalog evidence', value.catalogEvidence],
        ['target identity', value.targetIdentity]].map(([label, text]) => html`<div key=${label}>
          <dt>${label}</dt><dd><code>${text ?? '미관측'}</code></dd>
        </div>`)}
    </dl></details>
  </div>`
}
function Retained({ label, value }: { label: string; value: RetainedSlotObservation | null }) {
  return html`<section aria-label=${label} class="space-y-1">
    <h5 class="font-semibold">${label}</h5>
    ${value === null ? html`<p>날짜가 확인된 관측 없음</p>`
      : html`<${Observation} value=${value.observation} runId=${value.runId} />`}
  </section>`
}
export function ExactRunSlotObservations({ value }: { value?: SlotObservationState }) {
  const state = value ?? { state: 'unobserved' as const }
  return html`<section aria-label="이 실행의 슬롯 관측" class=${card}>
    <h4 class="font-semibold">이 실행의 슬롯 관측</h4>
    ${state.state === 'unobserved' ? html`<p>보관된 슬롯 관측 없음 · 실행 여부 미확인</p>`
      : state.state === 'unavailable' ? html`<p role="status">슬롯 관측을 읽지 못했습니다: ${state.detail}</p>`
        : state.observations.length === 0 ? html`<p>이 실행에 기록된 슬롯 관측 없음 · 실행 여부 미확인</p>`
          : html`<p>시각은 실행기 진입·반환 기준입니다. 실행 반환은 의미 검증 완료 시각과 다를 수 있습니다.</p>
            <ol class="space-y-3">${state.observations.map((item, index) => html`<li key=${index} class=${card}>
              <h5 class="font-semibold">${index + 1}. <code>${item.slotId}</code></h5>
              <${Observation} value=${item} />
            </li>`)}</ol>`}
  </section>`
}
export function ExactLaneSlotStates({ value }: { value?: SlotMatrixState }) {
  const state = value ?? { state: 'unobserved' as const }
  return html`<section aria-label="슬롯별 실행 관측" class=${card}>
    <h4 class="font-semibold">슬롯별 실행 관측</h4>
    <p>마지막 관측은 실행 시각이 기록된 항목만 비교합니다. 실행 반환은 의미 검증 완료 시각과 다를 수 있습니다.</p>
    ${state.state === 'unobserved' ? html`<p>보관된 슬롯 관측 없음 · 실행 여부 미확인</p>`
      : state.state === 'unavailable' ? html`<p role="status">슬롯 관측을 읽지 못했습니다: ${state.detail}</p>`
        : html`${state.unavailableRuns > 0 ? html`<p role="status">조회 범위에서 ${state.unavailableRuns}개 run의 슬롯 관측을 읽지 못했습니다.</p>` : null}
          ${state.slots.length === 0 ? html`<p>선언되거나 보관된 슬롯 관측 없음</p>` : state.slots.map(slot => html`
            <section key=${`${slot.transport}/${slot.slotId}`} aria-label=${`${slot.slotId} ${slot.transport}`} class=${card}>
              <h5 class="font-semibold"><code>${slot.slotId}</code> · ${slot.transport === 'http' ? 'HTTP' : '공식 클라이언트'}
                · ${slot.declared ? '현재 선언' : '과거 기록만 보관'}</h5>
              <p class="break-all">설정 경로: <code>${slot.laneKey}</code></p>
              <div aria-label="현재 설정 주소"><h6 class="font-semibold">현재 설정 주소</h6>
                ${slot.currentBinding === null
                  ? html`<p>${slot.transport === 'official_client' ? '공식 클라이언트가 공급자 주소를 관리합니다.' : '현재 허용된 HTTP 주소 미관측'}</p>`
                  : html`<${Binding} value=${slot.currentBinding} />`}
              </div>
              ${slot.lastObservation === null ? html`<p>날짜가 확인된 슬롯 관측 없음 · 실행 여부 미확인</p>`
                : html`<${Retained} label="날짜가 확인된 마지막 관측" value=${slot.lastObservation} />`}
              <details><summary>마지막 시도·수락·실패</summary><div class="space-y-3">
                <${Retained} label="마지막 실행 진입" value=${slot.lastAttempt} />
                <${Retained} label="마지막 수락 · 실행 반환 기준" value=${slot.lastSuccess} />
                <${Retained} label="마지막 실패 · 실행 반환 기준" value=${slot.lastFailure} />
              </div></details>
              ${slot.undatedOutcomes.length === 0 ? null : html`<details>
                <summary>순서 미확인 결과 (${slot.undatedOutcomes.length})</summary>
                <p>실행 반환 시각이 없어 위 관측과 앞뒤 순서를 비교할 수 없습니다.</p>
                <ul class="space-y-3">${slot.undatedOutcomes.map((item, index) => html`<li key=${`${item.runId}/${index}`}>
                  <${Observation} value=${item.observation} runId=${item.runId} />
                </li>`)}</ul>
              </details>`}
            </section>`)}`}
  </section>`
}
