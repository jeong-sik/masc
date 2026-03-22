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
    <div class="grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-3">
      <div class="p-3 px-3.5 rounded-[14px] border border-[var(--white-8)] bg-[var(--white-4)] grid gap-1.5">
        <span class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-xs)] tracking-[0.08em] uppercase">프로젝트</span>
        <strong class="text-[var(--text-strong)] text-base">${project ?? '확인 없음'}</strong>
      </div>
      <div class="p-3 px-3.5 rounded-[14px] border border-[var(--white-8)] bg-[var(--white-4)] grid gap-1.5">
        <span class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-xs)] tracking-[0.08em] uppercase">방</span>
        <strong class="text-[var(--text-strong)] text-base">${room ?? '기본 방'}</strong>
      </div>
      <div class="p-3 px-3.5 rounded-[14px] border border-[var(--white-8)] bg-[var(--white-4)] grid gap-1.5">
        <span class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-xs)] tracking-[0.08em] uppercase">갱신 시각</span>
        <strong class="text-[var(--text-strong)] text-base">${generatedAt ? relativeTime(generatedAt) : '기록 없음'}</strong>
      </div>
      ${cluster && cluster !== 'unknown'
        ? html`
            <div class="p-3 px-3.5 rounded-[14px] border border-[var(--white-8)] bg-[var(--white-4)] grid gap-1.5">
              <span class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-xs)] tracking-[0.08em] uppercase">배포 메타</span>
              <strong class="text-[var(--text-strong)] text-base">${cluster}</strong>
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
