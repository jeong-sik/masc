import { html } from 'htm/preact'
import { StatCell } from './common/stat-cell'
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
  namespace,
  generatedAt,
}: {
  cluster?: string
  project?: string
  namespace?: string | null
  generatedAt?: string
}) {
  return html`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3">
      <${StatCell} label="프로젝트" value=${project ?? '확인 없음'} />
      <${StatCell} label="네임스페이스" value=${namespace ?? 'default'} />
      <${StatCell} label="갱신 시각" value=${generatedAt ? relativeTime(generatedAt) : '기록 없음'} />
      ${cluster && cluster !== 'unknown'
        ? html`<${StatCell} label="배포 메타" value=${cluster} />`
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
  return html`<${StatCell} label=${label} value=${value} detail=${detail} tone=${toneClass(tone)} size="lg" />`
}
