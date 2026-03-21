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
    <${Card} title="판단 레이어" class="mission-briefing-card" semanticId="mission.model_briefing">
      <div class="mission-section-head">
        <h3>왜 그렇게 보이나</h3>
        <p>사회 truth를 읽은 뒤에만 별도 판단 결과를 참고하고, 근거는 접어서 둡니다.</p>
        <${ProvenanceStrip}
          items=${[
            { kind: 'narrative' },
            { kind: 'fallback', label: 'fallback on failure' },
          ]}
        />
      </div>

      <div class="mission-briefing-meta">
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
      ${briefing?.summary ? html`<div class="mission-inline-note">${briefing.summary}</div>` : null}
      ${briefing?.last_error && !briefing.error
        ? html`<div class="mission-inline-note">최근 갱신 실패: ${briefing.last_error}</div>`
        : null}

      ${briefing && briefing.sections.length > 0
        ? html`
            <div class="mission-briefing-grid">
              ${briefing.sections.slice(0, 3).map(section => html`
                <article class="mission-briefing-section ${toneClass(section.status)}">
                  <div class="mission-card-head">
                    <strong>${section.label}</strong>
                    <div class="mission-briefing-section-chips">
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
                        <details class="mission-card-disclosure compact">
                          <summary>근거 보기</summary>
                          <div class="mission-pill-row">
                            ${section.evidence.map(item => html`<span class="mission-pill">${item}</span>`)}
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
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>관측 공백 (${briefing.metadata_gap_count ?? briefing.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${briefing.metadata_gaps.map(item => html`
                  <article class="mission-briefing-gap ${item.severity === 'watch' ? 'warn' : ''}">
                    <div class="mission-card-head">
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

      <div class="mission-card-actions">
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
