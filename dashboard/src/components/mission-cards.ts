import { html } from 'htm/preact'
import {
  toneClass,
  relativeTime,
} from './mission-utils'

// Re-export from split files for consumers importing from './mission-cards'
export { SessionBriefCard, SessionDetailCard } from './mission-session-cards'
export { AgentBriefCard, KeeperBriefCard, InternalSignalCard } from './mission-agent-cards'
export { MissionBriefingCard } from './mission-briefing-card'
export { AttentionCard } from './mission-attention-card'

export function MissionContextBar({
  cluster,
  project,
  room,
  generatedAt,
}: {
  cluster?: string
  project?: string
  room?: string | null
  generatedAt?: string
}) {
  return html`
    <div class="mission-context-bar">
      <div class="mission-context-item">
        <span>프로젝트</span>
        <strong>${project ?? '확인 없음'}</strong>
      </div>
      <div class="mission-context-item">
        <span>방</span>
        <strong>${room ?? '기본 방'}</strong>
      </div>
      <div class="mission-context-item">
        <span>갱신 시각</span>
        <strong>${generatedAt ? relativeTime(generatedAt) : '기록 없음'}</strong>
      </div>
      ${cluster && cluster !== 'unknown'
        ? html`
            <div class="mission-context-item">
              <span>배포 메타</span>
              <strong>${cluster}</strong>
            </div>
          `
        : null}
    </div>
  `
}

export function SummaryStat({
  label,
  value,
  detail,
  tone,
}: {
  label: string
  value: string | number
  detail: string
  tone?: string | null
}) {
  return html`
    <article class="mission-stat-card ${toneClass(tone)}">
      <span class="mission-stat-label">${label}</span>
      <strong class="mission-stat-value">${value}</strong>
      <small class="mission-stat-detail">${detail}</small>
    </article>
  `
}
