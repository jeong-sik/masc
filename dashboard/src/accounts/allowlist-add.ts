// The form of the allowlist panel that puts an account on the list; what came
// of the latest registration; and the alert of a request about an entry that
// came to nothing (allowlist.ts).

import { html } from 'htm/preact'
import { useRef, useState } from 'preact/hooks'
import type { Dispatch, StateUpdater } from 'preact/hooks'
import type { VNode } from 'preact'
import { Callout, ProblemNote, sessionEndedWords } from './notes'
import { maxGithubUserId, providers, readTyped } from './allowlist'
import type { Add, AllowlistModel, Provider, Remove, Typed } from './allowlist'
import { identityWords } from './member-rows'
import { unknownWords } from './token-make'

const formTitleId = 'allowlist-new-title'
const fieldId = 'allowlist-account'
const fieldHintId = 'allowlist-account-hint'
const mistakeId = 'allowlist-account-mistake'
const addTipId = 'allowlist-add-tip'
/** The answers of a request about an entry the page has words for (lib/auth/login_allowlist_routes.mli). */
const forbidden = 403
const notFound = 404
const conflict = 409

// ---- words ----

/** The name of a way of signing in, and what its field takes. */
export function providerWords(provider: Provider): readonly [string, string] {
  switch (provider) {
    case 'github': return ['GitHub', 'GitHub 사용자 번호']
    case 'google': return ['Google', 'Google 계정 sub']
  }
}

/** What is wrong with what the Admin typed, which is not sent. */
function mistakeWords(why: Extract<Typed, { ok: false }>['why']): string {
  switch (why) {
    case 'empty': return '칸이 비어 있어요.'
    case 'not_a_number': return '숫자만 적어 주세요. 로그인 이름이 아니라 사용자 번호예요.'
    case 'out_of_range': return `GitHub 사용자 번호는 1부터 ${maxGithubUserId.toLocaleString('ko-KR')}까지예요.`
    case 'not_a_sub': return '공백 없는 영문·숫자·기호로 255자까지 적어 주세요.'
  }
}

function addWords(adding: Add): string {
  switch (adding.kind) {
    case 'sending': return '목록에 넣고 있어요…'
    case 'done':
      return adding.registered.previouslyDeleted
        ? `넣었어요: ${identityWords(adding.identity)}. 이 계정으로 전에 들어왔던 사람은 삭제됐어요. 다시 로그인하면 새 구성원으로 들어와요.`
        : `넣었어요: ${identityWords(adding.identity)}. 이 계정으로 로그인하면 구성원으로 들어와요.`
    case 'leaving': return sessionEndedWords
    case 'idle':
    case 'refused':
    case 'unknown':
      return ''
  }
}

/** The words of a refusal the page can say more of than that it was
    refused. A 403 on a request from this page comes of a session another
    tab replaced, and the next press carries the token of now, as on the
    invitations panel. */
function refusedWords(status: number, step: 'add' | 'remove'): readonly string[] | null {
  if (status === forbidden) {
    return [
      '서버가 이 요청을 받지 않았어요.',
      '다른 탭에서 다시 로그인했다면 한 번 더 해 주세요.',
    ]
  }
  // A 409 also answers an earlier try of this page that landed though the page did not hear so.
  if (status === conflict && step === 'add') return ['목록에 이미 있는 계정이거나, 이 서버에 이미 들어온 계정이에요.', '이 목록과 「들어온 사람」을 확인해 주세요.']
  if (status === notFound && step === 'remove') return ['서버에서 이 항목을 찾지 못했어요. 목록을 다시 불러와요.']
  return null
}

/** The alert of a request that came to nothing. The caller makes each one
    anew (its key is the count), so a screen reader says the second as it
    said the first. */
export function Outcome({ title, step, outcome }: {
  readonly title: string
  readonly step: 'add' | 'remove'
  readonly outcome: Extract<Add | Remove, { kind: 'refused' | 'unknown' }>
}): VNode {
  const { problem, attempts } = outcome
  const reason = problem.kind === 'refused' ? problem.reason : null
  if (outcome.kind === 'unknown') {
    const after = step === 'add'
      ? ['계정이 목록에 들어갔을 수도 있어요.', '목록에 이 계정이 보이는지 보고, 없으면 다시 넣어 주세요.']
      : ['항목이 빠졌을 수도 있어요.', '이 항목의 상태를 보고, 「기다리는 중」이나 「빼기 마무리 필요」이면 다시 빼 주세요.']
    return html`<${Callout} title=${title} attempts=${attempts} reason=${reason} lines=${[`${unknownWords(problem)} ${after[0]}`, after[1]]} />`
  }
  const words = refusedWords(outcome.problem.status, step)
  if (words === null) return html`<${ProblemNote} title=${title} failure=${{ problem: outcome.problem, attempts }} />`
  return html`<${Callout} title=${title} lines=${words} attempts=${attempts} reason=${reason} />`
}

// ---- the form ----

/** How to find what the field of `provider` takes. */
function FieldHint({ provider }: { readonly provider: Provider }): VNode {
  switch (provider) {
    case 'github':
      return html`<p id=${fieldHintId} class="hint">로그인 이름이 아니라 숫자예요. 로그인 이름을 알면 터미널에서 <span class="mono"><span lang="en">gh api</span> <span class="nowrap"><span lang="en">users/</span>로그인이름</span> <span lang="en" class="nowrap">--jq</span> <span lang="en">.id</span></span>로 볼 수 있어요.</p>`
    case 'google':
      return html`<p id=${fieldHintId} class="hint">Google 로그인이 계정마다 주는 번호(sub)예요. 이메일 주소가 아니에요. 이메일 주소를 넣으면 그 항목으로는 아무도 들어오지 못해요.</p>`
  }
}

/** The form that puts an account on the list. The panel keeps the way of
    signing in picked and what was typed, so a form drawn again (the list
    could not be read again) still shows them. What was typed is sent only
    when it is an account the server takes, and is emptied once the server
    put it on the list, unless the Admin typed something else meanwhile. */
export function AddForm({ model, provider, setProvider, typed, setTyped }: {
  readonly model: AllowlistModel
  readonly provider: Provider
  readonly setProvider: (provider: Provider) => void
  readonly typed: string
  readonly setTyped: Dispatch<StateUpdater<string>>
}): VNode {
  const adding = model.adding.value
  const busy = adding.kind === 'sending' || adding.kind === 'leaving'
  const field = useRef<HTMLInputElement>(null)
  const [mistake, setMistake] = useState<{ readonly why: Extract<Typed, { ok: false }>['why']; readonly attempts: number } | null>(null)
  const onSubmit = async (event: Event): Promise<void> => {
    event.preventDefault()
    if (busy) return
    const read = readTyped(provider, typed)
    if (!read.ok) {
      setMistake({ why: read.why, attempts: (mistake?.attempts ?? 0) + 1 })
      field.current?.focus()
      return
    }
    setMistake(null)
    const sent = typed
    await model.add(read.identity)
    const after = model.adding.peek()
    if (after.kind === 'done' && after.identity === read.identity) setTyped((now) => (now === sent ? '' : now))
  }
  return html`
    <form class="keeper-form" aria-labelledby=${formTitleId} onSubmit=${(event: Event) => { void onSubmit(event) }}>
      <h3 id=${formTitleId} tabindex="-1">계정 넣기</h3>
      <fieldset>
        <legend>로그인 방법</legend>
        <ul class="choices">
          ${providers.map((one) => html`
            <li key=${one}>
              <label class="choice">
                <input type="radio" name="allowlist-provider" value=${one} checked=${one === provider}
                  onChange=${() => { setProvider(one); setMistake(null) }} />
                <span class="choice-title">${providerWords(one)[0]}</span>
              </label>
            </li>
          `)}
        </ul>
      </fieldset>
      <div class="field">
        <label for=${fieldId}>${providerWords(provider)[1]}</label>
        <input ref=${field} id=${fieldId} name="account" value=${typed} autocomplete="off" autocapitalize="off" spellcheck=${false}
          inputmode=${provider === 'github' ? 'numeric' : 'text'} aria-invalid=${mistake !== null} aria-describedby=${mistake === null ? fieldHintId : `${fieldHintId} ${mistakeId}`}
          onInput=${(event: Event) => { setTyped((event.currentTarget as HTMLInputElement).value); setMistake(null) }} />
        <${FieldHint} provider=${provider} />
      </div>
      <p><button type="submit" class="primary" aria-disabled=${busy} aria-describedby=${addTipId}>목록에 넣기</button></p>
      <p id=${addTipId} class="hint">넣은 계정으로 로그인하면 초대 링크 없이 구성원으로 들어와요. 번호를 모르면 초대 링크를 보내는 편이 쉬워요.</p>
    </form>
    ${mistake === null
      ? null
      : html`<div id=${mistakeId}><${Callout} key=${mistake.attempts} attempts=${mistake.attempts} reason=${null}
          title="적은 값을 보내지 않았어요" lines=${[mistakeWords(mistake.why)]} /></div>`}
  `
}

/** The title of a registration that came to nothing. A 409 did not put
    the account on the list because it is there or bound already. */
function addTitle(adding: Extract<Add, { kind: 'refused' | 'unknown' }>): string {
  if (adding.kind === 'unknown') return '계정을 넣었는지 알 수 없어요'
  return adding.problem.status === conflict ? '목록에 넣지 않았어요' : '계정을 넣지 못했어요'
}

/** What came of the latest registration: a line a screen reader reads out
    and the alert of one that came to nothing. It is drawn whatever the list
    shows, so a list that could not be read again does not take the outcome
    off the page. */
export function AddArea({ model }: { readonly model: AllowlistModel }): VNode {
  const adding = model.adding.value
  // The line under the heading says that the session ended, so this one does not say it again.
  const words = model.view.value.kind === 'leaving' ? '' : addWords(adding)
  return html`
    <p class="hint" role="status">${words}</p>
    ${adding.kind === 'refused' || adding.kind === 'unknown'
      ? html`<${Outcome} key=${`${String(adding.attempts)} ${identityWords(adding.identity)}`} step="add" outcome=${adding}
          title=${`${addTitle(adding)}: ${identityWords(adding.identity)}`} />`
      : null}
  `
}
