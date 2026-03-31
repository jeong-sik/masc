import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  fetchDashboardCollaborationEvidence,
  type DashboardCollaborationEvidenceResponse,
} from '../api'

const collaborationEvidence = signal<DashboardCollaborationEvidenceResponse | null>(null)
const collaborationEvidenceError = signal<string | null>(null)
const collaborationEvidenceLoading = signal(false)
const collaborationEvidenceKey = signal('')

type CollaborationCountKey = keyof DashboardCollaborationEvidenceResponse['counts']
type CollaborationEvidencePanelRow = { key: string, content: ReturnType<typeof html> }
type CollaborationEvidencePanelView = {
  key: string
  title: string
  rows: CollaborationEvidencePanelRow[]
}

const COLLABORATION_COUNT_METRICS: Array<{ key: CollaborationCountKey, label: string }> = [
  { key: 'team_turn_count', label: 'team turns' },
  { key: 'session_broadcast_count', label: 'broadcast' },
  { key: 'portal_count', label: 'portal' },
  { key: 'mention_count', label: 'mentions' },
  { key: 'board_interaction_count', label: 'board' },
  { key: 'unique_actor_count', label: 'actors' },
]

async function loadCollaborationEvidence(sessionId?: string | null, roomId?: string | null) {
  const key = `${sessionId ?? ''}:${roomId ?? ''}`
  if (collaborationEvidenceLoading.value && collaborationEvidenceKey.value === key) return
  collaborationEvidenceLoading.value = true
  collaborationEvidenceError.value = null
  collaborationEvidenceKey.value = key
  try {
    collaborationEvidence.value = await fetchDashboardCollaborationEvidence({ sessionId, roomId })
  } catch (err) {
    collaborationEvidenceError.value = err instanceof Error ? err.message : String(err)
  } finally {
    collaborationEvidenceLoading.value = false
  }
}

function evidenceTone(value: string): string {
  switch (value) {
    case 'strong':
      return 'text-[var(--ok)] bg-[var(--ok-10)] border-[rgba(74,222,128,0.2)]'
    case 'partial':
      return 'text-[var(--warn)] bg-[var(--warn-12)] border-[rgba(251,191,36,0.2)]'
    default:
      return 'text-[var(--bad)] bg-[var(--bad-12)] border-[rgba(239,68,68,0.2)]'
  }
}

export function visibleCollaborationCountMetrics(
  counts: DashboardCollaborationEvidenceResponse['counts'],
): Array<{ key: CollaborationCountKey, label: string, value: number }> {
  return COLLABORATION_COUNT_METRICS
    .map(metric => ({
      ...metric,
      value: counts[metric.key],
    }))
    .filter(metric => metric.value > 0)
}

export function collaborationEvidenceSupportRows(
  data: DashboardCollaborationEvidenceResponse,
): string[] {
  const rows: string[] = []
  if (data.proof.available || data.proof.verdict) {
    rows.push(`proof verdict · ${data.proof.verdict ?? 'none'} · ${data.proof.available ? 'available' : 'missing'}`)
  }
  if (
    data.relation_backend.source !== 'graphql_proxy'
    || data.relation_backend.status !== 'configured'
  ) {
    rows.push(`relation backend · ${data.relation_backend.source} · ${data.relation_backend.status}`)
  }
  if (data.linkage.selected_operation_id) {
    rows.push(`linked operation · ${data.linkage.selected_operation_id}`)
  }
  if (data.linkage.explicit_linked_activity_count > 0) {
    rows.push(`linked room activity · ${data.linkage.explicit_linked_activity_count}`)
  }
  if (data.linkage.unlinked_activity_count > 0) {
    rows.push(`unlinked room activity · ${data.linkage.unlinked_activity_count}`)
  }
  if (data.counts.message_broadcast_count > 0) {
    rows.push(`message broadcast count · ${data.counts.message_broadcast_count}`)
  }
  for (const gap of data.linkage.gaps) {
    rows.push(`linkage gap · ${gap}`)
  }
  return rows
}

export function CollaborationEvidencePanel({
  sessionId,
  roomId,
}: {
  sessionId?: string | null
  roomId?: string | null
}) {
  useEffect(() => {
    void loadCollaborationEvidence(sessionId, roomId)
  }, [sessionId, roomId])

  const data = collaborationEvidence.value
  const counts = data?.counts
  const metrics = counts ? visibleCollaborationCountMetrics(counts) : []
  const evidenceRows = data ? collaborationEvidenceSupportRows(data) : []
  const evidencePanels: CollaborationEvidencePanelView[] = []

  if (evidenceRows.length > 0) {
    evidencePanels.push({
      key: 'support',
      title: 'proof / relation backend',
      rows: evidenceRows.map((row, index) => ({
        key: `support:${index}`,
        content: html`${row}`,
      })),
    })
  }

  if (data && data.recent_events.length > 0) {
    evidencePanels.push({
      key: 'recent-events',
      title: '최근 세션 이벤트',
      rows: data.recent_events.map(item => ({
        key: `${item.ts_iso ?? 'na'}:${item.event_type}:${item.actor ?? 'na'}`,
        content: html`
          <span class="text-[var(--text-strong)]">${item.event_type}</span>
          ${item.actor ? html` · ${item.actor}` : null}
          ${item.summary ? html` · ${item.summary}` : null}
        `,
      })),
    })
  }

  if (data && data.recent_unlinked_activity.length > 0) {
    evidencePanels.push({
      key: 'recent-unlinked',
      title: '최근 미연결 room activity',
      rows: data.recent_unlinked_activity.map(item => ({
        key: `${item.ts_iso ?? 'na'}:${item.kind}:${item.actor ?? 'na'}`,
        content: html`
          <span class="text-[var(--text-strong)]">${item.kind}</span>
          ${item.actor ? html` · ${item.actor}` : null}
          ${item.summary ? html` · ${item.summary}` : null}
        `,
      })),
    })
  }

  return html`
    <section class="rounded-lg border border-[var(--card-border)] bg-[var(--white-2)] p-4 grid gap-4">
      <div class="flex items-start justify-between gap-3 flex-wrap">
        <div class="grid gap-1">
          <div class="flex items-center gap-2 flex-wrap">
            <strong class="text-[14px] text-[var(--text-strong)]">협업 근거</strong>
            ${data
              ? html`<span class="px-2 py-0.5 rounded-full border text-[10px] uppercase tracking-[0.06em] ${evidenceTone(data.evidence_status)}">${data.evidence_status}</span>`
              : null}
          </div>
          <span class="text-[12px] text-[var(--text-body)]">${data?.headline ?? '세션/룸 상호작용 근거를 읽는 중입니다.'}</span>
          <span class="text-[12px] text-[var(--text-muted)]">${data?.detail ?? ''}</span>
        </div>
        <div class="text-[11px] text-[var(--text-muted)] font-mono">
          ${data?.session?.session_id ?? roomId ?? 'default'}
        </div>
      </div>

      ${collaborationEvidenceError.value
        ? html`<div class="text-[12px] text-[var(--bad)]">${collaborationEvidenceError.value}</div>`
        : null}

      ${collaborationEvidenceLoading.value && !data
        ? html`<div class="text-[12px] text-[var(--text-muted)]">협업 근거 불러오는 중...</div>`
        : null}

      ${data && counts
        ? html`
            ${metrics.length > 0
              ? html`
                  <div class="grid grid-cols-[repeat(auto-fit,minmax(130px,1fr))] gap-3">
                    ${metrics.map(metric => html`
                      <div key=${metric.key} class="rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] p-3">
                        <div class="text-[10px] uppercase tracking-[0.06em] text-[var(--text-muted)]">${metric.label}</div>
                        <strong class="text-[20px] text-[var(--text-strong)] tabular-nums">${metric.value}</strong>
                      </div>
                    `)}
                  </div>
                `
              : null}

            ${evidencePanels.length > 0
              ? html`
                  <div class="grid grid-cols-[repeat(auto-fit,minmax(240px,1fr))] gap-3">
                    ${evidencePanels.map(panel => html`
                      <div key=${panel.key} class="rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] p-3 grid gap-2">
                        <strong class="text-[13px] text-[var(--text-strong)]">${panel.title}</strong>
                        ${panel.rows.map(row => html`<div key=${row.key} class="text-[12px] text-[var(--text-muted)]">${row.content}</div>`)}
                      </div>
                    `)}
                  </div>
                `
              : null}

            ${metrics.length === 0 && evidencePanels.length === 0
              ? html`<div class="text-[12px] text-[var(--text-muted)]">추가로 펼칠 근거가 아직 없어 핵심 요약만 표시합니다.</div>`
              : null}
          `
        : null}
    </section>
  `
}
