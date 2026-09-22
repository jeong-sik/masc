// Read-only composition card for one fusion preset, rendered from the typed
// config projection (/api/v1/runtime/config/fusion): every panel group with its
// deadline and output budget, the meta judge, the first-pass judge roster, the
// topologies that roster makes runnable, and the quorum. It reads the same
// value the tool executes against.

import { html } from 'htm/preact'
import type {
  FusionJudgeSpecView,
  FusionPanelGroupView,
  FusionPresetConfigView,
  FusionTopologyLabel,
} from '../../api/dashboard'
import { runnableTopologies } from '../../api/dashboard'

// An unset optional means "the runtime/provider value applies"; it is not zero
// and not the provider's number. Rendering it as "런타임 기본" says that,
// where a fabricated figure would claim the preset declared something.
function budgetLabel(tokens: number | null): string {
  return tokens === null ? '런타임 기본' : `${tokens} tok`
}

function deadlineLabel(seconds: number | null): string {
  return seconds === null ? '런타임 기본' : `${seconds}s`
}

function PanelGroup({ group, index }: { group: FusionPanelGroupView; index: number }) {
  return html`
    <div class="set-fus-lane" data-testid="fusion-preset-panel-group">
      <div class="set-fus-lane-h">
        panel${group.label ? ` · ${group.label}` : ''} · ${group.models.length}
        <span class="set-fus-axis">
          ${deadlineLabel(group.timeoutS)} · ${budgetLabel(group.maxOutputTokens)}
          ${group.webTools ? ' · web tools' : ''}
        </span>
      </div>
      ${group.models.map(
        id =>
          html`<div
            key=${`${index}:${id}`}
            class="set-fus-model mono"
            data-testid="fusion-preset-panel-model"
          >
            ${id}
          </div>`,
      )}
    </div>
  `
}

function JudgeSpec({ judge }: { judge: FusionJudgeSpecView }) {
  return html`
    <div class="set-fus-model mono" data-testid="fusion-preset-first-judge">
      ${judge.label ? `${judge.label} · ` : ''}${judge.model}
      <span class="set-fus-axis">
        ${deadlineLabel(judge.timeoutS)} · ${budgetLabel(judge.maxOutputTokens)}
      </span>
    </div>
  `
}

export function FusionPresetCard({
  preset,
  stagedGroupSize,
}: {
  preset: FusionPresetConfigView
  stagedGroupSize: number
}) {
  const panelCount = preset.panels.reduce((total, group) => total + group.models.length, 0)
  const runnable: readonly FusionTopologyLabel[] = runnableTopologies(preset, stagedGroupSize)
  const jojReady = runnable.includes('judge_of_judges')
  return html`
    <div class="set-fus-preset" data-testid="fusion-preset-view">
      ${preset.panels.map(
        (group, index) => html`<${PanelGroup} key=${index} group=${group} index=${index} />`,
      )}

      <div class="set-fus-lane">
        <div class="set-fus-lane-h" data-testid="fusion-preset-judge-lane-h">
          judge${preset.judges.length > 0
            ? ` · 메타 (1차 심판 ${preset.judges.length} · judge-of-judges)`
            : ''}
          <span class="set-fus-axis">
            ${deadlineLabel(preset.judgeTimeoutS)} · ${budgetLabel(preset.judgeMaxOutputTokens)}
          </span>
        </div>
        <div class="set-fus-model judge mono" data-testid="fusion-preset-judge">
          ${preset.judge || '미지정'}
        </div>
        ${preset.judges.map(
          judge => html`<${JudgeSpec} key=${`${judge.label}:${judge.model}`} judge=${judge} />`,
        )}
      </div>

      <div class="set-fus-lane">
        <div class="set-fus-lane-h">실행 가능 위상</div>
        <div class="set-fus-model mono" data-testid="fusion-preset-topologies">
          ${runnable.map(topology => topology.replace(/_/g, ' ')).join(' · ')}
        </div>
        ${jojReady
          ? null
          : html`<div class="set-fus-model mono" data-testid="fusion-preset-joj-note">
              judge-of-judges 는 1차 심판 2명 이상이 필요합니다 (현재 ${preset.judges.length})
            </div>`}
        <div class="set-fus-model mono" data-testid="fusion-preset-quorum">
          정족수 ${preset.minAnswered} / 패널 ${panelCount}
        </div>
      </div>
    </div>
  `
}
