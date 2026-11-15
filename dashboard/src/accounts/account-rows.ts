// The rows of the subscriptions panel: a card for each account the person
// connected, with the Runtimes made on it and whether a Keeper may run on it
// here. Each card says before anything is pressed what its account cannot do,
// and on an account a Keeper may run on, the person checks a model in its card.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import { checkLimitMinutes } from './check'
import type { Check, CheckFailure, ChecksModel } from './check'
import { Callout, ProblemNote, fell, idTail, sessionEndedWords } from './notes'
import { integrationName } from './wire'
import type { CallRefusal, Integration, IntegrationUnread, ModelUnread, Owned, ProviderAccount, Runtime } from './wire'

// ---- what the panel knows of each account ----

/** What the panel knows of one account before it says anything. */
export interface AccountFacts {
  readonly account: ProviderAccount
  /** The subscription the server offers for the account, or null when the
      account's subscription is not known or the server no longer offers it:
      nothing can be done with the account here. */
  readonly offered: Integration | null
  /** The Runtimes made on the account. */
  readonly runtimes: readonly Runtime[]
  /** A model was checked on the account and the server still finds it in its
      settings. A Runtime whose model it cannot read is not one a turn runs on. */
  readonly checked: boolean
  readonly keeper: KeeperOn
}

/** Whether a Keeper can run on an account here, or what stands in its way. */
export type KeeperOn =
  /** The server lets a Keeper run on the subscription, and a model was checked on the account. */
  | { readonly kind: 'can_run' }
  /** The server lets a Keeper run on the subscription; no model of the account is checked. */
  | { readonly kind: 'needs_model' }
  | { readonly kind: 'refused'; readonly refusal: CallRefusal }
  /** The account's subscription is not known, or the server no longer offers it. */
  | { readonly kind: 'not_offered' }

function keeperOn(offered: Integration | null, checked: boolean): KeeperOn {
  if (offered === null) return { kind: 'not_offered' }
  if (offered.calls.kind === 'refused') return { kind: 'refused', refusal: offered.calls.refusal }
  return checked ? { kind: 'can_run' } : { kind: 'needs_model' }
}

/** The subscriptions a Keeper may run on here. */
export const runnable = (integrations: readonly Integration[]): readonly Integration[] =>
  integrations.filter((one) => one.calls.kind === 'allowed')

/** The facts of each account, in the order the server lists the accounts.
    No Runtime is left out: an account is never unlinked
    (lib/auth/authz_provider_account.ml has only `link`), and a Runtime is
    made only on an account its maker owns (lib/auth/authz_runtime_state.ml
    refuses it with `Account_not_theirs`). */
export function accountFacts(integrations: readonly Integration[], owned: Owned): readonly AccountFacts[] {
  return owned.accounts.map((account) => {
    const integration = account.integration
    const runtimes = owned.runtimes.filter((runtime) => runtime.accountId === account.id)
    const offered = integration.read ? integrations.find((one) => one.id === integration.value) ?? null : null
    const checked = runtimes.some((runtime) => runtime.model.read)
    return { account, offered, runtimes, checked, keeper: keeperOn(offered, checked) }
  })
}

// ---- words ----

/** The name of the subscription of an account: the name the operator gave
    the provider, its id when the name is empty, or the id the login named
    when the server no longer offers it. */
function subscriptionName(account: ProviderAccount, offered: Integration | null): string {
  if (!account.integration.read) return '어떤 구독인지 알 수 없는 계정'
  return offered === null ? account.integration.value : integrationName(offered)
}

function integrationUnreadWords(unread: IntegrationUnread | 'unrecognised'): string {
  switch (unread) {
    case 'login_receipt_missing': return '이 계정의 로그인 기록이 없어요.'
    case 'login_receipt_unreadable': return '이 계정의 로그인 기록을 읽지 못했어요. 이 서버를 운영하는 사람에게 알려 주세요.'
    case 'unrecognised': return '서버가 이 계정의 구독을 알려 주지 않았어요.'
  }
}

/** Why a Keeper does not run on an account of the subscription `name` here. */
function refusedWords(refusal: CallRefusal, name: string): string {
  switch (refusal) {
    case 'native_tools_reach_other_homes':
      return `이 서버는 다른 사람의 폴더에 닿을 수 있는 도구를 막아요. 그래서 ${name} 구독으로는 Keeper를 실행할 수 없어요.`
    case 'native_tools_reach_person_homes':
      return `이 서버에는 다른 사람의 폴더가 있어서 그 폴더에 닿을 수 있는 도구를 막아요. 그래서 ${name} 구독으로는 Keeper를 실행할 수 없어요.`
    case 'native_unpublished':
      return `서버가 아직 도구를 허용할지 정하지 않았어요. 그래서 지금은 ${name} 구독으로 Keeper를 실행할 수 없어요.`
    case 'person_homes_unread':
      return `서버가 사람들의 폴더를 확인하지 못했어요. 그래서 지금은 ${name} 구독으로 Keeper를 실행할 수 없어요. 이 서버를 운영하는 사람에게 알려 주세요.`
    case 'unrecognised':
      return `이 서버는 ${name} 구독으로 Keeper를 실행하지 않아요.`
  }
}

/** Why the model of a Runtime is not known, or null when the row of its
    account already says it: the subscription is not known, or the server no
    longer declares it and so does not offer it. */
function modelUnreadWords(unread: ModelUnread | 'unrecognised'): string | null {
  switch (unread) {
    case 'account_integration_unread': return null
    case 'template_not_declared': return null
    case 'configuration_unavailable': return '서버 설정을 읽지 못해서 모델을 알 수 없어요.'
    case 'runtime_not_bound': return '서버 설정이 바뀌어서 이 구독으로 이 모델을 부를 수 없어요.'
    case 'unrecognised': return '서버가 이 모델을 알려 주지 않았어요.'
  }
}

const operatorWords = '이 서버를 운영하는 사람에게 알려 주세요.'

/** Why a call of a model did not pass, and what the person can do next. */
function checkFailureWords(failure: CheckFailure): string {
  switch (failure) {
    case 'rate_limited': return '구독 쪽이 요청 한도나 사용 시간대에 걸렸다며 막았어요. 한도가 풀린 뒤 다시 확인해 주세요.'
    case 'quota_exhausted': return '이 구독의 사용량을 다 썼어요. 사용량이 다시 열린 뒤 확인해 주세요.'
    case 'provider_overloaded': return '구독 쪽 서버가 바쁘거나 오류를 냈어요. 잠시 뒤 다시 확인해 주세요.'
    case 'provider_auth_refused': return '구독 쪽이 이 계정의 로그인을 받지 않았어요. 이 계정이 이 모델을 쓸 수 있는지 확인해 주세요.'
    // The server gives this code for a request the provider refused, and
    // for a client or a connection of its own that failed on the way.
    case 'provider_rejected': return `모델을 부르는 요청이 실패했어요. 다시 확인해 보고, 같은 일이 되풀이되면 ${operatorWords}`
    case 'model_not_found': return '구독 쪽에 이 모델이 없어요. 다른 모델을 골라 주세요.'
    case 'timed_out': return '정해진 시간 안에 확인이 끝나지 않았어요. 다시 확인해 주세요.'
    case 'tool_not_called':
    case 'tool_result_not_consumed':
      return '모델이 답했지만 확인용 도구를 제대로 쓰지 않았어요. Keeper는 도구를 써야 일할 수 있어요. 다시 확인하거나 다른 모델을 골라 주세요.'
    case 'empty_response': return '모델이 빈 답을 보냈어요. 다시 확인해 주세요.'
    case 'provider_unreachable': return `이 서버가 구독 쪽에 닿지 못했어요. ${operatorWords}`
    case 'model_unreported': return `로그인 도구가 어떤 모델이 답했는지 알려 주지 않았어요. ${operatorWords}`
    case 'client_not_authenticated':
      return `로그인 도구가 이 계정의 로그인을 쓰지 못했어요. 구독을 다시 연결해 새 계정에서 확인해 보고, 같은 일이 되풀이되면 ${operatorWords}`
    case 'unsupported_runtime': return `이 서버는 이 구독의 모델을 아직 확인하지 못해요. ${operatorWords}`
    case 'missing_credential':
    case 'invalid_credential':
    case 'tools_not_declared':
    case 'invalid_configuration':
    case 'client_not_started':
    case 'account_not_authorized':
      return `이 서버의 설정 때문에 확인하지 못했어요. ${operatorWords}`
    case 'unrecognised': return '이 화면이 모르는 까닭으로 확인하지 못했어요.'
  }
}

/** The line a screen reader reads out for the check of an account. A check
    that came to nothing is said in an alert under it. */
function checkWords(check: Check): string {
  switch (check.kind) {
    case 'checking':
      return `${check.model} 모델을 확인하고 있어요. 서버가 이 계정으로 모델을 한 번 불러 봐요. 길게는 ${checkLimitMinutes}분쯤 걸려요.`
    case 'passed':
      return check.made
        ? `${check.model} 모델을 확인했어요. 이제 이 구독으로 Keeper를 실행할 수 있어요.`
        : `${check.model} 모델을 다시 확인했어요. 이 모델로 Keeper를 실행할 수 있어요.`
    case 'failed':
    case 'not_done':
    case 'unknown':
      return ''
    case 'leaving': return sessionEndedWords
  }
}

// ---- the rows ----

/** What an account can do here, in words and a border, never in colour alone.
    Nothing is suggested for an account the server offers no subscription for:
    nothing can be done with it here. */
function Chips({ facts }: { readonly facts: AccountFacts }): VNode {
  const { keeper, checked } = facts
  if (keeper.kind === 'not_offered') return html`<p class="chips"><span class="chip chip-todo">여기서 쓸 수 없음</span></p>`
  return html`
    <p class="chips">
      <span class=${checked ? 'chip' : 'chip chip-todo'}>${checked ? '모델 확인됨' : '모델 확인 필요'}</span>
      ${keeper.kind === 'can_run' ? html`<span class="chip">Keeper 실행 가능</span>` : null}
      ${keeper.kind === 'refused' ? html`<span class="chip chip-todo">Keeper 실행 불가</span>` : null}
    </p>
  `
}

function UnreadModel({ unread }: { readonly unread: ModelUnread | 'unrecognised' }): VNode {
  const why = modelUnreadWords(unread)
  return why === null ? html`<span>알 수 없는 모델</span>` : html`<span>알 수 없는 모델</span> <span class="hint">${why}</span>`
}

function Models({ runtimes }: { readonly runtimes: readonly Runtime[] }): VNode {
  if (runtimes.length === 0) return html`<p class="hint">아직 확인한 모델이 없어요.</p>`
  return html`
    <ul class="models">
      ${runtimes.map((runtime) => html`
        <li key=${runtime.id}>
          ${runtime.model.read ? html`<span class="model">${runtime.model.value}</span>` : html`<${UnreadModel} unread=${runtime.model.unread} />`}
        </li>
      `)}
    </ul>
  `
}

/** The alert of a call of a model that did not pass. */
function FailedNote({ check }: { readonly check: Extract<Check, { kind: 'failed' }> }): VNode {
  return html`<${Callout} title=${`${check.model} 모델을 확인하지 못했어요`} lines=${[checkFailureWords(check.failure)]}
    reason=${check.reason} attempts=${check.attempts} />`
}

/** The alert of a check whose answer did not come or could not be read. */
function UnknownNote({ check }: { readonly check: Extract<Check, { kind: 'unknown' }> }): VNode {
  const heard = check.problem.kind === 'unreachable' ? '서버의 답을 받지 못했어요.' : '서버의 답을 읽지 못했어요.'
  return html`<${Callout} title=${`${check.model} 모델을 확인했는지 알 수 없어요`} reason=${null} attempts=${check.attempts}
    lines=${[`${heard} 서버가 확인을 했을 수도 있어요.`, '조금 뒤 다시 확인해 주세요. 확인이 끝났다면 위 모델 목록에도 나와요.']} />`
}

/** The models of the subscription of an account, the button that checks the
    one picked, and what the latest check found. The button stays where it is
    while a check runs, marked, so the focus of the person who pressed it
    stays on it. The line a screen reader reads out is there from the start;
    each check that comes to nothing puts a new alert on the page, so a
    second one for the same reason is read out too. The field and the
    button are named with the card, so a list of the controls of the page
    tells the cards apart. */
function CheckArea({ accountId, models, check, checks, card }: {
  readonly accountId: string
  readonly models: readonly string[]
  readonly check: Check | undefined
  readonly checks: ChecksModel
  /** The ids of what names the card: its title and its account line. */
  readonly card: string
}): VNode {
  if (models.length === 0) return html`<p class="hint">이 서버에는 이 구독으로 확인할 수 있는 모델이 없어요. ${operatorWords}</p>`
  const busy = check?.kind === 'checking' || check?.kind === 'leaving'
  const onSubmit = (event: Event): void => {
    event.preventDefault()
    const picked = new FormData(event.currentTarget as HTMLFormElement).get('model')
    if (!busy && typeof picked === 'string') void checks.check(accountId, picked)
  }
  const field = `check-model-${accountId}`
  const label = `check-label-${accountId}`
  const button = `check-button-${accountId}`
  return html`
    <form class="check" onSubmit=${onSubmit}>
      <label id=${label} for=${field}>확인할 모델</label>
      <select id=${field} name="model" aria-labelledby=${`${label} ${card}`}>
        ${models.map((model) => html`<option key=${model} value=${model}>${model}</option>`)}
      </select>
      <button id=${button} type="submit" aria-disabled=${busy} aria-labelledby=${`${button} ${card}`}>모델 확인</button>
    </form>
    <p class="hint" role="status">${check === undefined ? '' : checkWords(check)}</p>
    ${check?.kind === 'failed' ? html`<${FailedNote} key=${check.attempts} check=${check} />` : null}
    ${check?.kind === 'not_done'
      ? html`<${ProblemNote} key=${check.attempts} title=${`${check.model} 모델을 확인하지 못했어요`} failure=${{ problem: check.problem, attempts: check.attempts }} />`
      : null}
    ${check?.kind === 'unknown' ? html`<${UnknownNote} key=${check.attempts} check=${check} />` : null}
  `
}

function AccountRow({ facts, checks }: { readonly facts: AccountFacts; readonly checks: ChecksModel }): VNode {
  const { account, offered } = facts
  const name = subscriptionName(account, offered)
  const title = useRef<HTMLHeadingElement>(null)
  const checkable = offered !== null && offered.calls.kind === 'allowed' && offered.models.length > 0
  const couldCheck = useRef(checkable)
  // A reading after a check can find the subscription no longer one a
  // Keeper may run on, which takes the pressed button away. The focus then
  // goes to the title of the card, not to the body of the page; a focus the
  // person moved elsewhere meanwhile stays.
  useEffect(() => {
    const before = couldCheck.current
    couldCheck.current = checkable
    if (before && !checkable && fell()) title.current?.focus()
  }, [checkable])
  const titleId = `row-title-${account.id}`
  const accountLine = `row-account-${account.id}`
  return html`
    <li class="row">
      <h3 ref=${title} id=${titleId} class="row-title" tabindex="-1">${name}</h3>
      <p id=${accountLine} class="hint">계정 <span class="mono">${idTail(account.id)}</span></p>
      <${Chips} facts=${facts} />
      ${account.integration.read
        ? (offered === null ? html`<p class="hint">이 서버는 이 구독을 더는 제공하지 않아요.</p>` : null)
        : html`<p class="hint">${integrationUnreadWords(account.integration.unread)}</p>`}
      ${facts.keeper.kind === 'refused' ? html`<p class="hint">${refusedWords(facts.keeper.refusal, name)}</p>` : null}
      <${Models} runtimes=${facts.runtimes} />
      ${offered !== null && offered.calls.kind === 'allowed'
        ? html`<${CheckArea} accountId=${account.id} models=${offered.models} check=${checks.checks.value.get(account.id)}
            checks=${checks} card=${`${titleId} ${accountLine}`} />`
        : null}
    </li>
  `
}

export function AccountList({ integrations, owned, checks }: {
  readonly integrations: readonly Integration[]
  readonly owned: Owned
  readonly checks: ChecksModel
}): VNode {
  if (owned.accounts.length === 0) return html`<p>아직 연결한 구독이 없어요.</p>`
  return html`
    <ul class="rows">
      ${accountFacts(integrations, owned).map((facts) => html`<${AccountRow} key=${facts.account.id} facts=${facts} checks=${checks} />`)}
    </ul>
  `
}
