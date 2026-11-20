// The rows of the subscriptions panel: a card for each account the person
// connected, with the Runtimes made on it and whether a Keeper may run on it
// here. Each card says before anything is pressed what its account cannot do,
// and on an account whose subscription has a model to check, the person
// checks one in its card.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { checkLimitMinutes } from './check'
import type { Check, CheckFailure, ChecksModel } from './check'
import type { RemovalStopped, RemovalsModel, Removing } from './key-remove'
import type { ReplacementsModel } from './key-replace'
import { ReplaceArea } from './key-replace-area'
import { Callout, ProblemNote, fell, idTail, keyStaysValidWords, noModelWords, operatorWords, sessionEndedWords } from './notes'
import { checkable, integrationName } from './wire'
import type { CallRefusal, Held, Integration, KeyState, ModelUnread, Owned, ProviderAccount, Removal, Replacement, Runtime, Withheld } from './wire'

// ---- what the panel knows of each account ----

/** What the panel knows of one account before it says anything. */
export interface AccountFacts {
  readonly account: ProviderAccount
  /** The subscription the server offers for the account, or null when the
      server no longer offers it: nothing can be done with the account here. */
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
  /** The server lets a Keeper run on the subscription; no model of the account is checked, and one can be. */
  | { readonly kind: 'needs_model' }
  /** As `needs_model`, and the server offers no model of the subscription to check. */
  | { readonly kind: 'no_model' }
  | { readonly kind: 'refused'; readonly refusal: CallRefusal }
  /** As `can_run`, on a key account whose key the server did not find
      readable when it listed the account: it refuses a turn on the account
      before it starts a client
      (lib/server/server_setup_account_login.ml, `person_runtime`). */
  | { readonly kind: 'key_not_readable' }
  /** The server no longer offers the account's subscription. */
  | { readonly kind: 'not_offered' }
  /** A removal of the account did not go through. The server refuses every
      use of it, whatever its subscription lets a Keeper do. */
  | { readonly kind: 'removal_left' }
  /** A replacement of the key of the account did not go through. The server
      refuses every use of it until its key is sent again. */
  | { readonly kind: 'replacement_left' }

/** Whether a call of the account has what it runs on: a login, or a key
    the server read when it listed the account. */
const holdsWhatItRunsOn = (held: Held): boolean => held.kind === 'login' || held.key === 'readable'

function keeperOn(account: ProviderAccount, offered: Integration | null, checked: boolean): KeeperOn {
  if (account.left !== null) return account.left.kind === 'removal' ? { kind: 'removal_left' } : { kind: 'replacement_left' }
  if (offered === null) return { kind: 'not_offered' }
  if (offered.calls.kind === 'refused') return { kind: 'refused', refusal: offered.calls.refusal }
  if (checked) return holdsWhatItRunsOn(account.held) ? { kind: 'can_run' } : { kind: 'key_not_readable' }
  return checkable(offered) ? { kind: 'needs_model' } : { kind: 'no_model' }
}

/** The facts of each account, in the order the server lists the accounts.
    No Runtime the server lists is left out: it lists a Runtime only with
    its account (wire.ts, `readOwned`). */
export function accountFacts(integrations: readonly Integration[], owned: Owned): readonly AccountFacts[] {
  return owned.accounts.map((account) => {
    const runtimes = owned.runtimes.filter((runtime) => runtime.accountId === account.id)
    const offered = integrations.find((one) => one.id === account.integration) ?? null
    const checked = runtimes.some((runtime) => runtime.model.read)
    return { account, offered, runtimes, checked, keeper: keeperOn(account, offered, checked) }
  })
}

// ---- words ----

/** The name of the subscription of an account: the name the operator gave
    the provider, its id when the name is empty, or the id the account
    names when the server no longer offers it. */
function subscriptionName(account: ProviderAccount, offered: Integration | null): string {
  return offered === null ? account.integration : integrationName(offered)
}

/** What the server found of the key file of a key account, when a use of
    the account would not read a key. It is what was there when the list was
    read: the file of an account whose registration is under way is not
    there yet. */
function keyWords(key: KeyState): string | null {
  switch (key) {
    case 'readable': return null
    case 'key_missing':
      return '이 계정의 key 파일이 이 서버에 없어요. key 를 넣는 중이면 곧 생겨요. 계속 없으면 이 계정으로는 모델을 부를 수 없어요. 「key 바꾸기」로 key 를 다시 넣을 수 있어요.'
    case 'key_unreadable': return `이 서버가 이 계정의 key 파일에서 key 를 읽지 못했어요. 이 계정으로는 모델을 부를 수 없어요. 「key 바꾸기」로 key 를 다시 넣어 보세요. 그래도 읽지 못하면 ${operatorWords}`
    case 'not_looked_at': return `이 서버가 이 계정의 key 파일을 확인하지 못했어요. ${operatorWords}`
    case 'unrecognised': return '서버가 이 계정의 key 상태를 알려 주지 않았어요.'
  }
}

/** Whether the key of an account a removal was left on is still on the
    server. It is what the server found of the key file when it listed the
    account, not a guess from where the removal stopped: a removal that never
    started can be of an account whose key file was never made. */
function keyLeftWords(held: Held): string {
  if (held.kind === 'login') return ''
  switch (held.key) {
    case 'readable': return ' key 가 아직 이 서버에 있어요.'
    case 'key_missing': return ' key 파일은 이 서버에 없어요.'
    case 'key_unreadable': return ' key 파일이 이 서버에 남아 있어요.'
    case 'not_looked_at':
    case 'unrecognised':
      return ' key 파일이 이 서버에 남아 있을 수 있어요.'
  }
}

/** What a removal that did not go through left on the server
    (lib/auth_preview.ml, `removal_code`). */
function removalWords(removal: Removal, held: Held): string {
  const left = `${keyLeftWords(held)} 이 계정으로는 아무것도 실행되지 않아요.`
  switch (removal) {
    case 'key_not_removed': return `이 계정을 없애다가 멈췄어요.${left}`
    case 'home_not_removed': return `이 계정을 없애다가 멈췄어요. 계정의 다른 파일이 이 서버에 남아 있어요.${left}`
    case 'start_given_up': return `이 계정을 없애려다 시작하지 못했어요.${left}`
    case 'unrecognised': return `이 계정을 없애는 일이 끝나지 않았어요.${left}`
  }
}

/** What a replacement of the key that did not go through left on the
    server (lib/auth_preview.ml, `provider_accounts`). No record of the
    replacement went in: a key the server has for the account is the one
    from before. Whether it has one is not said here. */
function replacementWords(replacement: Replacement): string {
  const left = '이 계정으로는 아무것도 실행되지 않아요.'
  switch (replacement) {
    case 'start_given_up':
      return `이 계정의 key 를 바꾸려다 시작하지 못했어요. 서버의 key 는 바뀌지 않았어요. ${left} key 를 다시 보내면 풀려요. 계정을 없애도 돼요.`
    case 'unrecognised': return `이 계정의 key 를 바꾸는 일이 끝나지 않았어요. ${left}`
  }
}

/** What the line under the remove button says: what a second press does
    once the first one asked, else what the removal is doing. A removal that
    came to nothing is said in an alert under it. `again` when a removal was
    left on the account, whose models the list already leaves out. */
function removeLineWords(removing: Removing | undefined, sure: boolean, again: boolean): string {
  if (sure) {
    return again
      ? `한 번 더 누르면 멈춘 없애기를 이어서 끝내요. 되돌릴 수 없어요. ${keyStaysValidWords}`
      : `한 번 더 누르면 이 서버에서 이 계정과 key 를 지워요. 되돌릴 수 없어요. 이 계정으로 확인한 모델도 목록에서 없어져요. ${keyStaysValidWords}`
  }
  switch (removing?.kind) {
    case undefined: return ''
    case 'sending': return '없애고 있어요…'
    // On the page only until the list that was asked for comes.
    case 'removed': return removing.already ? '서버에 이 계정이 없어요.' : '서버가 이 계정을 없앴다고 답했어요.'
    case 'leaving': return sessionEndedWords
    case 'refused':
    case 'unknown':
      return ''
  }
}

/** Why the server did not remove an account, and what the person does
    next. A refusal with no code of the route is said in the words every
    part of the console shares (notes.ts, `ProblemNote`). */
function removalRefusedWords(code: Exclude<RemovalStopped, 'unrecognised'>): string {
  switch (code) {
    case 'account_call_running': return '이 계정으로 호출이 돌고 있어요. 끝난 뒤 다시 없애 주세요.'
    case 'removal_not_recorded': return '서버가 없애기를 기록하지 못했어요. 다시 없애 주세요.'
    case 'key_not_removed': return '서버가 key 를 지우지 못했어요. key 가 아직 이 서버에 있어요. 다시 없애 주세요.'
    case 'home_not_removed': return '서버가 key 는 지웠고, 계정의 다른 파일을 지우지 못했어요. 다시 없애 주세요.'
    case 'removal_refused': return '내 계정이 지금 쓸 수 있는 상태가 아니라서 없애지 못했어요.'
    case 'internal_error': return '서버가 예상하지 못한 까닭으로 거절했어요. 없애기는 시작되지 않았어요.'
    case 'not_a_key_account': return '로그인으로 연결한 계정이라 여기서 없앨 수 없어요.'
  }
}

/** What the page heard of a removal it has no word of the server on. */
function unheardWords(answer: Extract<Removing, { kind: 'unknown' }>['answer']): string {
  switch (answer) {
    case 'none': return '서버의 답을 받지 못했어요. 서버가 계정을 없앴을 수도 있어요.'
    case 'unreadable': return '서버의 답을 읽지 못했어요. 서버가 계정을 없앴을 수도 있어요.'
    case 'server_failed': return '서버 쪽이 오류로 답했고, 없애지 않았다고는 말하지 않았어요. 서버가 계정을 없앴을 수도 있어요.'
  }
}

/** The alert of a removal the server refused or did not finish. */
function StoppedNote({ removing }: { readonly removing: Extract<Removing, { kind: 'refused' }> }): VNode {
  const title = '계정을 없애지 못했어요'
  if (removing.code === 'unrecognised') {
    return html`<${ProblemNote} title=${title} failure=${{ problem: { kind: 'refused', status: removing.status, reason: removing.reason }, attempts: removing.attempts }} />`
  }
  return html`<${Callout} title=${title} lines=${[removalRefusedWords(removing.code)]} reason=${removing.reason} attempts=${removing.attempts} />`
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
    account already says the server no longer declares the subscription. */
function modelUnreadWords(unread: ModelUnread | 'unrecognised'): string | null {
  switch (unread) {
    case 'template_not_declared': return null
    case 'configuration_unavailable': return '서버 설정을 읽지 못해서 모델을 알 수 없어요.'
    case 'runtime_not_bound': return '서버 설정이 바뀌어서 이 구독으로 이 모델을 부를 수 없어요.'
    case 'unrecognised': return '서버가 이 모델을 알려 주지 않았어요.'
  }
}

/** Why a call of a model did not pass, and what the person can do next. */
function checkFailureWords(failure: CheckFailure): string {
  switch (failure) {
    case 'key_refused':
      return '키가 거절됐어요. 구독 쪽이 이 계정의 API key 를 받지 않았어요. key 를 폐기했거나 잘못 넣었다면, 「key 바꾸기」로 key 를 다시 넣어 주세요.'
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
  const held = facts.account.held.kind === 'key' ? html`<span class="chip">API key 로 연결</span>` : null
  if (keeper.kind === 'removal_left') return html`<p class="chips">${held}<span class="chip chip-todo">없애기가 끝나지 않음</span></p>`
  if (keeper.kind === 'replacement_left') return html`<p class="chips">${held}<span class="chip chip-todo">key 바꾸기가 끝나지 않음</span></p>`
  if (keeper.kind === 'not_offered') return html`<p class="chips">${held}<span class="chip chip-todo">여기서 쓸 수 없음</span></p>`
  return html`
    <p class="chips">
      ${held}
      <span class=${checked ? 'chip' : 'chip chip-todo'}>${checked ? '모델 확인됨' : keeper.kind === 'no_model' ? '확인할 모델 없음' : '모델 확인 필요'}</span>
      ${keeper.kind === 'can_run' ? html`<span class="chip">Keeper 실행 가능</span>` : null}
      ${keeper.kind === 'refused' || keeper.kind === 'key_not_readable' ? html`<span class="chip chip-todo">Keeper 실행 불가</span>` : null}
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
function CheckArea({ accountId, models, withheld, check, checks, card }: {
  readonly accountId: string
  readonly models: readonly string[]
  readonly withheld: readonly Withheld[]
  readonly check: Check | undefined
  readonly checks: ChecksModel
  /** The ids of what names the card: its title and its account line. */
  readonly card: string
}): VNode {
  if (models.length === 0) {
    return html`<p class="hint">이 서버에는 이 구독으로 확인할 수 있는 모델이 없어요. ${noModelWords(withheld)}</p>`
  }
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

/** What the card of an account says and offers while nothing is left on
    it: what stands in the way of its use, the models checked on it, and the
    check of one. */
function InUse({ facts, name, checks, card }: {
  readonly facts: AccountFacts
  readonly name: string
  readonly checks: ChecksModel
  readonly card: string
}): VNode {
  const { account, offered } = facts
  const key = account.held.kind === 'key' ? keyWords(account.held.key) : null
  return html`
    ${offered === null ? html`<p class="hint">이 서버는 이 구독을 더는 제공하지 않아요.</p>` : null}
    ${key === null ? null : html`<p class="hint">${key}</p>`}
    ${facts.keeper.kind === 'refused' ? html`<p class="hint">${refusedWords(facts.keeper.refusal, name)}</p>` : null}
    <${Models} runtimes=${facts.runtimes} />
    ${offered !== null && offered.calls.kind === 'allowed'
      ? html`<${CheckArea} accountId=${account.id} models=${offered.models} withheld=${offered.withheld} check=${checks.checks.value.get(account.id)}
          checks=${checks} card=${card} />`
      : null}
  `
}

/** The button that removes a key account, which asks once more before it
    does, with its line and what came of the latest removal. The button is
    the same one before and after a removal that stopped, so the focus of
    the person who pressed it stays on it. It is named with the card. */
function RemoveArea({ accountId, removals, card, again }: {
  readonly accountId: string
  readonly removals: RemovalsModel
  /** The ids of what names the card: its title and its account line. */
  readonly card: string
  /** A removal was left on the account: this one goes on from it. */
  readonly again: boolean
}): VNode {
  const removing = removals.removing.value.get(accountId)
  const [sure, setSure] = useState(false)
  const button = useRef<HTMLButtonElement>(null)
  const busy = removing?.kind === 'sending' || removing?.kind === 'leaving'
  const press = (): void => {
    if (busy) return
    if (!sure) {
      setSure(true)
      return
    }
    setSure(false)
    void removals.remove(accountId)
  }
  const back = (): void => {
    setSure(false)
    button.current?.focus()
  }
  const id = `remove-${accountId}`
  const backId = `remove-back-${accountId}`
  const line = `remove-line-${accountId}`
  return html`
    <p class="actions">
      <button ref=${button} id=${id} type="button" aria-disabled=${busy} aria-labelledby=${`${id} ${card}`} aria-describedby=${line} onClick=${press}>
        ${sure ? '정말 없애기' : again ? '다시 없애기' : '없애기'}
      </button>
      ${sure ? html`<button id=${backId} type="button" aria-labelledby=${`${backId} ${card}`} onClick=${back}>취소</button>` : null}
    </p>
    <p id=${line} class="hint" role="status">${removeLineWords(removing, sure, again)}</p>
    ${removing?.kind === 'refused' ? html`<${StoppedNote} key=${removing.attempts} removing=${removing} />` : null}
    ${removing?.kind === 'unknown'
      ? html`<${Callout} key=${removing.attempts} title="계정을 없앴는지 알 수 없어요" reason=${null} attempts=${removing.attempts}
          lines=${[unheardWords(removing.answer), '이 계정이 그대로 보이면 다시 없애 주세요.']} />`
      : null}
  `
}

function AccountRow({ facts, checks, removals, replacements }: {
  readonly facts: AccountFacts
  readonly checks: ChecksModel
  readonly removals: RemovalsModel
  readonly replacements: ReplacementsModel
}): VNode {
  const { account, offered } = facts
  const name = subscriptionName(account, offered)
  const title = useRef<HTMLHeadingElement>(null)
  const left = account.left
  const canCheck = left === null && offered !== null && checkable(offered)
  const canReplace = account.held.kind === 'key' && left?.kind !== 'removal'
  const could = useRef({ canCheck, canReplace })
  // A reading can take a control away with the focus on it. One after a
  // check can find the subscription with no model to check, or its calls
  // refused, and the pressed button goes. One after a key was sent can find
  // a removal left on the account, and the field of the key goes. The
  // focus then goes to the title of the card, not to the body of the page;
  // a focus the person moved elsewhere meanwhile stays.
  useEffect(() => {
    const before = could.current
    could.current = { canCheck, canReplace }
    if (((before.canCheck && !canCheck) || (before.canReplace && !canReplace)) && fell()) title.current?.focus()
  }, [canCheck, canReplace])
  const titleId = `row-title-${account.id}`
  const accountLine = `row-account-${account.id}`
  return html`
    <li class="row">
      <h3 ref=${title} id=${titleId} class="row-title" tabindex="-1">${name}</h3>
      <p id=${accountLine} class="hint">계정 <span class="mono">${idTail(account.id)}</span></p>
      <${Chips} facts=${facts} />
      ${left === null
        ? html`<${InUse} facts=${facts} name=${name} checks=${checks} card=${`${titleId} ${accountLine}`} />`
        : html`<p class="hint">${left.kind === 'removal' ? removalWords(left.stage, account.held) : replacementWords(left.stage)}</p>`}
      ${canReplace
        ? html`<${ReplaceArea} accountId=${account.id} replacements=${replacements} card=${`${titleId} ${accountLine}`} again=${left?.kind === 'replacement'} />`
        : null}
      ${account.held.kind === 'key'
        ? html`<${RemoveArea} accountId=${account.id} removals=${removals} card=${`${titleId} ${accountLine}`} again=${left?.kind === 'removal'} />`
        : null}
    </li>
  `
}

export function AccountList({ integrations, owned, checks, removals, replacements }: {
  readonly integrations: readonly Integration[]
  readonly owned: Owned
  readonly checks: ChecksModel
  readonly removals: RemovalsModel
  readonly replacements: ReplacementsModel
}): VNode {
  if (owned.accounts.length === 0) return html`<p>아직 연결한 구독이 없어요.</p>`
  return html`
    <ul class="rows">
      ${accountFacts(integrations, owned).map((facts) => html`<${AccountRow} key=${facts.account.id} facts=${facts} checks=${checks} removals=${removals} replacements=${replacements} />`)}
    </ul>
  `
}
