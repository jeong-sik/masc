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
    <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3">
      <div class="p-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1">
        <span class="text-[10px] text-[var(--text-muted)] tracking-wider uppercase font-medium">프로젝트</span>
        <span class="text-sm font-medium text-[var(--text-strong)]">${project ?? '확인 없음'}</span>
      </div>
      <div class="p-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1">
        <span class="text-[10px] text-[var(--text-muted)] tracking-wider uppercase font-medium">방</span>
        <span class="text-sm font-medium text-[var(--text-strong)]">${room ?? '기본 방'}</span>
      </div>
      <div class="p-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1">
        <span class="text-[10px] text-[var(--text-muted)] tracking-wider uppercase font-medium">갱신 시각</span>
        <span class="text-sm font-medium text-[var(--text-strong)]">${generatedAt ? relativeTime(generatedAt) : '기록 없음'}</span>
      </div>
      ${cluster && cluster !== 'unknown'
        ? html`
            <div class="p-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1">
              <span class="text-[10px] text-[var(--text-muted)] tracking-wider uppercase font-medium">배포 메타</span>
              <span class="text-sm font-medium text-[var(--text-strong)]">${cluster}</span>
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
    <article class="rounded-lg p-3 border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1 ${toneClass(tone)}">
      <span class="text-[10px] text-[var(--text-muted)] tracking-wider uppercase font-medium">${label}</span>
      <strong class="text-xl text-[var(--text-strong)] leading-none tabular-nums">${value}</strong>
      <span class="text-[10px] text-[var(--text-muted)] leading-relaxed">${detail}</span>
    </article>
  `
}
