// The Keepers panel: a card for each Keeper of the person, with the model it
// works with, the field that gives it another and its conversation
// (talk-area.ts), and the form of a new Keeper. The models offered are the ones a Keeper can run on here: a model
// checked on an account whose subscription the server lets a Keeper run on.
// A Keeper that cannot work says so on its card before anything is pressed.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import { accountFacts } from './account-rows'
import type { Assign, Keeper, KeepersModel, Make } from './keepers'
import { ProblemNote, Retry, idTail, sessionEndedWords } from './notes'
import type { Shown } from './notes'
import type { SubscriptionsModel } from './subscriptions'
import { TalkPart } from './talk-area'
import { integrationName } from './wire'
import type { Integration, Owned } from './wire'

/** A Runtime a Keeper can be given here, and how the page names it. */
export interface Choice {
  readonly runtimeId: string
  readonly label: string
}

/** The Runtimes a Keeper can run on here, in the order of the subscriptions panel. */
export function runtimeChoices(integrations: readonly Integration[], owned: Owned): readonly Choice[] {
  return accountFacts(integrations, owned).flatMap(({ account, offered, runtimes }) => {
    if (offered === null || offered.calls.kind !== 'allowed') return []
    const subscription = `${integrationName(offered)} 계정 ${idTail(account.id)}`
    return runtimes.flatMap((runtime) => (runtime.model.read ? [{ runtimeId: runtime.id, label: `${runtime.model.value} · ${subscription}` }] : []))
  })
}

/** The model a Keeper works with, as far as the page knows it. */
type Uses =
  | { readonly kind: 'none' }
  | { readonly kind: 'runs'; readonly choice: Choice }
  /** The Runtime is the person's, and a Keeper cannot run on it here now. */
  | { readonly kind: 'stopped'; readonly model: string | null }
  /** The subscriptions are not read, or the Runtime is not among them. */
  | { readonly kind: 'unknown' }

function usesOf(keeper: Keeper, owned: Owned | null, choices: readonly Choice[] | null): Uses {
  if (keeper.runtimeId === null) return { kind: 'none' }
  const choice = choices?.find((one) => one.runtimeId === keeper.runtimeId)
  if (choice !== undefined) return { kind: 'runs', choice }
  const runtime = owned?.runtimes.find((one) => one.id === keeper.runtimeId)
  if (runtime === undefined) return { kind: 'unknown' }
  return { kind: 'stopped', model: runtime.model.read ? runtime.model.value : null }
}

// ---- words ----

const nameRuleWords = '영문, 숫자, 마침표(.), 밑줄(_), 붙임표(-)로 128자까지 쓸 수 있어요.'
const noChoiceWords = '고를 수 있는 모델이 아직 없어요. 위 구독에서 모델을 먼저 확인해 주세요.'

function usesWords(uses: Uses): string {
  switch (uses.kind) {
    case 'none': return '아직 쓸 모델을 고르지 않았어요.'
    case 'runs': return `쓰는 모델: ${uses.choice.label}`
    case 'stopped':
      return `쓰는 모델: ${uses.model ?? '알 수 없는 모델'}. 이 모델로는 지금 Keeper가 일할 수 없어요. 이유는 위 구독 카드에 있어요.`
    case 'unknown': return '쓰는 모델을 불러오지 못했어요.'
  }
}

function makeWords(making: Make): string {
  switch (making.kind) {
    case 'sending': return `${making.name} Keeper를 만들고 있어요.`
    case 'made':
      return making.existing
        ? `${making.name} Keeper는 다른 화면에서 먼저 만들어졌어요. 고른 모델은 정하지 않았어요. 모델은 그 Keeper의 카드에서 정해 주세요.`
        : `${making.name} Keeper를 만들었어요.`
    case 'leaving': return sessionEndedWords
    case 'idle':
    case 'not_sent':
    case 'refused':
    case 'unknown':
      return ''
  }
}

function assignWords(assign: Assign): string {
  switch (assign.kind) {
    case 'sending': return '모델을 정하고 있어요.'
    case 'done': return assign.existing ? '이미 이 모델로 일하고 있어요.' : '모델을 정했어요. 이제 이 모델로 일해요.'
    case 'leaving': return sessionEndedWords
    case 'refused':
    case 'unknown':
      return ''
  }
}

/** What a refusal of `status` means for a Keeper, when the page can say more
    than that it was refused. A 403 is not one: for a signed-in person it is
    the guard of the session (its token or the origin of the page), which
    the status does not tell apart. */
function refusedWords(status: number, step: 'make' | 'assign'): string | null {
  if (status === 400 && step === 'make') return `이 이름은 Keeper 이름으로 쓸 수 없어요. ${nameRuleWords}`
  if (status === 404 && step === 'assign') return 'Keeper나 고른 모델을 서버에서 찾지 못했어요. 페이지를 새로 고친 뒤 다시 골라 주세요.'
  return null
}

function Note({ title, lines, reason, attempts }: {
  readonly title: string
  readonly lines: readonly string[]
  readonly reason: string | null
  readonly attempts: number
}): VNode {
  return html`
    <div class="callout" role="alert">
      <p class="callout-title">${title}</p>
      ${lines.map((line) => html`<p>${line}</p>`)}
      ${reason === null ? null : html`<p class="hint">서버가 알려 준 이유: <span lang="en">${reason}</span></p>`}
      ${attempts > 1 ? html`<p class="hint">${attempts}번 시도했어요.</p>` : null}
    </div>
  `
}

/** What the page heard of a request whose end it does not know. */
function unknownWords(problem: Shown): string {
  switch (problem.kind) {
    case 'unreachable': return '서버의 답을 받지 못했어요.'
    case 'unreadable': return '서버의 답을 읽지 못했어요.'
    case 'refused': return '서버가 오류로 답했어요.'
  }
}

/** The alert of a request that came to nothing. The caller makes each one
    anew (its key is the count), so a screen reader says the second as it
    said the first. */
function Outcome({ title, step, outcome }: {
  readonly title: string
  readonly step: 'make' | 'assign'
  readonly outcome: Extract<Make | Assign, { kind: 'refused' | 'unknown' }>
}): VNode {
  const { problem, attempts } = outcome
  const reason = problem.kind === 'refused' ? problem.reason : null
  if (outcome.kind === 'unknown') {
    return html`<${Note} title=${title} attempts=${attempts} reason=${reason}
      lines=${[`${unknownWords(problem)} 서버가 했을 수도 있어요.`, '목록을 다시 불러왔어요. 목록이 그대로면 다시 해 주세요.']} />`
  }
  const words = refusedWords(outcome.problem.status, step)
  if (words === null) return html`<${ProblemNote} title=${title} failure=${{ problem, attempts }} />`
  return html`<${Note} title=${title} lines=${[words]} attempts=${attempts} reason=${reason} />`
}

// ---- a card ----

/** The field that gives a Keeper a model, and what the latest assignment did. */
function AssignArea({ keeper, uses, choices, assign, model, card }: {
  readonly keeper: Keeper
  readonly uses: Uses
  readonly choices: readonly Choice[]
  readonly assign: Assign | undefined
  readonly model: KeepersModel
  readonly card: string
}): VNode {
  const busy = assign?.kind === 'sending' || assign?.kind === 'leaving'
  const onSubmit = (event: Event): void => {
    event.preventDefault()
    const picked = new FormData(event.currentTarget as HTMLFormElement).get('runtime')
    if (!busy && typeof picked === 'string') void model.assign(keeper.id, picked)
  }
  // No prefix of an id here is the start of another, so two Keeper names
  // never make one id.
  const field = `keeper-field-${keeper.id}`
  const label = `keeper-label-${keeper.id}`
  const button = `keeper-button-${keeper.id}`
  const current = uses.kind === 'runs' ? uses.choice.runtimeId : null
  return html`
    <form class="check" onSubmit=${onSubmit}>
      <label id=${label} for=${field}>쓸 모델</label>
      <select id=${field} name="runtime" aria-labelledby=${`${label} ${card}`}>
        ${choices.map((choice) => html`<option key=${choice.runtimeId} value=${choice.runtimeId} selected=${choice.runtimeId === current}>${choice.label}</option>`)}
      </select>
      <button id=${button} type="submit" aria-disabled=${busy} aria-labelledby=${`${button} ${card}`}>
        ${keeper.runtimeId === null ? '모델 정하기' : '모델 바꾸기'}
      </button>
    </form>
    <p class="hint" role="status">${assign === undefined ? '' : assignWords(assign)}</p>
    ${assign?.kind === 'refused' || assign?.kind === 'unknown'
      ? html`<${Outcome} key=${assign.attempts} step="assign" outcome=${assign}
          title=${assign.kind === 'refused' ? `${keeper.id}의 모델을 정하지 못했어요` : `${keeper.id}의 모델을 정했는지 알 수 없어요`} />`
      : null}
  `
}

function Chip({ uses }: { readonly uses: Uses }): VNode | null {
  switch (uses.kind) {
    case 'runs': return html`<p class="chips"><span class="chip">일할 수 있음</span></p>`
    case 'none': return html`<p class="chips"><span class="chip chip-todo">모델 필요</span></p>`
    case 'stopped': return html`<p class="chips"><span class="chip chip-todo">지금 일할 수 없음</span></p>`
    case 'unknown': return null
  }
}

function KeeperRow({ keeper, owned, choices, model }: {
  readonly keeper: Keeper
  readonly owned: Owned | null
  readonly choices: readonly Choice[] | null
  readonly model: KeepersModel
}): VNode {
  const uses = usesOf(keeper, owned, choices)
  const titleId = `keeper-title-${keeper.id}`
  return html`
    <li class="row" data-home=${titleId}>
      <h3 id=${titleId} class="row-title" tabindex="-1">${keeper.id}</h3>
      <p>${choices === null && keeper.runtimeId !== null ? '구독을 불러오면 쓰는 모델이 나와요.' : usesWords(uses)}</p>
      <${Chip} uses=${uses} />
      ${choices === null
        ? null
        : choices.length === 0
          ? html`<p class="hint">${noChoiceWords}</p>`
          : html`<${AssignArea} keeper=${keeper} uses=${uses} choices=${choices} assign=${model.assigning.value.get(keeper.id)}
              model=${model} card=${titleId} />`}
      <${TalkPart} keeperId=${keeper.id} card=${titleId} talk=${model.talking} />
    </li>
  `
}

// ---- a new Keeper ----

function MakeForm({ model, choices }: { readonly model: KeepersModel; readonly choices: readonly Choice[] | null }): VNode {
  const making = model.making.value
  const name = useRef<HTMLInputElement>(null)
  const busy = making.kind === 'sending' || making.kind === 'leaving'
  // The form is emptied when the server made the Keeper, before the model
  // picked is given to it, so a name typed meanwhile is not lost.
  const onSubmit = async (event: Event): Promise<void> => {
    event.preventDefault()
    const form = event.currentTarget as HTMLFormElement
    const data = new FormData(form)
    const typed = data.get('name')
    const picked = data.get('runtime')
    if (busy || typeof typed !== 'string') return
    const outcome = await model.make(typed, typeof picked === 'string' && picked !== '' ? picked : null)
    if (outcome?.kind === 'made') form.reset()
    if (outcome?.kind === 'not_sent') name.current?.focus()
  }
  return html`
    <form class="keeper-form" aria-labelledby="keeper-new-title" data-home="keeper-new-title" onSubmit=${(event: Event) => { void onSubmit(event) }}>
      <h3 id="keeper-new-title" tabindex="-1">새 Keeper</h3>
      <div class="field">
        <label for="keeper-name">이름</label>
        <input ref=${name} id="keeper-name" name="name" autocomplete="off" spellcheck=${false} maxlength="128"
          aria-describedby="keeper-name-hint" />
        <p id="keeper-name-hint" class="hint">${nameRuleWords}</p>
      </div>
      ${choices === null || choices.length === 0
        ? html`<p class="hint">${choices === null ? '구독을 불러오면 쓸 모델을 고를 수 있어요.' : '고를 수 있는 모델이 아직 없어요.'} 모델은 Keeper를 만든 뒤에 골라도 돼요.</p>`
        : html`
            <div class="field">
              <label for="keeper-new-runtime">쓸 모델</label>
              <select id="keeper-new-runtime" name="runtime" aria-describedby="keeper-new-runtime-hint">
                ${choices.map((choice) => html`<option key=${choice.runtimeId} value=${choice.runtimeId}>${choice.label}</option>`)}
                <option value="">나중에 고르기</option>
              </select>
              <p id="keeper-new-runtime-hint" class="hint">모델 확인을 마친 구독의 모델만 나와요.</p>
            </div>
          `}
      <p><button type="submit" class="primary" aria-disabled=${busy}>Keeper 만들기</button></p>
    </form>
    <p class="hint" role="status">${makeWords(making)}</p>
    ${making.kind === 'not_sent'
      ? html`<${Note} key=${making.attempts} attempts=${making.attempts} reason=${null}
          title=${making.why === 'blank' ? 'Keeper 이름을 적어 주세요' : `${making.name} Keeper는 이미 있어요`}
          lines=${[making.why === 'blank' ? nameRuleWords : '다른 이름을 적어 주세요. 그 Keeper의 모델은 목록의 카드에서 바꿔요.']} />`
      : null}
    ${making.kind === 'refused' || making.kind === 'unknown'
      ? html`<${Outcome} key=${making.attempts} step="make" outcome=${making}
          title=${making.kind === 'refused' ? `${making.name} Keeper를 만들지 못했어요` : `${making.name} Keeper를 만들었는지 알 수 없어요`} />`
      : null}
  `
}

// ---- the panel ----

const headingId = 'keepers-heading'

/** Whether the focus is on nothing: the control that held it went away. */
const fell = (): boolean => document.activeElement === null || document.activeElement === document.body

export function KeepersPanel({ model, subscriptions }: { readonly model: KeepersModel; readonly subscriptions: SubscriptionsModel }): VNode {
  const view = model.view.value
  const panel = subscriptions.view.value
  const owned = panel.kind === 'read' ? panel.owned : null
  const choices = panel.kind === 'read' ? runtimeChoices(panel.integrations, panel.owned) : null
  const heading = useRef<HTMLHeadingElement>(null)
  const shown = useRef(view.kind)
  // A retry that read takes the pressed button away. The focus then goes to
  // the heading of the panel, not to the body of the page.
  useEffect(() => {
    const before = shown.current
    shown.current = view.kind
    if (before !== view.kind && (before === 'failed' || before === 'read') && fell()) heading.current?.focus()
  }, [view.kind])
  // A reading of the subscriptions can leave no model to give, which takes
  // the model fields and their buttons away. The focus then goes to the
  // title of the card or of the form that held it last, not to the body of
  // the page; a focus moved elsewhere stays.
  const home = useRef(headingId)
  const fields = choices !== null && choices.length > 0
  const hadFields = useRef(fields)
  useEffect(() => {
    const before = hadFields.current
    hadFields.current = fields
    if (before && !fields && fell()) document.getElementById(home.current)?.focus()
  }, [fields])
  const onFocusIn = (event: FocusEvent): void => {
    const holder = event.target instanceof Element ? event.target.closest('[data-home]') : null
    home.current = holder?.getAttribute('data-home') ?? headingId
  }
  return html`
    <section aria-labelledby=${headingId} onFocusIn=${onFocusIn}>
      <h2 id=${headingId} ref=${heading} tabindex="-1">Keeper</h2>
      <p class="hint">Keeper는 내 구독으로 일하는 내 에이전트예요.</p>
      ${view.kind === 'read'
        ? html`
            ${view.keepers.length === 0
              ? html`<p>아직 Keeper가 없어요. 아래에서 첫 Keeper를 만들어 보세요.</p>`
              : html`<ul class="rows">${view.keepers.map((keeper) => html`<${KeeperRow} key=${keeper.id} keeper=${keeper} owned=${owned} choices=${choices} model=${model} />`)}</ul>`}
            <${MakeForm} model=${model} choices=${choices} />
          `
        : view.kind === 'failed'
          ? html`
              <${ProblemNote} key=${view.failure.attempts} title="Keeper를 불러오지 못했어요" failure=${view.failure} />
              <${Retry} label="다시 시도" next=${view.next} onRetry=${() => { void model.retry() }} />
            `
          : html`<p class="hint" role="status">${view.kind === 'leaving' ? sessionEndedWords : view.kind === 'reading' && view.slow ? 'Keeper를 불러오고 있어요…' : ''}</p>`}
    </section>
  `
}
