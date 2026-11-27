/**
 * Infra > Repos: files Keepers wrote in the last 24 hours.
 *
 * One line per file, newest write first. A line opens to that file's writes,
 * so a file rewritten thirty times is one row with a count, and a diff is
 * built only for a write someone opened.
 */

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { Observed } from '../../core'
import { classifyUnifiedDiffLine } from '../../components/common/unified-diff'
import { KeeperBadge } from '../../components/keeper-badge'
import { formatTimestampKo } from '../../lib/format-time'
import { formatCount, splitDir, type FileWrites } from './repos-model'
import { Ago, Chip, FailLine, WaitLine } from './repos-sections'
import type { RepoActivityChange, RepoActivityData } from './types'

const FILES_STEP = 20
const WRITES_STEP = 3
const DIFF_PREVIEW_LINES = 18
/** Writers named on a file's line; the rest fold into "+N". */
const KEEPERS_SHOWN = 2

export type KeeperFile = FileWrites<RepoActivityChange>

/** `fromFirstHunk` drops the file header lines; the row already names the file. */
export function DiffLines(props: { readonly patch: string; readonly maxLines: number; readonly fromFirstHunk?: boolean }) {
  const whole = props.patch.split('\n')
  const firstHunk = props.fromFirstHunk ? whole.findIndex((line) => line.startsWith('@@')) : -1
  const all = firstHunk > 0 ? whole.slice(firstHunk) : whole
  const lines = all.length > props.maxLines ? all.slice(0, props.maxLines) : all
  const cut = all.length - lines.length
  return html`
    <pre class="rp-diff">${lines.map((line, index) =>
      html`<span key=${index} data-line=${classifyUnifiedDiffLine(line)}>${line}</span>`,
    )}${cut > 0 && html`<span data-line="cut">… ${formatCount(cut)}줄 더 있음</span>`}</pre>
  `
}

function FileRow(props: {
  readonly file: KeeperFile
  readonly patchOf: (write: RepoActivityChange) => string
  readonly onInspect: (write: RepoActivityChange) => void
}) {
  const { file } = props
  const [open, setOpen] = useState(false)
  const [shown, setShown] = useState(WRITES_STEP)
  const { dir, name } = splitDir(file.path)
  const visible = file.writes.slice(0, shown)
  const rest = file.writes.length - visible.length
  const moreKeepers = file.keepers.length - KEEPERS_SHOWN
  return html`
    <li class="rp-file">
      <div class="rp-file-h">
        <button
          type="button"
          class="rp-file-toggle"
          aria-expanded=${open}
          title=${file.path}
          onClick=${() => setOpen((value) => !value)}
        >
          <span class="rp-file-caret" aria-hidden="true">${open ? '▾' : '▸'}</span>
          ${dir !== null && html`<span class="rp-file-dir">${dir}</span>`}
          <span class="rp-file-name">${name}</span>
        </button>
        <span class="rp-file-meta">
          ${file.failed > 0 && html`<${Chip} tone="bad">실패 ${formatCount(file.failed)}<//>`}
          ${file.keepers.slice(0, KEEPERS_SHOWN).map((keeper) => html`<${KeeperBadge} key=${keeper} id=${keeper} size="sm" />`)}
          ${moreKeepers > 0 && html`<span class="rp-section-note" title=${file.keepers.slice(KEEPERS_SHOWN).join(', ')}>+${moreKeepers}</span>`}
          <span class="rp-file-count">쓰기 ${formatCount(file.writes.length)}회</span>
          <span class="rp-file-when"><${Ago} atSec=${file.lastAt} /></span>
        </span>
      </div>
      ${open && html`
        <ol class="rp-writes">
          ${visible.map((write, index) => html`
            <li key=${`${write.at}-${index}`} class="rp-write">
              <div class="rp-write-h">
                <span class="rp-section-note rp-nowrap">${formatTimestampKo(write.at)}</span>
                <${KeeperBadge} id=${write.keeper} size="sm" />
                ${write.task_id !== null && html`<span class="rp-section-note mono">${write.task_id}</span>`}
                ${!write.succeeded && html`<${Chip} tone="bad">실패<//>`}
                <button type="button" class="rp-textbtn" onClick=${() => props.onInspect(write)}>전체 Diff</button>
              </div>
              <${DiffLines} patch=${props.patchOf(write)} maxLines=${DIFF_PREVIEW_LINES} fromFirstHunk />
            </li>
          `)}
          ${rest > 0 && html`
            <li>
              <button type="button" class="rp-textbtn" onClick=${() => setShown((value) => value + WRITES_STEP)}>
                ${formatCount(file.writes.length)}회 중 ${formatCount(visible.length)}회 표시 · ${formatCount(Math.min(WRITES_STEP, rest))}회 더 보기
              </button>
            </li>
          `}
        </ol>
      `}
    </li>
  `
}

export function KeeperFilesSection(props: {
  readonly activity: Observed<RepoActivityData>
  /** The activity's writes grouped by file; empty until the activity is read. */
  readonly files: readonly KeeperFile[]
  readonly patchOf: (write: RepoActivityChange) => string
  readonly onInspect: (write: RepoActivityChange) => void
  readonly onRetry: () => void
}) {
  const [shown, setShown] = useState(FILES_STEP)
  const { activity, files } = props
  if (activity.kind === 'loading') return html`<${WaitLine} what="Keeper가 쓴 파일" />`
  if (activity.kind === 'failed') {
    return html`<${FailLine} what="Keeper가 쓴 파일" message=${activity.error.message} onRetry=${props.onRetry} />`
  }
  if (activity.kind !== 'value') {
    return html`<div class="rp-empty">서버가 Keeper 파일 기록을 보내지 않았습니다.</div>`
  }
  const { incomplete, unattributed } = activity.data
  const visible = files.slice(0, shown)
  const rest = files.length - visible.length
  return html`
    ${files.length === 0
      ? html`<div class="rp-empty">최근 24시간 동안 Keeper가 이 저장소에 쓴 파일이 없습니다.</div>`
      : html`
          <ul class="rp-filelist">
            ${visible.map((file) => html`
              <${FileRow} key=${file.path} file=${file} patchOf=${props.patchOf} onInspect=${props.onInspect} />
            `)}
          </ul>
        `}
    ${rest > 0 && html`
      <button type="button" class="btn-ghost rp-more" onClick=${() => setShown((value) => value + FILES_STEP)}>
        ${formatCount(files.length)}개 중 ${formatCount(visible.length)}개 표시 · ${formatCount(Math.min(FILES_STEP, rest))}개 더 보기
      </button>
    `}
    ${incomplete > 0 && html`
      <p class="rp-section-note">이 저장소의 변경 ${formatCount(incomplete)}건은 기록이 잘려 내용을 보여 줄 수 없습니다.</p>
    `}
    ${unattributed > 0 && html`
      <p class="rp-section-note">전체 Keeper 기록 ${formatCount(unattributed)}건은 파일 위치가 남지 않아 어느 저장소 것인지 알 수 없습니다.</p>
    `}
  `
}
