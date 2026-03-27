import { html } from 'htm/preact'
import type {
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
} from '../../api/dashboard'
import { Card } from '../common/card'

function toneClass(status: string): string {
  switch (status) {
    case 'ready':
      return 'border-[rgba(34,197,94,0.28)] bg-[rgba(34,197,94,0.10)] text-[#bbf7d0]'
    case 'warn':
      return 'border-[rgba(250,204,21,0.28)] bg-[rgba(250,204,21,0.10)] text-[#fde68a]'
    case 'invalid_env':
      return 'border-[rgba(244,63,94,0.28)] bg-[rgba(244,63,94,0.10)] text-[#fecdd3]'
    default:
      return 'border-[var(--card-border)] bg-[var(--white-6)] text-[var(--text-muted)]'
  }
}

function sourceLabel(source: string): string {
  switch (source) {
    case 'env':
      return 'ENV'
    case 'home_masc':
      return 'HOME'
    case 'invalid_env':
      return 'INVALID ENV'
    case 'exe_relative':
      return 'EXE'
    case 'cwd':
      return 'CWD'
    case 'legacy_me_root':
      return 'LEGACY'
    default:
      return 'MISSING'
  }
}

function ConfigRow({
  label,
  item,
}: {
  label: string
  item: DashboardConfigResolutionItem
}) {
  return html`
    <div class="rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-3">
      <div class="mb-2 flex flex-wrap items-center gap-2">
        <div class="text-[11px] uppercase tracking-[0.08em] text-[var(--text-muted)]">${label}</div>
        <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] ${toneClass(item.exists ? 'ready' : item.source === 'invalid_env' ? 'invalid_env' : 'warn')}">
          ${item.exists ? 'present' : 'missing'}
        </span>
        <span class="rounded-full border border-[var(--card-border)] bg-[var(--white-6)] px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] text-[var(--text-muted)]">
          ${sourceLabel(item.source)}
        </span>
      </div>
      <div class="break-all font-mono text-[12px] leading-relaxed text-[var(--text-body)]">${item.path}</div>
    </div>
  `
}

export function ConfigResolutionPanel({
  resolution,
}: {
  resolution: DashboardConfigResolution | undefined
}) {
  if (!resolution) return null

  return html`
    <${Card} title="설정 경로" class="section mb-4">
      <div class="mb-4 flex flex-wrap items-center gap-2">
        <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] ${toneClass(resolution.status)}">
          ${resolution.status}
        </span>
        <span class="text-[12px] text-[var(--text-muted)]">
          runtime data root와 별개로, repo-managed config root 해석 결과를 보여줍니다.
        </span>
      </div>

      ${resolution.warnings.length > 0
        ? html`
            <div class="mb-4 rounded-lg border border-[rgba(250,204,21,0.28)] bg-[rgba(250,204,21,0.08)] px-3 py-3">
              <div class="mb-2 text-[11px] uppercase tracking-[0.08em] text-[#fde68a]">warnings</div>
              <div class="flex flex-col gap-2">
                ${resolution.warnings.map(warning => html`
                  <div class="text-[12px] leading-relaxed text-[var(--text-body)]">${warning}</div>
                `)}
              </div>
            </div>
          `
        : null}

      <div class="grid gap-3 md:grid-cols-2">
        <${ConfigRow} label="config root" item=${resolution.config_root} />
        <${ConfigRow} label="cascade" item=${resolution.cascade} />
        <${ConfigRow} label="prompts" item=${resolution.prompts} />
        <${ConfigRow} label="keepers" item=${resolution.keepers} />
        <${ConfigRow} label="personas" item=${resolution.personas} />
      </div>
    <//>
  `
}
