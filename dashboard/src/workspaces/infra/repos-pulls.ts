/**
 * Infra > Repos: open GitHub pull requests of one repository.
 */

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import type { Observed } from '../../core'
import { DataTable, type DataTableColumn } from '../../components/primitives'
import { KeeperBadge } from '../../components/keeper-badge'
import { formatCount, type Tone } from './repos-model'
import {
  CHECKS_LABEL,
  CHECKS_RANK,
  MERGEABLE_LABEL,
  MERGEABLE_RANK,
  REVIEW_LABEL,
  REVIEW_RANK,
  filterPulls,
  pullFailureSentence,
  pullReaderSentence,
  pullUrl,
  summarizePulls,
  type PullFilter,
  type PullsSnapshot,
  type RepoPull,
  type RepoPullsEntry,
} from './repos-pulls-model'
import { Chip, FailLine, StateWord, WaitLine } from './repos-sections'

/** Up to this many rows the table grows with the page and its header sticks
 *  under the repository head; beyond it the table scrolls inside itself. */
const PULLS_SCROLL_AFTER = 80
const PULLS_SCROLL_HEIGHT = 560

function pullColumns(slug: string | null): readonly DataTableColumn<RepoPull>[] {
  return [
    {
      // An identifier, not a quantity: it starts at the left edge like the
      // title beside it.
      id: 'number',
      header: '번호',
      sortable: true,
      sortValue: (pull) => pull.number,
      cell: (pull) => slug
        ? html`<a class="rp-link rp-nowrap mono" href=${pullUrl(slug, pull.number)} target="_blank" rel="noreferrer">#${pull.number}</a>`
        : html`<span class="rp-nowrap mono">#${pull.number}</span>`,
    },
    {
      id: 'title',
      header: '제목',
      sortable: true,
      sortValue: (pull) => (pull.title ?? '').toLowerCase(),
      // The cell shows two lines at most; the full title is one hover away.
      cell: (pull) => html`
        <span class="rp-pr-title" title=${pull.title ?? undefined}>
          ${pull.draft && html`<span class="rp-draft">Draft</span>`}${pull.title ?? '(제목 없음)'}
        </span>
      `,
    },
    {
      id: 'author',
      header: '작성',
      sortable: true,
      sortValue: (pull) => pull.keeper ?? pull.author ?? '',
      cell: (pull) => pull.keeper
        ? html`<${KeeperBadge} id=${pull.keeper} size="sm" />`
        : html`<span class="rp-plain rp-nowrap">${pull.author ?? '미보고'}</span>`,
    },
    {
      id: 'checks',
      header: 'CI',
      sortable: true,
      sortValue: (pull) => CHECKS_RANK[pull.checks],
      cell: (pull) => html`<${StateWord} fact=${CHECKS_LABEL[pull.checks]} />`,
    },
    {
      id: 'review',
      header: '리뷰',
      sortable: true,
      sortValue: (pull) => REVIEW_RANK[pull.review],
      cell: (pull) => html`
        <${StateWord} fact=${REVIEW_LABEL[pull.review]} />
        ${pull.headReview === 'not_reviewed_on_head' && (pull.review === 'approved' || pull.review === 'changes_requested')
          && html`<div class="rp-fact-sub rp-nowrap">최신 커밋은 리뷰 전</div>`}
      `,
    },
    {
      id: 'mergeable',
      header: '병합',
      sortable: true,
      sortValue: (pull) => MERGEABLE_RANK[pull.mergeable],
      cell: (pull) => html`<${StateWord} fact=${MERGEABLE_LABEL[pull.mergeable]} />`,
    },
  ]
}

/** Counts of pull requests that need a hand. Each chip narrows the table to
 *  its rows and releases on a second press. */
export function PullFilterChips(props: {
  readonly pulls: readonly RepoPull[]
  readonly filter: PullFilter
  readonly onFilter: (next: PullFilter) => void
}) {
  const summary = summarizePulls(props.pulls)
  const chip = (id: Exclude<PullFilter, 'all'>, label: string, n: number, tone: Tone) => n > 0 && html`
    <button
      type="button"
      class="rp-chip rp-chip-btn"
      data-tone=${tone}
      aria-pressed=${props.filter === id}
      onClick=${() => props.onFilter(props.filter === id ? 'all' : id)}
    >
      ${label} ${n}
    </button>
  `
  return html`
    <div class="rp-chips" role="group" aria-label="PR 걸러 보기">
      ${chip('conflicting', '충돌', summary.conflicting, 'bad')}
      ${chip('checksFailing', 'CI 실패', summary.checksFailing, 'bad')}
      ${chip('changesRequested', '변경 요청', summary.changesRequested, 'warn')}
      ${chip('ready', '병합 준비', summary.ready, 'ok')}
      ${props.filter !== 'all' && html`
        <span class="rp-section-note">${formatCount(filterPulls(props.pulls, props.filter).length)}건만 표시</span>
        <button type="button" class="rp-textbtn" onClick=${() => props.onFilter('all')}>전체 보기</button>
      `}
    </div>
  `
}

/** Read-only counts for the repository table, where a chip is not a control.
 *  `unreadable` pull requests are open but missing from the count beside them. */
export function PullAttention(props: { readonly pulls: readonly RepoPull[]; readonly unreadable: number }) {
  const summary = summarizePulls(props.pulls)
  return html`
    <span class="rp-chips">
      <span class="rp-count">${summary.total}</span>
      ${props.unreadable > 0 && html`<${Chip} tone="warn">읽지 못함 ${formatCount(props.unreadable)}<//>`}
      ${summary.conflicting > 0 && html`<${Chip} tone="bad">충돌 ${summary.conflicting}<//>`}
      ${summary.checksFailing > 0 && html`<${Chip} tone="bad">CI 실패 ${summary.checksFailing}<//>`}
      ${summary.changesRequested > 0 && html`<${Chip} tone="warn">변경 요청 ${summary.changesRequested}<//>`}
      ${summary.ready > 0 && html`<${Chip} tone="ok">병합 준비 ${summary.ready}<//>`}
    </span>
  `
}

export function PullsSection(props: {
  readonly snapshot: Observed<PullsSnapshot>
  readonly entry: RepoPullsEntry | undefined
  readonly filter: PullFilter
  readonly onRetry: () => void
}) {
  const { snapshot, entry } = props
  const columns = useMemo(() => pullColumns(entry?.slug ?? null), [entry?.slug])
  if (snapshot.kind === 'loading') return html`<${WaitLine} what="GitHub PR" />`
  if (snapshot.kind === 'failed') {
    return html`<${FailLine} what="GitHub PR" message=${snapshot.error.message} onRetry=${props.onRetry} />`
  }
  if (snapshot.kind !== 'value') {
    return html`<div class="rp-empty">서버가 GitHub PR을 보내지 않았습니다.</div>`
  }
  if (snapshot.data.repositoriesError !== null) {
    return html`
      <div class="rp-notice" data-tone="bad" role="alert">
        저장소 목록을 읽지 못해 PR을 가져오지 못했습니다: ${snapshot.data.repositoriesError}
      </div>
    `
  }
  if (!entry || entry.pulls.kind === 'not_read') {
    return html`
      <div class="rp-empty">${pullReaderSentence(snapshot.data.reader) ?? '아직 이 저장소의 PR을 읽지 않았습니다.'}</div>
    `
  }
  if (entry.pulls.kind === 'not_github') {
    return html`<div class="rp-empty">GitHub 저장소가 아니어서 PR을 읽지 않습니다.</div>`
  }
  if (entry.pulls.kind === 'failed') {
    return html`<div class="rp-notice" data-tone="bad" role="alert">${pullFailureSentence(entry.pulls.failure)}</div>`
  }
  const { pulls, unreadable } = entry.pulls
  const shown = filterPulls(pulls, props.filter)
  const scrolls = shown.length > PULLS_SCROLL_AFTER
  const { keepers } = snapshot.data
  return html`
    ${unreadable > 0 && html`
      <div class="rp-notice" data-tone="warn">PR ${formatCount(unreadable)}건은 응답을 읽지 못해 표에 없습니다.</div>
    `}
    ${pulls.length === 0
      ? html`<div class="rp-empty">열린 PR이 없습니다.</div>`
      : html`
          <${DataTable}
            data=${shown}
            columns=${columns}
            getRowId=${(pull: RepoPull) => String(pull.number)}
            initialSort=${{ id: 'number', desc: true }}
            maxHeight=${scrolls ? PULLS_SCROLL_HEIGHT : undefined}
            caption="열린 GitHub PR"
            className=${scrolls ? 'rp-pulls' : 'rp-pulls rp-pulls-flow'}
          />
        `}
    ${keepers.kind === 'list_failed' && pulls.length > 0 && html`
      <p class="rp-section-note">
        Keeper 목록을 읽지 못해 작성자를 GitHub 계정 이름으로만 보여 줍니다: ${keepers.reason}
      </p>
    `}
  `
}
