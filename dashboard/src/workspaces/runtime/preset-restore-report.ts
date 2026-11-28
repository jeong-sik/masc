/**
 * What a preset restore did, surface by surface (`Prompt_preset.report_to_json`).
 *
 * Prompt overrides take effect at once; keeper instructions at each keeper's
 * next up; runtime.toml routing when the commit lands. Each surface lists what
 * it applied and what it skipped with the server's reason, so a partial
 * restore reads as partial.
 */

import { html } from 'htm/preact'
import { Chip } from './prompt-chip'
import type { DefaultPrompts, PartResult, RestoreReport, RuntimeOutcome } from './presets-wire'

const noteStyle = { fontSize: 'var(--fs-12)', color: 'var(--fg-2)' } as const

function Skipped({ rows }: { rows: readonly { readonly key: string; readonly reason: string }[] }) {
  if (rows.length === 0) return null
  return html`
    <ul style=${{ margin: 0, paddingLeft: 'var(--sp-4)', fontSize: 'var(--fs-12)', color: 'var(--warn-fg)' }}>
      ${rows.map(r => html`<li key=${r.key}><span class="mono">${r.key}</span>: ${r.reason}</li>`)}
    </ul>
  `
}

function Part({ title, when, part }: { title: string; when: string; part: PartResult }) {
  return html`
    <div data-testid="restore-part" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
      <div style=${{ display: 'flex', gap: 'var(--sp-1)', alignItems: 'center', flexWrap: 'wrap' }}>
        <strong style=${{ fontSize: 'var(--fs-13)' }}>${title}</strong>
        <${Chip} tone="ok">적용 ${part.applied.length}</${Chip}>
        ${part.skipped.length > 0 && html`<${Chip} tone="warn">건너뜀 ${part.skipped.length}</${Chip}>`}
        <span style=${noteStyle}>${when}</span>
      </div>
      ${part.applied.length > 0 && html`<div class="mono" style=${{ ...noteStyle, overflowWrap: 'anywhere' }}>${part.applied.join(', ')}</div>`}
      <${Skipped} rows=${part.skipped} />
    </div>
  `
}

function RuntimeLine({ runtime }: { runtime: RuntimeOutcome }) {
  switch (runtime.status) {
    case 'unchanged':
      return html`<div style=${noteStyle}>runtime.toml 은 바꿀 것이 없어서 그대로예요.</div>`
    case 'failed':
      return html`<div role="alert" class="ap-error">runtime.toml 을 바꾸지 못했어요: ${runtime.error}</div>`
    case 'committed': {
      const { commit, exact_output_registry: registry } = runtime
      return html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
          <div style=${noteStyle}>runtime.toml 의 배정과 lane 을 바꿨어요.</div>
          ${commit.durability === 'unconfirmed' && html`<div style=${{ ...noteStyle, color: 'var(--warn-fg)' }}>디스크에 남았는지 확인하지 못했어요: ${commit.durability_detail}</div>`}
          ${commit.warnings.map(w => html`<div key=${w.code} style=${{ ...noteStyle, color: 'var(--warn-fg)' }}>${w.code}: ${w.detail}</div>`)}
          ${registry.status === 'unpublished' && html`<div style=${{ ...noteStyle, color: 'var(--warn-fg)' }}>exact-output lane 은 서버를 다시 시작해야 새 선언으로 돌아요.</div>`}
          ${registry.status === 'kept' && html`<div style=${{ ...noteStyle, color: 'var(--warn-fg)' }}>exact-output lane 은 이전 선언으로 돌아요: ${registry.reason}</div>`}
        </div>
      `
    }
  }
}

export function DefaultPromptsLine({ defaults }: { defaults: DefaultPrompts }) {
  switch (defaults.status) {
    case 'unknown':
      return html`<${Chip} tone="neutral" title="이 프리셋은 저장할 때 기본 텍스트의 해시를 남기지 않았어요">기본 텍스트 기록 없음</${Chip}>`
    case 'matches':
      return html`<${Chip} tone="ok" title="저장한 뒤 기본 프롬프트 텍스트가 바뀌지 않았어요">기본 텍스트 그대로</${Chip}>`
    case 'differs':
      return html`<${Chip} tone="warn" title=${defaults.changes.map(c => c.key).join(', ')}>기본 텍스트 ${defaults.changes.length}개 바뀜</${Chip}>`
  }
}

export function RestoreReportView({ report, onDismiss }: { report: RestoreReport; onDismiss: () => void }) {
  const lanes = [
    ...report.skipped_assignments.map(r => ({ key: `배정 ${r.keeper}`, reason: r.reason })),
    ...report.skipped_lanes.map(r => ({ key: `lane ${r.lane}`, reason: r.reason })),
  ]
  return html`
    <div class="wka-card" role="status" data-testid="preset-restore-report" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', borderColor: 'var(--ok-border)' }}>
      <div class="wka-h">
        <h3><span class="mono">${report.restored}</span> 을 복원했어요</h3>
        <button type="button" class="btn-ghost btn-compact" onClick=${onDismiss}>닫기</button>
      </div>
      <div style=${noteStyle}>복원 전 상태는 <span class="mono">${report.autosave}</span> 프리셋에 있어요. 그 프리셋을 복원하면 되돌려요.</div>
      <${Part} title="프롬프트 override" when="바로 적용돼요." part=${report.prompt_overrides} />
      <${Part} title="Keeper instructions" when="각 Keeper 를 다시 올릴 때 적용돼요." part=${report.instructions} />
      <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
        <strong style=${{ fontSize: 'var(--fs-13)' }}>Runtime 배정 · lane</strong>
        <${RuntimeLine} runtime=${report.runtime} />
        <${Skipped} rows=${lanes} />
        ${report.preserved_lane_settings.length > 0 && html`
          <div style=${noteStyle}>프리셋이 기록하지 않아 지금 값을 둔 설정: ${report.preserved_lane_settings.map(s => `${s.lane}.${s.setting}`).join(', ')}</div>
        `}
      </div>
      <div><${DefaultPromptsLine} defaults=${report.default_prompts} /></div>
    </div>
  `
}
