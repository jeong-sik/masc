import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { fetchGitGraph, type GitGraphResponse } from '../../api/git-graph'
import { globalPresenceSnapshot, type KeeperPresenceStatus } from './keeper-presence-store'
import { cursorOverlaySignal } from './keeper-cursor-overlay'

type BranchTone = 'current' | 'dirty' | 'conflict' | 'stale'
type PanelState = 'loading' | 'ready' | 'empty' | 'error'

export interface IdeBranchChip {
  readonly id: string
  readonly label: string
  readonly tone: BranchTone
  readonly detail: string
}

export interface IdeWorktreeLane {
  readonly id: string
  readonly label: string
  readonly branch: string
  readonly path: string
  readonly color: string
  /** Keeper identity owning this worktree, when known.
      Used to match against presence/cursor stores (which are keyed by
      keeper_id, not the worktree path that drives [id]). When undefined,
      presence/cursor rendering for this lane degrades silently — the
      upstream snapshot producer (lib/git_graph_snapshot.ml) is
      responsible for populating this when it can. */
  readonly keeperId?: string
}

export interface IdeBranchContextModel {
  readonly repoLabel: string
  readonly repoRoot: string
  readonly currentBranch: string
  readonly head: string
  readonly status: 'clean' | 'dirty' | 'conflict'
  readonly stats: {
    readonly branchCount: number
    readonly commitCount: number
    readonly worktreeCount: number
    readonly dirtyCount: number
    readonly conflictCount: number
  }
  readonly branches: ReadonlyArray<IdeBranchChip>
  readonly lanes: ReadonlyArray<IdeWorktreeLane>
  readonly warnings: ReadonlyArray<string>
}

interface IdeBranchContextPanelProps {
  readonly activeRepositoryId?: () => string | null
  readonly subscribeActiveRepositoryId?: (listener: () => void) => () => void
  readonly fetchGraph?: typeof fetchGitGraph
  readonly refreshMs?: number | null
}

const DEFAULT_REFRESH_MS = 15000

function shortSha(raw: string | null): string {
  if (!raw) return 'unknown'
  return raw.length > 10 ? raw.slice(0, 10) : raw
}

function compactPath(path: string): string {
  const normalized = path.replace(/\\/g, '/')
  const parts = normalized.split('/').filter(Boolean)
  if (parts.length <= 2) return normalized || 'workspace'
  return `${parts[parts.length - 2]}/${parts[parts.length - 1]}`
}

function toneForBranch(node: GitGraphResponse['nodes'][number], currentBranch: string): BranchTone {
  if (node.conflict || node.status === 'conflict') return 'conflict'
  if (node.status === 'dirty') return 'dirty'
  if (node.branch && node.branch === currentBranch) return 'current'
  if (node.status === 'current') return 'current'
  return 'stale'
}

function branchSortKey(branch: IdeBranchChip): string {
  const toneRank: Record<BranchTone, string> = {
    current: '0',
    conflict: '1',
    dirty: '2',
    stale: '3',
  }
  return `${toneRank[branch.tone]}:${branch.label}`
}

export function buildIdeBranchContextModel(
  graph: GitGraphResponse,
  preferredRepoId?: string | null,
): IdeBranchContextModel | null {
  const repo =
    graph.repos.find(candidate => preferredRepoId && candidate.id === preferredRepoId)
    ?? graph.repos[0]

  if (!repo) return null

  const currentBranch = repo.current_branch ?? 'detached'
  const repoNodes = graph.nodes.filter(node => node.repo_id === repo.id)
  const branches = repoNodes
    .filter(node => node.kind === 'branch')
    .map(node => {
      const label = node.branch ?? node.label
      return {
        id: node.id,
        label,
        tone: toneForBranch(node, currentBranch),
        detail: node.detail ?? node.sha ?? node.status,
      }
    })
    .sort((a, b) => branchSortKey(a).localeCompare(branchSortKey(b)))
    .slice(0, 5)

  const repoAgentIds = new Set(repoNodes.map(node => node.agent_id).filter((id): id is string => Boolean(id)))
  const lanes = graph.agents
    .filter(agent => repoAgentIds.size === 0 || repoAgentIds.has(agent.id))
    .map(agent => ({
      id: agent.id,
      label: agent.label,
      branch: agent.branch ?? 'detached',
      path: compactPath(agent.worktree_path),
      color: agent.color,
    }))
    .slice(0, 4)

  const status =
    repo.conflict_count > 0 ? 'conflict'
      : repo.dirty ? 'dirty'
        : 'clean'

  return {
    repoLabel: repo.label,
    repoRoot: repo.root,
    currentBranch,
    head: shortSha(repo.head),
    status,
    stats: {
      branchCount: repo.branch_count,
      commitCount: repo.commit_count,
      worktreeCount: repo.worktree_count,
      dirtyCount: graph.stats.dirty_count,
      conflictCount: repo.conflict_count,
    },
    branches,
    lanes,
    warnings: graph.warnings,
  }
}

function stateLabel(state: PanelState, model: IdeBranchContextModel | null): string {
  if (state === 'loading') return 'syncing'
  if (state === 'error') return 'unavailable'
  if (!model) return 'empty'
  if (model.status === 'conflict') return 'conflict'
  if (model.status === 'dirty') return 'dirty'
  return 'clean'
}

function MiniBranchGraph({ model }: { readonly model: IdeBranchContextModel }) {
  const branches = model.branches.length > 0
    ? model.branches
    : [{ id: 'current', label: model.currentBranch, tone: model.status === 'conflict' ? 'conflict' : model.status === 'dirty' ? 'dirty' : 'current', detail: model.head }]

  return html`
    <svg
      class="ide-branch-mini-graph"
      viewBox="0 0 320 86"
      role="img"
      aria-label=${`Branch graph for ${model.repoLabel}`}
    >
      <line x1="24" y1="43" x2="296" y2="43" class="ide-branch-mini-line" />
      ${branches.slice(0, 5).map((branch, index) => {
        const x = 34 + index * 62
        const y = index % 2 === 0 ? 34 : 52
        return html`
          <g key=${branch.id}>
            <line x1=${x} y1="43" x2=${x} y2=${y} class="ide-branch-mini-link" />
            <circle cx=${x} cy=${y} r="6" class=${`ide-branch-node is-${branch.tone}`} />
            <text x=${x} y=${index % 2 === 0 ? 20 : 74} text-anchor="middle" class="ide-branch-mini-label">
              ${branch.label.length > 10 ? `${branch.label.slice(0, 9)}...` : branch.label}
            </text>
          </g>
        `
      })}
    </svg>
  `
}

export function IdeBranchContextPanel({
  activeRepositoryId = () => null,
  subscribeActiveRepositoryId,
  fetchGraph = fetchGitGraph,
  refreshMs = DEFAULT_REFRESH_MS,
}: IdeBranchContextPanelProps) {
  const [repoId, setRepoId] = useState<string | null>(() => activeRepositoryId())
  const [model, setModel] = useState<IdeBranchContextModel | null>(null)
  const [state, setState] = useState<PanelState>('loading')
  const [error, setError] = useState<string | null>(null)
  const [presence, setPresence] = useState(globalPresenceSnapshot.value)
  const [overlay, setOverlay] = useState(cursorOverlaySignal.value)

  useEffect(() => globalPresenceSnapshot.subscribe(v => setPresence(v)), [])
  useEffect(() => cursorOverlaySignal.subscribe(v => setOverlay(v)), [])

  useEffect(() => {
    if (!subscribeActiveRepositoryId) return undefined
    return subscribeActiveRepositoryId(() => {
      setRepoId(activeRepositoryId())
    })
  }, [activeRepositoryId, subscribeActiveRepositoryId])

  useEffect(() => {
    if (!repoId) {
      setModel(null)
      setError(null)
      setState('empty')
      return undefined
    }

    let cancelled = false
    const controller = new AbortController()

    const load = () => {
      setState(current => current === 'ready' ? current : 'loading')
      fetchGraph({ limit: 80, repoId, signal: controller.signal })
        .then(graph => {
          if (cancelled) return
          const next = buildIdeBranchContextModel(graph, repoId)
          setModel(next)
          setError(null)
          setState(next ? 'ready' : 'empty')
        })
        .catch(err => {
          if (cancelled || controller.signal.aborted) return
          setError(err instanceof Error ? err.message : String(err))
          setState('error')
        })
    }

    load()
    const timer = refreshMs && refreshMs > 0
      ? window.setInterval(load, refreshMs)
      : null

    return () => {
      cancelled = true
      controller.abort()
      if (timer) window.clearInterval(timer)
    }
  }, [fetchGraph, refreshMs, repoId])

  const branchSummary = useMemo(() => {
    if (!model) return '0 branches / 0 worktrees'
    return `${model.stats.branchCount} branches / ${model.stats.worktreeCount} worktrees`
  }, [model])

  return html`
    <section class="ide-branch-context" role="region" aria-label="IDE branch context">
      <header class="ide-branch-context-head">
        <span>BRANCH GRAPH</span>
        <span class=${`ide-branch-state is-${model?.status ?? state}`}>
          ${stateLabel(state, model)}
        </span>
      </header>

      ${model ? html`
        <div class="ide-branch-repo-row">
          <span class="ide-branch-repo">${model.repoLabel}</span>
          <span class="ide-branch-current">${model.currentBranch}</span>
          <span class="ide-branch-head">${model.head}</span>
        </div>
        <${MiniBranchGraph} model=${model} />
        <div class="ide-branch-stat-row" aria-label=${branchSummary}>
          <span>${model.stats.branchCount} br</span>
          <span>${model.stats.worktreeCount} wt</span>
          <span>${model.stats.commitCount} commits</span>
          <span class=${model.stats.conflictCount > 0 ? 'is-conflict' : model.stats.dirtyCount > 0 ? 'is-dirty' : ''}>
            ${model.stats.conflictCount > 0 ? `${model.stats.conflictCount} conflicts` : `${model.stats.dirtyCount} dirty`}
          </span>
        </div>
        ${model.lanes.length > 0 ? html`
          <ol class="ide-branch-lanes" aria-label="Worktree lanes">
            ${model.lanes.map(lane => LaneRow(lane, presence, overlay))}
          </ol>
        ` : null}
        ${model.warnings.length > 0 ? html`
          <div class="ide-branch-warning" role="status">${model.warnings[0]}</div>
        ` : null}
      ` : html`
        <div class="ide-branch-empty" role=${state === 'error' ? 'alert' : 'status'}>
          ${state === 'loading'
            ? 'branch graph syncing...'
            : state === 'error'
              ? `git graph unavailable: ${error ?? 'unknown error'}`
              : repoId
                ? 'no repository graph'
                : 'select repository'}
        </div>
      `}
    </section>
  `
}

const LANE_STATUS_DOT: Record<KeeperPresenceStatus, { color: string; label: string }> = {
  active: { color: 'var(--color-status-ok)', label: 'ACTIVE' },
  blocked: { color: 'var(--color-status-err)', label: 'BLOCKED' },
  idle: { color: 'var(--color-fg-muted)', label: 'IDLE' },
}

function LaneRow(
  lane: IdeWorktreeLane,
  presence: { readonly entries: ReadonlyArray<{ keeper_id: string; status: KeeperPresenceStatus }> } | null,
  overlay: { readonly cursors: Map<string, { keeper_id: string; file_path: string; line: number }> },
) {
  // Lane.id is the worktree path; presence/cursor stores key on keeper_id.
  // Prefer the explicit keeperId mapping when the snapshot supplies it,
  // otherwise fall back to id and accept that the lookup may miss.
  const presenceKey = lane.keeperId ?? lane.id
  const entry = presence?.entries.find(e => e.keeper_id === presenceKey)
  const status = entry?.status
  const cursor = overlay.cursors.get(presenceKey)
  const focusFile = cursor?.file_path ? cursor.file_path.split('/').pop() : null
  const dotStyle = status ? LANE_STATUS_DOT[status] : null

  return html`
    <li key=${lane.id} style=${{ display: 'grid', gridTemplateColumns: '6px 1fr auto', alignItems: 'center', gap: 'var(--sp-1)', padding: '2px 0' }}>
      <span
        aria-hidden="true"
        style=${{
          width: '5px',
          height: '5px',
          borderRadius: '50%',
          background: dotStyle ? dotStyle.color : 'var(--color-fg-disabled)',
          boxShadow: status === 'active' ? `0 0 4px ${dotStyle?.color ?? 'transparent'}` : 'none',
          justifySelf: 'center',
        }}
      />
      <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-1)', minWidth: 0, overflow: 'hidden' }}>
        <span class="ide-branch-lane-name">${lane.label}</span>
        <span class="ide-branch-lane-branch">${lane.branch}</span>
        <span class="ide-branch-lane-path">${lane.path}</span>
        ${focusFile ? html`
          <span
            style=${{
              fontSize: 'var(--fs-10)',
              fontFamily: 'var(--font-mono)',
              color: 'var(--color-accent-fg)',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
            }}
            title=${cursor?.file_path}
          >${focusFile}:${cursor?.line}</span>
        ` : null}
      </div>
      ${dotStyle ? html`
        <span
          role="status"
          aria-label=${`Keeper ${lane.id}: ${dotStyle.label}`}
          style=${{
            fontSize: 'var(--fs-9)',
            fontWeight: 600,
            letterSpacing: '0.04em',
            color: dotStyle.color,
            whiteSpace: 'nowrap',
          }}
        >${dotStyle.label}</span>
      ` : null}
    </li>
  `
}
