/**
 * Infra > Repos: one repository. Its local clone (branch, distance from the
 * remote, uncommitted files), its open GitHub pull requests, and the files
 * Keepers wrote in the last 24 hours.
 *
 * Mounted with the repository id as its key, so the pull request filter and
 * every opened row start over when another repository is selected.
 */

import { html } from 'htm/preact'
import { createTwoFilesPatch } from 'diff'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { KeeperBadge } from '../../components/keeper-badge'
import { resourceCache, type Observed } from '../../core'
import { formatTimestampKo } from '../../lib/format-time'
import { RepoStateWord, StalledNotice } from './repos-list'
import type { RepoGitState } from './repos-git-model'
import { formatCount, groupWritesByFile, splitDir, type Fact } from './repos-model'
import { PullFilterChips, PullsSection } from './repos-pulls'
import type { PullFilter, PullsSnapshot } from './repos-pulls-model'
import { activityKey, gitKey, loadActivity, loadGit, loadPulls, useRefetchWhenStale } from './repos-reads'
import { Ago, Chip, SummaryRow } from './repos-sections'
import { DiffLines, KeeperFilesSection } from './repos-writes'
import {
  extractChangeBeforeAfter,
  extractChangePath,
  type InfraRepository,
  type RepoActivityChange,
  type RepoActivityData,
  type WorkspaceViewProps,
} from './types'

const INSPECT_DIFF_MAX_LINES = 500
const HEAD_HEIGHT_VAR = '--rp-head-h'
/** The Sync button's label while a sync is in flight. The button is laid out
 *  as wide as this label from the start (`infra.css`), so it holds its width. */
const SYNCING_LABEL = '가져오는 중…'

/** A manual sync that left the working tree alone, or failed: what the server
 *  said, and when. One that did what was asked leaves none. */
export interface UnfinishedSync {
  readonly fact: Fact
  readonly atSec: number
}

function buildUnifiedChangeDiff(change: RepoActivityChange): string {
  const filePath = extractChangePath(change.location)
  const { before, after, unified } = extractChangeBeforeAfter(change.change)
  if (unified) return unified
  return createTwoFilesPatch(`a/${filePath}`, `b/${filePath}`, before, after, 'before', 'after', { context: 3 })
}

/** The pull request table header sticks just below the repository head, so the
 *  card carries that head's height, which changes when the head wraps. The
 *  height is rounded down: a header half a pixel lower leaves a seam that the
 *  rows scrolling under it show through. */
function useHeadHeight() {
  const card = useRef<HTMLElement>(null)
  const head = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const cardEl = card.current
    const headEl = head.current
    if (cardEl === null || headEl === null || typeof ResizeObserver === 'undefined') return undefined
    const apply = () => {
      cardEl.style.setProperty(HEAD_HEIGHT_VAR, `${Math.floor(headEl.getBoundingClientRect().height)}px`)
    }
    apply()
    const observer = new ResizeObserver(apply)
    observer.observe(headEl)
    return () => observer.disconnect()
  }, [])
  return { card, head }
}

/** Where the clone is on the server. The slash before the last directory
 *  name stays with the name, so a path cut in the middle still reads as one.
 *  The dot that parts the path from the address belongs to the path: on a line
 *  with no room for the path, the dot goes with it. */
function ClonePath(props: { readonly path: string; readonly afterAddress: boolean }) {
  const { dir, name } = splitDir(props.path)
  return html`
    <span class="rp-path" title=${`서버의 로컬 클론 경로: ${props.path}`}>
      ${props.afterAddress && html`<span class="rp-path-sep" aria-hidden="true">·</span>`}
      ${dir !== null && html`<span class="rp-path-dir">${dir.slice(0, -1)}</span>`}
      <span class="rp-path-name">${dir !== null ? `/${name}` : name}</span>
    </span>
  `
}

export function RepoDetail(props: {
  readonly repo: InfraRepository
  readonly pulls: Observed<PullsSnapshot>
  /** Whether this session may sync the repository and read the Keeper write
   *  record. Without it the record is not requested. */
  readonly canAdmin: boolean
  readonly syncing: boolean
  readonly unfinishedSync: UnfinishedSync | undefined
  readonly onSync: () => void
  readonly onInspect: WorkspaceViewProps['onInspect']
}) {
  const { repo, pulls: pullsObs, unfinishedSync } = props
  const gitObs = resourceCache.observe<RepoGitState>(gitKey(repo.id)).value
  const activityObs = resourceCache.observe<RepoActivityData>(activityKey(repo.id)).value
  const [pullFilter, setPullFilter] = useState<PullFilter>('all')
  const { card, head } = useHeadHeight()

  // `loadActivity` sends nothing for a session that may not read the record.
  useEffect(() => {
    void loadGit(repo.id, 'mount')
    void loadActivity(repo.id, 'mount')
  }, [props.canAdmin])

  // A sync or a finished clone rewrites the row; what was read about the clone
  // before that is out of date, including a "no clone yet" answer.
  const rowStamp = `${repo.status.kind}:${repo.updated_at}`
  const readAtStamp = useRef(rowStamp)
  useEffect(() => {
    if (readAtStamp.current === rowStamp) return
    readAtStamp.current = rowStamp
    void loadGit(repo.id, 'manual')
    void loadActivity(repo.id, 'manual')
    void loadPulls('manual')
  }, [rowStamp])

  useRefetchWhenStale(gitObs, () => void loadGit(repo.id, 'mount'))
  useRefetchWhenStale(activityObs, () => void loadActivity(repo.id, 'mount'))

  const files = useMemo(
    () => (activityObs.kind === 'value'
      ? groupWritesByFile(activityObs.data.changes, (write) => extractChangePath(write.location))
      : []),
    [activityObs],
  )

  const handleInspectDiff = (change: RepoActivityChange) => {
    const patch = buildUnifiedChangeDiff(change)
    props.onInspect({
      title: extractChangePath(change.location),
      subtitle: `${change.keeper} · ${formatTimestampKo(change.at)}${change.task_id ? ` · ${change.task_id}` : ''}`,
      kind: 'repo_diff',
      data: change,
      render: () => html`
        <div class="rp-section">
          <div class="rp-chips">
            <${KeeperBadge} id=${change.keeper} size="sm" />
            <${Chip} tone=${change.succeeded ? 'ok' : 'bad'}>${change.succeeded ? '적용 성공' : '실패'}<//>
            ${change.turn !== null && html`<span class="rp-section-note">turn #${change.turn}</span>`}
          </div>
          <${DiffLines} patch=${patch} maxLines=${INSPECT_DIFF_MAX_LINES} />
        </div>
      `,
    })
  }

  const entry = pullsObs.kind === 'value' ? pullsObs.data.byRepo.get(repo.id) : undefined
  const openPulls = entry?.pulls.kind === 'read' ? entry.pulls.pulls : []
  const pullsObservedAt = entry && (entry.pulls.kind === 'read' || entry.pulls.kind === 'failed')
    ? entry.pulls.observedAt
    : null
  const writeCount = activityObs.kind === 'value' ? activityObs.data.changes.length : 0

  return html`
    <section class="rp-detail" ref=${card} aria-label=${`${repo.name} 상세`}>
      <div class="rp-head" ref=${head}>
        <div class="rp-head-main">
          <div class="rp-head-title">
            <h2>${repo.name}</h2>
            ${repo.status.kind !== 'active' && html`<${RepoStateWord} repo=${repo} />`}
          </div>
          <div class="rp-head-sub">
            ${entry?.slug && html`
              <a class="rp-link" href=${`https://github.com/${entry.slug}`} target="_blank" rel="noreferrer">${entry.slug}</a>
            `}
            ${repo.local_path !== null && html`<${ClonePath} path=${repo.local_path} afterAddress=${Boolean(entry?.slug)} />`}
          </div>
        </div>
        ${props.canAdmin && html`
          <button type="button" class="btn-primary" data-wide-label=${SYNCING_LABEL} disabled=${props.syncing} onClick=${props.onSync}>
            <span>${props.syncing ? SYNCING_LABEL : '동기화'}</span>
          </button>
        `}
      </div>

      <div class="rp-body">
        ${repo.status.kind === 'error' && html`
          <div class="rp-notice" data-tone="bad" role="alert">
            ${repo.status.message !== null
              ? `마지막 동기화 실패: ${repo.status.message}`
              : '마지막 동기화가 실패했습니다. 서버가 이유를 남기지 않았습니다.'}
          </div>
        `}
        <${StalledNotice} repo=${repo} canSync=${props.canAdmin} />
        ${unfinishedSync && html`
          <div class="rp-notice" data-tone=${unfinishedSync.fact.tone}>
            <span role=${unfinishedSync.fact.tone === 'bad' ? 'alert' : 'status'}>${unfinishedSync.fact.text}</span>
            <${Ago} atSec=${unfinishedSync.atSec} what="동기화" />
          </div>
        `}

        <${SummaryRow}
          git=${gitObs}
          activity=${props.canAdmin ? activityObs : null}
          fileCount=${files.length}
          onRetryGit=${() => void loadGit(repo.id, 'manual')}
          onRetryActivity=${() => void loadActivity(repo.id, 'manual')}
        />

        <section class="rp-section" aria-label="열린 GitHub PR">
          <div class="rp-section-h">
            <div class="rp-section-title">
              <h3>열린 PR${entry?.pulls.kind === 'read' ? ` ${formatCount(openPulls.length)}` : ''}</h3>
              <${PullFilterChips} pulls=${openPulls} filter=${pullFilter} onFilter=${setPullFilter} />
            </div>
            ${pullsObservedAt !== null && html`<${Ago} atSec=${pullsObservedAt} what="GitHub 확인" />`}
          </div>
          <${PullsSection}
            snapshot=${pullsObs}
            entry=${entry}
            filter=${pullFilter}
            onRetry=${() => void loadPulls('manual')}
          />
        </section>

        <section class="rp-section" aria-label="Keeper가 쓴 파일">
          <div class="rp-section-h">
            <h3>최근 24시간 Keeper가 쓴 파일${props.canAdmin && activityObs.kind === 'value' ? ` ${formatCount(files.length)}` : ''}</h3>
            ${props.canAdmin && files.length > 0 && html`
              <span class="rp-section-note">쓰기 ${formatCount(writeCount)}회 · 최근에 쓴 순</span>
            `}
          </div>
          ${props.canAdmin
            ? html`
                <${KeeperFilesSection}
                  activity=${activityObs}
                  files=${files}
                  patchOf=${buildUnifiedChangeDiff}
                  onInspect=${handleInspectDiff}
                  onRetry=${() => void loadActivity(repo.id, 'manual')}
                />
              `
            : html`
                <div class="rp-empty" data-testid="infra-repo-activity-admin-locked" role="status">
                  Keeper가 쓴 파일 기록과 저장소 등록·동기화는 관리자 전용입니다.
                </div>
              `}
        </section>
      </div>
    </section>
  `
}
