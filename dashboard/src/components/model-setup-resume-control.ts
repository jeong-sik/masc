import { html } from 'htm/preact'
import { modelSetupResumeState, resumeSavedModelSetup } from '../lib/model-setup-resume'

export function ModelSetupResumeControl({ disabled = false, onComplete }: {
  disabled?: boolean; onComplete?: () => Promise<void> | void
}) {
  const state = modelSetupResumeState.value
  async function resume() {
    if (disabled || modelSetupResumeState.peek().kind === 'resuming') return
    await resumeSavedModelSetup()
    await onComplete?.()
  }
  return html`<div class="set-card" aria-label="저장한 모델 설정 적용">
    <button type="button" class="btn" disabled=${disabled || state.kind === 'resuming'} onClick=${resume}>
      ${state.kind === 'resuming' ? '설정을 적용하고 있습니다…' : '설정 재개'}
    </button>
    ${state.kind === 'active' ? html`<p role="status">저장한 모델 설정을 실행 중인 서버에 적용했습니다.
      ${state.exactOutputAvailable ? '' : '작업 완료 검증용 모델 연결은 추가 설정이 필요합니다.'}
      모델 응답과 도구 검증 결과는 준비 상태에서 별도로 확인하세요.</p>` : null}
    ${state.kind === 'failed' ? html`<p role="status">${state.reason === 'upgrade_required'
      ? '현재 서버 버전은 설정 재개를 지원하지 않습니다. 설치된 MASC로 작업 공간 서버를 업그레이드하세요.'
      : state.reason === 'access_required'
        ? '소유자 로그인이 필요합니다. 로그인한 뒤 설정 재개를 다시 누르세요.'
        : '모델 설정을 적용하지 못했습니다. 연결 설정을 확인한 뒤 설정 재개를 다시 누르세요.'}</p>` : null}
    <p class="set-hint">재개는 저장한 연결을 적용합니다. 실제 대화·도구·sandbox 검증을 실행하거나 통과로 표시하지 않습니다.</p>
  </div>`
}
