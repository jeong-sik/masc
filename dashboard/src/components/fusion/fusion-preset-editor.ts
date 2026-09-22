// Form for one Fusion preset draft: panel groups, the meta judge, the
// first-pass judges and the quorum. Pure over its props — the panel that owns
// the draft decides which write the draft becomes (save, copy, rename).
//
// Every seat is picked from the routes GET /api/v1/runtime/resolved reports,
// grouped by kind, because the server refuses a preset naming anything else
// (route_unresolved). A loaded seat that is no longer in that list stays
// visible under its own group so the operator sees what the file says.

import { html } from 'htm/preact'
import {
  emptyJudgeDraft,
  emptyPanelGroupDraft,
  type FusionJudgeDraft,
  type FusionPanelGroupDraft,
  type FusionPresetDraft,
} from '../../lib/fusion-preset-draft'
import type { FusionRouteOption } from '../../lib/fusion-routes'

const str = (event: Event) => (event.target as HTMLInputElement).value
const checked = (event: Event) => (event.target as HTMLInputElement).checked

function replaceAt<T>(list: readonly T[], index: number, item: T): T[] {
  return list.map((entry, at) => (at === index ? item : entry))
}

function removeAt<T>(list: readonly T[], index: number): T[] {
  return list.filter((_, at) => at !== index)
}

function RouteOptions({ routes }: { routes: readonly FusionRouteOption[] }) {
  const lanes = routes.filter(route => route.kind === 'lane')
  const runtimes = routes.filter(route => route.kind === 'runtime')
  return html`
    ${lanes.length > 0
      ? html`<optgroup label="lane">
          ${lanes.map(route => html`<option key=${route.id} value=${route.id}>${route.id}</option>`)}
        </optgroup>`
      : null}
    ${runtimes.length > 0
      ? html`<optgroup label="runtime">
          ${runtimes.map(route => html`<option key=${route.id} value=${route.id}>${route.id}</option>`)}
        </optgroup>`
      : null}
  `
}

function RouteSelect({
  value,
  routes,
  testId,
  disabled,
  onChange,
}: {
  value: string
  routes: readonly FusionRouteOption[]
  testId: string
  disabled: boolean
  onChange: (route: string) => void
}) {
  const known = routes.some(route => route.id === value)
  return html`
    <select
      class="set-fusion-runtime-add mono"
      data-testid=${testId}
      value=${value}
      disabled=${disabled}
      onChange=${(event: Event) => onChange((event.target as HTMLSelectElement).value)}
    >
      <option value="">미지정</option>
      ${value !== '' && !known
        ? html`<optgroup label="목록에 없음"><option value=${value}>${value}</option></optgroup>`
        : null}
      <${RouteOptions} routes=${routes} />
    </select>
  `
}

function RouteListEditor({
  models,
  routes,
  testId,
  disabled,
  onChange,
}: {
  models: readonly string[]
  routes: readonly FusionRouteOption[]
  testId: string
  disabled: boolean
  onChange: (models: readonly string[]) => void
}) {
  const addable = routes.filter(route => !models.includes(route.id))
  return html`
    <div class="set-fusion-runtime-list" data-testid=${testId}>
      <div class="set-fusion-runtime-chips">
        ${models.length === 0
          ? html`<span class="set-hint" data-testid=${`${testId}-empty`}>패널 모델 없음</span>`
          : models.map(model => html`
            <span key=${model} class="set-fusion-runtime-chip mono" data-testid=${`${testId}-chip`}>
              ${model}
              <button
                type="button"
                aria-label=${`${model} 제거`}
                data-testid=${`${testId}-remove`}
                disabled=${disabled}
                onClick=${() => onChange(models.filter(entry => entry !== model))}
              >
                ×
              </button>
            </span>
          `)}
      </div>
      <select
        class="set-fusion-runtime-add mono"
        data-testid=${`${testId}-add`}
        value=""
        disabled=${disabled || addable.length === 0}
        onChange=${(event: Event) => {
          const select = event.target as HTMLSelectElement
          if (select.value !== '') onChange([...models, select.value])
          select.value = ''
        }}
      >
        <option value="">패널 모델 추가</option>
        <${RouteOptions} routes=${addable} />
      </select>
    </div>
  `
}

function PanelGroupEditor({
  group,
  index,
  routes,
  disabled,
  onChange,
  onRemove,
}: {
  group: FusionPanelGroupDraft
  index: number
  routes: readonly FusionRouteOption[]
  disabled: boolean
  onChange: (group: FusionPanelGroupDraft) => void
  onRemove: () => void
}) {
  const patch = (next: Partial<FusionPanelGroupDraft>) => onChange({ ...group, ...next })
  return html`
    <div class="set-fusion-group" data-testid="fusion-panel-group">
      <div class="set-fusion-group-h">
        <span>패널 그룹 ${index + 1}</span>
        <button type="button" data-testid="fusion-panel-group-remove" disabled=${disabled} onClick=${onRemove}>
          그룹 삭제
        </button>
      </div>
      <label class="set-line">
        <span>label</span>
        <input type="text" data-testid="fusion-panel-label" value=${group.label} disabled=${disabled}
          onInput=${(event: Event) => patch({ label: str(event) })} />
      </label>
      <div class="set-line set-line-stack">
        <span>models</span>
        <${RouteListEditor}
          models=${group.models}
          routes=${routes}
          testId="fusion-panel-models"
          disabled=${disabled}
          onChange=${(models: readonly string[]) => patch({ models })}
        />
      </div>
      <label class="set-line set-line-stack">
        <span>system_prompt</span>
        <textarea class="set-fusion-prompt" data-testid="fusion-panel-system-prompt" rows="4"
          value=${group.systemPrompt} disabled=${disabled}
          onInput=${(event: Event) => patch({ systemPrompt: str(event) })}></textarea>
      </label>
      <label class="set-line v2-mobile-operator-target">
        <span>web_tools</span>
        <input type="checkbox" data-testid="fusion-panel-web-tools" checked=${group.webTools} disabled=${disabled}
          onChange=${(event: Event) => patch({ webTools: checked(event) })} />
      </label>
      <label class="set-line">
        <span>max_output_tokens (비우면 런타임 기본)</span>
        <input type="number" step="1" data-testid="fusion-panel-max-output-tokens" value=${group.maxOutputTokens}
          disabled=${disabled} onInput=${(event: Event) => patch({ maxOutputTokens: str(event) })} />
      </label>
      <label class="set-line">
        <span>timeout_s (비우면 런타임 기본)</span>
        <input type="number" step="any" data-testid="fusion-panel-timeout-s" value=${group.timeoutS}
          disabled=${disabled} onInput=${(event: Event) => patch({ timeoutS: str(event) })} />
      </label>
    </div>
  `
}

function JudgeEditor({
  judge,
  index,
  routes,
  disabled,
  onChange,
  onRemove,
}: {
  judge: FusionJudgeDraft
  index: number
  routes: readonly FusionRouteOption[]
  disabled: boolean
  onChange: (judge: FusionJudgeDraft) => void
  onRemove: () => void
}) {
  const patch = (next: Partial<FusionJudgeDraft>) => onChange({ ...judge, ...next })
  return html`
    <div class="set-fusion-group" data-testid="fusion-first-judge">
      <div class="set-fusion-group-h">
        <span>1차 심판 ${index + 1}</span>
        <button type="button" data-testid="fusion-first-judge-remove" disabled=${disabled} onClick=${onRemove}>
          심판 삭제
        </button>
      </div>
      <label class="set-line">
        <span>model</span>
        <${RouteSelect}
          value=${judge.model}
          routes=${routes}
          testId="fusion-first-judge-model"
          disabled=${disabled}
          onChange=${(model: string) => patch({ model })}
        />
      </label>
      <label class="set-line">
        <span>label</span>
        <input type="text" data-testid="fusion-first-judge-label" value=${judge.label} disabled=${disabled}
          onInput=${(event: Event) => patch({ label: str(event) })} />
      </label>
      <label class="set-line set-line-stack">
        <span>system_prompt</span>
        <textarea class="set-fusion-prompt" data-testid="fusion-first-judge-system-prompt" rows="4"
          value=${judge.systemPrompt} disabled=${disabled}
          onInput=${(event: Event) => patch({ systemPrompt: str(event) })}></textarea>
      </label>
      <label class="set-line v2-mobile-operator-target">
        <span>web_tools</span>
        <input type="checkbox" data-testid="fusion-first-judge-web-tools" checked=${judge.webTools}
          disabled=${disabled} onChange=${(event: Event) => patch({ webTools: checked(event) })} />
      </label>
      <label class="set-line">
        <span>max_output_tokens (비우면 런타임 기본)</span>
        <input type="number" step="1" data-testid="fusion-first-judge-max-output-tokens"
          value=${judge.maxOutputTokens} disabled=${disabled}
          onInput=${(event: Event) => patch({ maxOutputTokens: str(event) })} />
      </label>
      <label class="set-line">
        <span>timeout_s (비우면 런타임 기본)</span>
        <input type="number" step="any" data-testid="fusion-first-judge-timeout-s" value=${judge.timeoutS}
          disabled=${disabled} onInput=${(event: Event) => patch({ timeoutS: str(event) })} />
      </label>
    </div>
  `
}

export function FusionPresetEditor({
  draft,
  routes,
  disabled,
  onChange,
}: {
  draft: FusionPresetDraft
  routes: readonly FusionRouteOption[]
  disabled: boolean
  onChange: (draft: FusionPresetDraft) => void
}) {
  const patch = (next: Partial<FusionPresetDraft>) => onChange({ ...draft, ...next })
  return html`
    <div class="set-fusion-preset-editor" data-testid="fusion-preset-editor">
      <label class="set-line">
        <span>이름 (name)</span>
        <input type="text" data-testid="fusion-preset-name" value=${draft.name} disabled=${disabled}
          onInput=${(event: Event) => patch({ name: str(event) })} />
      </label>

      <div class="set-sub-h">패널 (panels)</div>
      ${draft.panels.map((group, index) => html`
        <${PanelGroupEditor}
          key=${index}
          group=${group}
          index=${index}
          routes=${routes}
          disabled=${disabled}
          onChange=${(next: FusionPanelGroupDraft) => patch({ panels: replaceAt(draft.panels, index, next) })}
          onRemove=${() => patch({ panels: removeAt(draft.panels, index) })}
        />
      `)}
      <div class="set-line">
        <button type="button" data-testid="fusion-panel-group-add" disabled=${disabled}
          onClick=${() => patch({ panels: [...draft.panels, emptyPanelGroupDraft()] })}>
          패널 그룹 추가
        </button>
      </div>

      <div class="set-sub-h">심판 (judge)</div>
      <label class="set-line">
        <span>${draft.judges.length > 0 ? '메타 심판 route (judge)' : '심판 route (judge)'}</span>
        <${RouteSelect}
          value=${draft.judge}
          routes=${routes}
          testId="fusion-judge-route"
          disabled=${disabled}
          onChange=${(judge: string) => patch({ judge })}
        />
      </label>
      <label class="set-line set-line-stack">
        <span>judge_system_prompt</span>
        <textarea class="set-fusion-prompt" data-testid="fusion-judge-system-prompt" rows="4"
          value=${draft.judgeSystemPrompt} disabled=${disabled}
          onInput=${(event: Event) => patch({ judgeSystemPrompt: str(event) })}></textarea>
      </label>
      <label class="set-line">
        <span>judge_max_output_tokens (비우면 런타임 기본)</span>
        <input type="number" step="1" data-testid="fusion-judge-max-output-tokens" value=${draft.judgeMaxOutputTokens}
          disabled=${disabled} onInput=${(event: Event) => patch({ judgeMaxOutputTokens: str(event) })} />
      </label>
      <label class="set-line">
        <span>judge_timeout_s (비우면 런타임 기본)</span>
        <input type="number" step="any" data-testid="fusion-judge-timeout-s" value=${draft.judgeTimeoutS}
          disabled=${disabled} onInput=${(event: Event) => patch({ judgeTimeoutS: str(event) })} />
      </label>

      <div class="set-sub-h">1차 심판 (judges) · judge-of-judges 는 2명 이상</div>
      ${draft.judges.map((judge, index) => html`
        <${JudgeEditor}
          key=${index}
          judge=${judge}
          index=${index}
          routes=${routes}
          disabled=${disabled}
          onChange=${(next: FusionJudgeDraft) => patch({ judges: replaceAt(draft.judges, index, next) })}
          onRemove=${() => patch({ judges: removeAt(draft.judges, index) })}
        />
      `)}
      <div class="set-line">
        <button type="button" data-testid="fusion-first-judge-add" disabled=${disabled}
          onClick=${() => patch({ judges: [...draft.judges, emptyJudgeDraft()] })}>
          1차 심판 추가
        </button>
      </div>

      <div class="set-sub-h">정족수</div>
      <label class="set-line">
        <span>최소 응답 패널 (min_answered)</span>
        <input type="number" step="1" data-testid="fusion-min-answered" value=${draft.minAnswered}
          disabled=${disabled} onInput=${(event: Event) => patch({ minAnswered: str(event) })} />
      </label>
    </div>
  `
}
