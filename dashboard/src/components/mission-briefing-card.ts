import { html } from 'htm/preact'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { TagBadge } from './common/tag-badge'
import { ActionBar, ActionBtn } from './common/action-bar'
import { ProvenanceStrip } from './common/provenance-strip'
import {
  missionBriefing,
  missionBriefingError,
  missionBriefingLoading,
  refreshMissionBriefing,
} from '../mission-store'
import { missionTargetTypeLabel, relativeTime, signalClassLabel, statusLabel, toneClass } from './mission-utils'

export function MissionBriefingCard() {
  const briefing = missionBriefing.value
  const briefingTone = toneClass(briefing?.status ?? (missionBriefingError.value ? 'bad' : 'warn'))
  const showEmpty = !briefing || briefing.sections.length === 0
  const retryNeedsForce =
    briefing?.status === 'error'
    || (briefing?.status === 'unavailable' && !briefing?.cached)

  return html`
    <${Card} title="판단 레이어" class="mission-briefing-card rounded-xl">
      <div class="grid gap-1.5 mb-4">
        <h3>왜 그렇게 보이나</h3>
        <p>사회 truth를 읽은 뒤에만 별도 판단 결과를 참고하고, 근거는 접어서 둡니다.</p>
        <${ProvenanceStrip}
          items=${[
            { kind: 'narrative' },
            { kind: 'fallback', label: 'fallback on failure' },
          ]}
        />
      </div>

      <div class="flex gap-3 flex-wrap mb-4">
        <span class="cmd-chip rounded-full ${briefingTone}">
          ${statusLabel(briefing?.status ?? (missionBriefingError.value ? 'error' : 'loading'))}
        </span>
        ${briefing?.model ? html`<span class="cmd-chip rounded-full">${briefing.model}</span>` : null}
        ${briefing?.generated_at ? html`<span class="cmd-chip rounded-full">${relativeTime(briefing.generated_at)}</span>` : null}
        ${briefing?.cached ? html`<span class="cmd-chip rounded-full">캐시</span>` : null}
        ${briefing?.stale ? html`<span class="cmd-chip rounded-full warn">오래됨</span>` : null}
        ${briefing?.refreshing ? html`<span class="cmd-chip rounded-full warn">갱신 중</span>` : null}
      </div>

      ${missionBriefingError.value ? html`<${EmptyState} message=${missionBriefingError.value} compact />` : null}
      ${briefing?.error ? html`<${EmptyState} message=${briefing.error} compact />` : null}
      ${briefing?.summary ? html`<div class="grid gap-1.5">${briefing.summary}</div>` : null}
      ${briefing?.last_error && !briefing.error
        ? html`<div class="grid gap-1.5">최근 갱신 실패: ${briefing.last_error}</div>`
        : null}

      ${briefing && briefing.sections.length > 0
        ? html`
            <div class="grid grid-cols-3 gap-3 mt-3">
              ${briefing.sections.slice(0, 3).map(section => html`
                <article class="p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] grid gap-3 ${toneClass(section.status)}">
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <strong>${section.label}</strong>
                    <div class="flex gap-2 flex-wrap justify-end">
                      <span class="cmd-chip rounded-full ${toneClass(section.status)}">${statusLabel(section.status)}</span>
                      ${signalClassLabel(section.signal_class)
                        ? html`<span class="cmd-chip rounded-full ${section.signal_class === 'mixed' ? 'warn' : ''}">${signalClassLabel(section.signal_class)}</span>`
                        : null}
                      ${section.evidence_quality ? html`<span class="cmd-chip rounded-full">${section.evidence_quality}</span>` : null}
                    </div>
                  </div>
                  <p class="m-0 text-[rgba(255,255,255,0.8)] leading-normal">${section.summary}</p>
                  ${section.evidence.length > 0
                    ? html`
                        <details class="pt-2 border-t border-[var(--white-6)] mt-3">
                          <summary>근거 보기</summary>
                          <div class="flex gap-3 flex-wrap mt-3">
                            ${section.evidence.map(item => html`<${TagBadge}>${item}<//>`)}
                          </div>
                        </details>
                      `
                    : null}
                </article>
              `)}
            </div>
          `
        : (!missionBriefingLoading.value && !missionBriefingError.value && showEmpty
            ? html`
                <${EmptyState} message=${briefing?.status === 'pending'
                    ? '최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.'
                    : '판단 결과가 아직 없습니다.'} compact />
              `
            : null)}

      ${briefing && briefing.metadata_gaps.length > 0
        ? html`
            <details class="pt-2 border-t border-[var(--white-6)] mt-4">
              <summary>관측 공백 (${briefing.metadata_gap_count ?? briefing.metadata_gaps.length})</summary>
              <div class="flex flex-col gap-3 mt-3">
                ${briefing.metadata_gaps.map(item => html`
                  <article class="p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] grid gap-3 ${item.severity === 'watch' ? 'warn' : ''}">
                    <div class="flex justify-between gap-3 items-start flex-wrap">
                      <strong>${missionTargetTypeLabel(item.scope_type)}${item.scope_id ? ` · ${item.scope_id}` : ''}</strong>
                      <span class="cmd-chip rounded-full ${item.severity === 'watch' ? 'warn' : ''}">${statusLabel(item.severity)}</span>
                    </div>
                    <p class="m-0 text-[rgba(255,255,255,0.78)] leading-snug">${item.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `
        : null}

      <${ActionBar}>
        <${ActionBtn}
          label=${missionBriefingLoading.value ? '응답 기다리는 중…' : '판단 다시 읽기'}
          onClick=${() => { void refreshMissionBriefing(retryNeedsForce) }}
          disabled=${missionBriefingLoading.value}
        />
        <${ActionBtn}
          label="강제 갱신"
          onClick=${() => { void refreshMissionBriefing(true) }}
          disabled=${missionBriefingLoading.value}
        />
      <//>
    <//>
  `
}
