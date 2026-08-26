// MASC Dashboard — questions Keepers put to a human.
//
// Nothing is held waiting on these: the Keeper that asked kept working. They
// are not a queue of blocked calls, which is why they read as a list of
// decisions rather than as approvals.
//
// The choice ids sent back come from the rows the server gave us, so rewording
// a choice cannot orphan an answer already recorded, and nothing here matches
// on label text.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { formatDateTimeKo } from '../../lib/format-time'
import { LoadingState } from '../common/feedback-state'
import {
  clearQuestion,
  freeTextSlot,
  readiness,
  responseFor,
  setText,
  skipQuestion,
  toggleChoice,
} from '../../lib/keeper-ask-draft'
import type { AskChoice, AskQuestion, AskRow } from '../../lib/keeper-ask-wire'
import {
  askConflict,
  askError,
  askSubmitting,
  asksResource,
  closeAsk,
  draftForRow,
  openAskId,
  refreshKeeperAsks,
  selectAsk,
  submitAnswer,
  updateDraft,
} from '../keeper-asks-store'

// One mark shape per mode: round where only one answer fits, square where
// several do. The operator should not have to read the header to know whether
// picking a second choice replaces the first.
function choiceMark(question: AskQuestion, picked: boolean): string {
  if (question.mode === 'single') return picked ? '◉' : '○'
  return picked ? '☑' : '☐'
}

function ChoiceRow({ row, question, choice }: {
  row: AskRow
  question: AskQuestion
  choice: AskChoice
}) {
  const draft = draftForRow(row)
  const response = responseFor(draft, question)
  const picked = response?.kind === 'chose' && response.choiceIds.includes(choice.choiceId)
  return html`
    <button
      type="button"
      class=${`ka-choice${picked ? ' is-picked' : ''}`}
      aria-pressed=${picked}
      onClick=${() => updateDraft(toggleChoice(draft, question, choice))}
    >
      <span class="ka-choice-mark" aria-hidden="true">${choiceMark(question, picked)}</span>
      <span class="ka-choice-label">${choice.label}</span>
      ${choice.description === null
        ? null
        : html`<span class="ka-choice-desc">${choice.description}</span>`}
    </button>
  `
}

function FreeText({ row, question }: { row: AskRow; question: AskQuestion }) {
  const slot = freeTextSlot(question)
  if (slot === null) return null
  const draft = draftForRow(row)
  const response = responseFor(draft, question)
  const value = response?.kind === 'wrote' ? response.text : ''
  return html`
    <label class="ka-freetext">
      <span class="ka-freetext-hint">${slot.hint ?? '직접 적어도 됩니다'}</span>
      <textarea
        rows="2"
        value=${value}
        onInput=${(e: Event) =>
          updateDraft(setText(draft, slot, (e.target as HTMLTextAreaElement).value))}
      ></textarea>
    </label>
  `
}

function Question({ row, question }: { row: AskRow; question: AskQuestion }) {
  const draft = draftForRow(row)
  const response = responseFor(draft, question)
  const skipped = response?.kind === 'skipped'
  return html`
    <li class="ka-question">
      <p class="ka-prompt">${question.prompt}</p>
      <div class="ka-choices">
        ${question.choices.map(
          (choice) => html`<${ChoiceRow} row=${row} question=${question} choice=${choice} />`,
        )}
      </div>
      <${FreeText} row=${row} question=${question} />
      <div class="ka-question-actions">
        <button
          type="button"
          class=${`ka-skip${skipped ? ' is-picked' : ''}`}
          aria-pressed=${skipped}
          onClick=${() =>
            updateDraft(skipped ? clearQuestion(draft, question) : skipQuestion(draft, question))}
        >
          ${skipped ? '건너뜀' : '이 질문은 건너뛰기'}
        </button>
      </div>
    </li>
  `
}

function AskCard({ row }: { row: AskRow }) {
  const open = openAskId.value === row.askId
  const draft = draftForRow(row)
  const state = readiness(draft, row)
  const missing = state.state === 'missing' ? state.questions.length : 0
  return html`
    <article class=${`ka-card${open ? ' is-open' : ''}`}>
      <header class="ka-card-head">
        <span class="ka-keeper">${row.keeper}</span>
        <time class="ka-asked">${formatDateTimeKo(new Date(row.askedAt * 1000).toISOString())}</time>
      </header>
      ${row.context === null ? null : html`<p class="ka-context">${row.context}</p>`}
      ${open
        ? html`
            <ul class="ka-questions">
              ${row.questions.map((q) => html`<${Question} row=${row} question=${q} />`)}
            </ul>
            ${askError.value === null
              ? null
              : html`<p class="ka-error" role="alert">${askError.value}</p>`}
            <div class="ka-card-actions">
              <button
                type="button"
                class="ka-submit"
                disabled=${askSubmitting.value || state.state !== 'ready'}
                onClick=${() => void submitAnswer(row, null)}
              >
                ${askSubmitting.value ? '보내는 중…' : '답 보내기'}
              </button>
              ${missing === 0 ? null : html`<span class="ka-missing">${missing}개 남음</span>`}
              <button type="button" class="ka-cancel" onClick=${closeAsk}>닫기</button>
            </div>
          `
        : html`
            <p class="ka-summary">
              ${row.questions.length}개 질문 · ${row.questions.map((q) => q.header).join(' / ')}
            </p>
            <button type="button" class="ka-open" onClick=${() => selectAsk(row)}>답하기</button>
          `}
    </article>
  `
}

export function KeeperAsksSurface() {
  const { data, loading, error } = asksResource.state.value
  useEffect(() => {
    void refreshKeeperAsks()
  }, [])

  // A question already on screen is kept while a refresh is in flight;
  // blanking the panel would take it away from someone mid-answer.
  if (data === null && loading) return html`<${LoadingState} label="질문을 읽는 중" />`
  if (data === null) {
    return html`<p class="ka-error" role="alert">${error ?? '질문을 읽지 못했습니다'}</p>`
  }

  const open = data.rows.filter((row) => row.resolution.state === 'open')
  return html`
    <section class="ka-surface">
      <header class="ka-head">
        <h2>사람을 기다리는 질문 (${data.openCount})</h2>
        <button type="button" class="ka-refresh" onClick=${() => void refreshKeeperAsks()}>
          새로 읽기
        </button>
      </header>
      ${askConflict.value === null
        ? null
        : html`<p class="ka-conflict" role="status">${askConflict.value}</p>`}
      ${open.length === 0
        ? html`<p class="ka-empty">아무도 결정을 기다리고 있지 않습니다.</p>`
        : html`<div class="ka-list">${open.map((row) => html`<${AskCard} row=${row} />`)}</div>`}
    </section>
  `
}
