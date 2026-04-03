import { html } from 'htm/preact'
import { StatusChip } from './status-chip'
import { namespaceTruth, namespaceTruthError, namespaceTruthLoading } from '../../namespace-truth-store'
import { toneClass } from '../../lib/tone'

export function NamespaceTruthStrip() {
  const snapshot = namespaceTruth.value
  if (!snapshot) {
    if (namespaceTruthLoading.value) {
      return html`<section class="namespace-truth-strip namespace-truth-strip-loading">불러오는 중...</section>`
    }
    if (namespaceTruthError.value) {
      return html`<section class="namespace-truth-strip namespace-truth-strip-error">${namespaceTruthError.value}</section>`
    }
    return null
  }

  const status = snapshot.namespace.status
  const counts = snapshot.namespace.counts
  const execution = snapshot.execution?.summary
  const blocked = execution?.blocked_sessions ?? 0

  return html`
    <section class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3 mb-4">
      <article class="namespace-truth-card rounded-xl">
        <span class="namespace-truth-label">현황</span>
        <strong>에이전트 ${counts?.agents ?? 0} · 키퍼 ${counts?.keepers ?? 0}${(counts?.tasks ?? 0) > 0 ? ` · 태스크 ${counts?.tasks}` : ''}</strong>
        <p>${status?.project ?? 'project'} · ${status?.paused ? '일시정지' : '활성'}</p>
      </article>

      <article class="namespace-truth-card rounded-xl">
        <span class="namespace-truth-label">세션</span>
        <strong>활성 ${execution?.active_sessions ?? 0} · 막힘 ${blocked}</strong>
        <div class="flex flex-wrap gap-2">
          <${StatusChip} label=${`우선 ${execution?.priority_items ?? 0}`} tone=${toneClass(blocked > 0 ? 'warn' : 'ok')} />
        </div>
      </article>
    </section>
  `
}
