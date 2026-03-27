import { html } from 'htm/preact'
import { CARD_STANDARD } from '../common/card'
import { navigate } from '../../router'

const ACTION_BUTTON =
  'px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]'

export function WarroomGuideCallout() {
  return html`
    <section class="${CARD_STANDARD}" data-guide-banner="warroom">
      <div class="flex items-start justify-between gap-3 flex-wrap">
        <div class="grid gap-2">
          <div class="flex items-center gap-2 flex-wrap">
            <strong class="text-[13px] text-[var(--text-strong)]">관제면은 실험 화면입니다.</strong>
            <span class="px-2 py-0.5 rounded-full border border-[rgba(251,191,36,0.2)] bg-[var(--warn-12)] text-[10px] text-[var(--warn)]">
              메인 메뉴 숨김
            </span>
          </div>
          <span class="text-[12px] text-[var(--text-muted)] leading-[1.5]">
            오케스트라, 스웜, 체인 제어는 아직 실험 단계입니다. 기본 운영은 실시간 개입 화면에서 하고,
            검증 기준과 진입 경로는 실험실의 실험 섹션에서 확인합니다.
          </span>
        </div>
        <div class="flex gap-2 flex-wrap">
          <button
            type="button"
            class=${ACTION_BUTTON}
            onClick=${() => navigate('lab', { section: 'experiments' })}
          >
            실험 안내
          </button>
          <button
            type="button"
            class=${ACTION_BUTTON}
            onClick=${() => navigate('command', { section: 'intervene' })}
          >
            실시간 개입 열기
          </button>
        </div>
      </div>
    </section>
  `
}
