/**
 * Infra > Repos: shared small pieces and the clone summary.
 *
 * Each piece owns its own waiting and failure state, so a slow git call does
 * not hide the pull requests and a failed GitHub read does not hide the clone.
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import type { Observed } from '../../core'
import { SECONDS_PER_MINUTE, formatTimestampKo } from '../../lib/format-time'
import { nowSecondsSignal, useNowSecondsTicker } from '../../lib/now-signal'
import {
  countChanges,
  groupByDirectory,
  groupChangesByKind,
  headFact,
  upstreamFact,
  upstreamRef,
  workingTreeBreakdown,
  workingTreeFact,
  type RepoGitState,
} from './repos-git-model'
import { formatCount, formatSpan, type Fact, type Tone } from './repos-model'
import type { RepoActivityData } from './types'

const WAIT_SHOW_SECONDS_AFTER = 3
/** A directory with more files than this opens closed, as one counted line. */
const DIR_OPEN_MAX = 6

export function Chip(props: { readonly tone?: Tone; readonly children: ComponentChildren }) {
  return html`<span class="rp-chip" data-tone=${props.tone ?? 'neutral'}>${props.children}</span>`
}

/** A chip only for a state someone has to act on. A good state is coloured
 *  text; the expected and the still-moving ones are plain text. */
export function StateWord(props: { readonly fact: Fact }) {
  const { text, tone } = props.fact
  if (tone === 'warn' || tone === 'bad') return html`<${Chip} tone=${tone}>${text}<//>`
  if (tone === 'ok') return html`<span class="rp-plain rp-toned" data-tone="ok">${text}</span>`
  return html`<span class="rp-plain">${text}</span>`
}

/** The wall clock in seconds. The shared tick re-renders only the component
 *  that calls this. The time is read fresh because the tick signal keeps its
 *  last value while no component is mounted. */
export function useNowSec(): number {
  useNowSecondsTicker()
  void nowSecondsSignal.value
  return Date.now() / 1000
}

/** "방금 조회", "3분 전 조회", or a bare "3분 전": when something happened.
 *  Hover shows the clock time. */
export function Ago(props: { readonly atSec: number; readonly what?: string }) {
  const age = useNowSec() - props.atSec
  const tail = props.what ? ` ${props.what}` : ''
  const text = age < SECONDS_PER_MINUTE ? `방금${tail}` : `${formatSpan(age)} 전${tail}`
  return html`<span class="rp-section-note rp-nowrap" title=${formatTimestampKo(props.atSec)}>${text}</span>`
}

/** Seconds since this element appeared, shown once the wait is noticeable. */
function useElapsedSeconds(): number {
  const [seconds, setSeconds] = useState(0)
  useEffect(() => {
    const startedAt = Date.now()
    const timer = setInterval(() => setSeconds(Math.floor((Date.now() - startedAt) / 1000)), 1000)
    return () => clearInterval(timer)
  }, [])
  return seconds
}

export function WaitText(props: { readonly what: string }) {
  const seconds = useElapsedSeconds()
  return html`${props.what}${seconds >= WAIT_SHOW_SECONDS_AFTER ? ` ${seconds}초째` : ''}`
}

export function WaitLine(props: { readonly what: string }) {
  return html`<div class="rp-empty" role="status"><${WaitText} what=${`${props.what} 불러오는 중…`} /></div>`
}

export function FailLine(props: { readonly what: string; readonly message: string; readonly onRetry: () => void }) {
  return html`
    <div class="rp-notice" data-tone="bad" role="alert">
      <span>${props.what} 조회 실패: ${props.message}</span>
      <button type="button" class="btn-ghost" onClick=${props.onRetry}>다시 시도</button>
    </div>
  `
}

// ── Summary row: branch, distance from remote, uncommitted files, Keeper writes ──

function SummaryCell(props: {
  readonly label: string
  readonly value: ComponentChildren
  readonly tone?: Tone
  readonly sub?: ComponentChildren
}) {
  return html`
    <div class="rp-fact">
      <dt>${props.label}</dt>
      <dd>
        <span class="rp-fact-v rp-toned" data-tone=${props.tone ?? 'neutral'}>${props.value}</span>
        <span class="rp-fact-sub">${props.sub}</span>
      </dd>
    </div>
  `
}

const GIT_LABELS = ['브랜치', '원격과 차이', '커밋 안 된 변경'] as const

/** Three cells share one git call, so they wait and fail together. */
function gitCells(git: Observed<RepoGitState>, onRetry: () => void, filesToggle: ComponentChildren) {
  if (git.kind === 'value') {
    const counts = countChanges(git.data.changes)
    const head = headFact(git.data.head)
    const upstream = upstreamFact(git.data.upstream)
    const tree = workingTreeFact(counts)
    const breakdown = workingTreeBreakdown(counts)
    const ref = upstreamRef(git.data.upstream)
    return html`
      <${SummaryCell} label=${GIT_LABELS[0]} value=${html`<span class="mono">${head.text}</span>`} tone=${head.tone} />
      <${SummaryCell}
        label=${GIT_LABELS[1]}
        value=${upstream.text}
        tone=${upstream.tone}
        sub=${ref && html`<span class="mono">${ref}</span>`}
      />
      <${SummaryCell}
        label=${GIT_LABELS[2]}
        value=${tree.text}
        tone=${tree.tone}
        sub=${breakdown && html`<span>${breakdown}</span>${filesToggle}`}
      />
    `
  }
  if (git.kind === 'failed') {
    return html`
      <${SummaryCell}
        label=${GIT_LABELS[0]}
        value="조회 실패"
        tone="bad"
        sub=${html`<span>${git.error.message}</span><button type="button" class="rp-textbtn" onClick=${onRetry}>다시 시도</button>`}
      />
      <${SummaryCell} label=${GIT_LABELS[1]} value="–" />
      <${SummaryCell} label=${GIT_LABELS[2]} value="–" />
    `
  }
  if (git.kind === 'absent') {
    // 404: nothing is checked out at the repository's path, e.g. a first clone still running.
    return html`
      <${SummaryCell} label=${GIT_LABELS[0]} value="로컬 클론 없음" sub=${git.reason && html`<span>${git.reason}</span>`} />
      <${SummaryCell} label=${GIT_LABELS[1]} value="–" />
      <${SummaryCell} label=${GIT_LABELS[2]} value="–" />
    `
  }
  const waiting = git.kind === 'loading'
  return GIT_LABELS.map((label, index) => html`
    <${SummaryCell}
      key=${label}
      label=${label}
      value=${waiting ? (index === 0 ? html`<${WaitText} what="확인 중…" />` : '…') : '미보고'}
    />
  `)
}

function keeperCell(activity: Observed<RepoActivityData>, fileCount: number, onRetry: () => void) {
  const label = 'Keeper가 쓴 파일 · 24시간'
  if (activity.kind === 'value') {
    const { changes, unattributed } = activity.data
    // Zero here can mean "none" or "written, but the record does not say where".
    const sub = changes.length > 0
      ? `쓰기 ${formatCount(changes.length)}회`
      : unattributed > 0 ? `어느 저장소인지 모르는 기록 ${formatCount(unattributed)}건` : undefined
    return html`<${SummaryCell} label=${label} value=${`${formatCount(fileCount)}개`} sub=${sub} />`
  }
  if (activity.kind === 'failed') {
    return html`
      <${SummaryCell}
        label=${label}
        value="조회 실패"
        tone="bad"
        sub=${html`<button type="button" class="rp-textbtn" onClick=${onRetry}>다시 시도</button>`}
      />
    `
  }
  return html`
    <${SummaryCell}
      label=${label}
      value=${activity.kind === 'loading' ? html`<${WaitText} what="확인 중…" />` : '미보고'}
    />
  `
}

/** A value on screen while its replacement is being read. */
function rereading(observed: Observed<unknown>): boolean {
  return observed.kind === 'value' && observed.stale
}

export function SummaryRow(props: {
  readonly git: Observed<RepoGitState>
  readonly activity: Observed<RepoActivityData>
  /** Distinct files among the activity's writes. */
  readonly fileCount: number
  readonly onRetryGit: () => void
  readonly onRetryActivity: () => void
}) {
  const [showFiles, setShowFiles] = useState(false)
  const changes = props.git.kind === 'value' ? props.git.data.changes : []
  const filesToggle = changes.length > 0 && html`
    <button
      type="button"
      class="rp-textbtn"
      aria-expanded=${showFiles}
      onClick=${() => setShowFiles((value) => !value)}
    >
      ${showFiles ? '목록 접기' : '목록 보기'}
    </button>
  `
  return html`
    <dl
      class="rp-facts"
      aria-busy=${props.git.kind === 'loading' || rereading(props.git) || rereading(props.activity)}
      data-rereading=${rereading(props.git) || rereading(props.activity)}
    >
      ${gitCells(props.git, props.onRetryGit, filesToggle)}
      ${keeperCell(props.activity, props.fileCount, props.onRetryActivity)}
    </dl>
    ${showFiles && changes.length > 0 && html`
      <div class="rp-files" aria-label="커밋 안 된 파일">
        ${groupChangesByKind(changes).map((group) => html`
          <section key=${group.kind} class="rp-files-group">
            <h4>${group.kind} ${formatCount(group.paths.length)}</h4>
            ${groupByDirectory(group.paths).map((folder) => html`
              <details key=${folder.dir} class="rp-dir" open=${folder.names.length <= DIR_OPEN_MAX}>
                <summary><span class="mono">${folder.dir}</span> <span class="rp-count">${formatCount(folder.names.length)}</span></summary>
                <ul>
                  ${folder.names.map((name) => html`<li key=${name}>${name}</li>`)}
                </ul>
              </details>
            `)}
          </section>
        `)}
      </div>
    `}
  `
}
