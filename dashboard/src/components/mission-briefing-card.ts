import { html } from 'htm/preact'
import { Card } from './common/card'
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
    <${Card} title="판단 레이어" class="mission-briefing-card">
      <div class="grid gap-1 mb-3">
        <h3>왜 그렇게 보이나</h3>
        <p>사회 truth를 읽은 뒤에만 별도 판단 결과를 참고하고, 근거는 접어서 둡니다.</p>
        <${ProvenanceStrip}
          items=${[
            { kind: 'narrative' },
            { kind: 'fallback', label: 'fallback on failure' },
          ]}
        />
      </div>

      <div class="flex gap-2 flex-wrap mb-3">
        <span class="command-chip ${briefingTone}">
          ${statusLabel(briefing?.status ?? (missionBriefingError.value ? 'error' : 'loading'))}
        </span>
        ${briefing?.model ? html`<span class="command-chip">${briefing.model}</span>` : null}
        ${briefing?.generated_at ? html`<span class="command-chip">${relativeTime(briefing.generated_at)}</span>` : null}
        ${briefing?.cached ? html`<span class="command-chip">캐시</span>` : null}
        ${briefing?.stale ? html`<span class="command-chip warn">오래됨</span>` : null}
        ${briefing?.refreshing ? html`<span class="command-chip warn">갱신 중</span>` : null}
      </div>

      ${missionBriefingError.value ? html`<div class="empty-state error">${missionBriefingError.value}</div>` : null}
      ${briefing?.error ? html`<div class="empty-state error">${briefing.error}</div>` : null}
      ${briefing?.summary ? html`<div class="grid gap-1">${briefing.summary}</div>` : null}
      ${briefing?.last_error && !briefing.error
        ? html`<div class="grid gap-1">최근 갱신 실패: ${briefing.last_error}</div>`
        : null}

      ${briefing && briefing.sections.length > 0
        ? html`
            <div class="grid grid-cols-3 gap-3">
              ${briefing.sections.slice(0, 3).map(section => html`
                <article class="mission-briefing-section ${toneClass(section.status)}">
                  <div class="flex justify-between gap-2 items-start flex-wrap">
                    <strong>${section.label}</strong>
                    <div class="flex gap-2 flex-wrap justify-end">
                      <span class="command-chip ${toneClass(section.status)}">${statusLabel(section.status)}</span>
                      ${signalClassLabel(section.signal_class)
                        ? html`<span class="command-chip ${section.signal_class === 'mixed' ? 'warn' : ''}">${signalClassLabel(section.signal_class)}</span>`
                        : null}
                      ${section.evidence_quality ? html`<span class="command-chip">${section.evidence_quality}</span>` : null}
                    </div>
                  </div>
                  <p>${section.summary}</p>
                  ${section.evidence.length > 0
                    ? html`
                        <details class="pt-1 border-t border-[var(--white-6)] mt-2">
                          <summary>근거 보기</summary>
                          <div class="flex gap-2 flex-wrap mt-2.5">
                            ${section.evidence.map(item => html`<span class="px-2.5 py-1.5 rounded-full border border-[var(--white-8)] bg-[var(--white-4)] text-[rgba(255,255,255,0.76)] text-[length:var(--fs-sm)] leading-[1.35]">${item}</span>`)}
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
                <div class="empty-state">
                  ${briefing?.status === 'pending'
                    ? '최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.'
                    : '판단 결과가 아직 없습니다.'}
                </div>
              `
            : null)}

      ${briefing && briefing.metadata_gaps.length > 0
        ? html`
            <details class="pt-1 border-t border-[var(--white-6)] mt-2 mt-3">
              <summary>관측 공백 (${briefing.metadata_gap_count ?? briefing.metadata_gaps.length})</summary>
              <div class="flex flex-col gap-3">
                ${briefing.metadata_gaps.map(item => html`
                  <article class="mission-briefing-gap ${item.severity === 'watch' ? 'warn' : ''}">
                    <div class="flex justify-between gap-2 items-start flex-wrap">
                      <strong>${missionTargetTypeLabel(item.scope_type)}${item.scope_id ? ` · ${item.scope_id}` : ''}</strong>
                      <span class="command-chip ${item.severity === 'watch' ? 'warn' : ''}">${statusLabel(item.severity)}</span>
                    </div>
                    <p>${item.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `
        : null}

      <div class="flex gap-2 flex-wrap mt-2.5">
        <button class="control-btn ghost" onClick=${() => { void refreshMissionBriefing(retryNeedsForce) }} disabled=${missionBriefingLoading.value}>
          ${missionBriefingLoading.value ? '응답 기다리는 중…' : '판단 다시 읽기'}
        </button>
        <button class="control-btn ghost" onClick=${() => { void refreshMissionBriefing(true) }} disabled=${missionBriefingLoading.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `
}
