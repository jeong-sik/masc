import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { Search } from 'lucide-preact'
import { activeKeeperName } from '../../keeper-state'
import { type FileTreeStore, type FileTreeNode, type FileTreeDiffSummary } from './file-tree-store'
import { activeIdeFile, ideContextFocus, type IdeContextFocus } from './ide-state'
import type { WorkspaceSource } from '../../api/workspace-source'
import type { Repository } from '../../api/repositories'
import { showToast } from '../common/toast'
import { KeeperBadge } from '../keeper-badge'
import { cursorOverlaySignal, getKeeperColor } from './keeper-cursor-overlay'
import { openIdeContextRouteLink } from './ide-context-lens'

interface IdeExplorerProps {
  readonly fileTreeStore: FileTreeStore
  // Optional source-hint wiring: when provided, [SourceHint] renders a
  // small status block under the EXPLORER header on
  // [playground_missing] / [keeper_unknown] resolutions. Decoded from
  // the [X-Workspace-Source] header by the data workspace store. When
  // omitted (e.g. tests), the hint stays hidden — default is
  // [{ kind: 'project' }] which renders nothing.
  readonly workspaceSource?: () => WorkspaceSource
  readonly subscribeWorkspaceSource?: (listener: () => void) => () => void
  readonly repositories?: () => ReadonlyArray<Repository>
  readonly activeRepositoryId?: () => string | null
  readonly onRepositoryChange?: (repoId: string | null) => void
  readonly onRepositoryScan?: () => Promise<ReadonlyArray<Repository>>
  readonly subscribeRepositories?: (listener: () => void) => () => void
}

type ExplorerScopeTone = 'accent' | 'muted'

interface ExplorerScopeLabel {
  readonly label: string
  readonly tone: ExplorerScopeTone
}

const EXPLORER_CONTEXT_LINK_LIMIT = 3

function repositoryLabel(
  repositories: ReadonlyArray<Repository>,
  repoId: string,
): string {
  const repository = repositories.find(candidate => candidate.id === repoId)
  return repository?.name.trim() || repoId
}

export function explorerScopeLabel(
  source: WorkspaceSource,
  keeperName: string,
  repositories: ReadonlyArray<Repository> = [],
): ExplorerScopeLabel {
  const keeper = keeperName.trim()
  if (keeper) return { label: `@${keeper}`, tone: 'accent' }

  switch (source.kind) {
    case 'repository':
      return { label: repositoryLabel(repositories, source.repoId), tone: 'accent' }
    case 'repository_missing':
    case 'repository_unknown':
      return { label: `${repositoryLabel(repositories, source.repoId)} fallback`, tone: 'muted' }
    case 'playground':
      return { label: `@${source.keeper}`, tone: 'accent' }
    case 'playground_missing':
    case 'keeper_unknown':
      return { label: `@${source.keeper} fallback`, tone: 'muted' }
    case 'project':
      return { label: 'project', tone: 'muted' }
  }
}

export function explorerFileCountLabel(
  visibleFileCount: number,
  filteredFileCount: number,
  filtering: boolean,
): string {
  return filtering
    ? `${filteredFileCount}/${visibleFileCount} VISIBLE`
    : `${visibleFileCount} VISIBLE`
}

export function IdeExplorer({
  fileTreeStore: store,
  workspaceSource,
  subscribeWorkspaceSource,
  repositories,
  activeRepositoryId,
  onRepositoryChange,
  onRepositoryScan,
  subscribeRepositories,
}: IdeExplorerProps) {
  const [keeperName, setKeeperName] = useState(activeKeeperName.value)
  useEffect(() => activeKeeperName.subscribe(name => setKeeperName(name)), [])

  const [source, setSource] = useState<WorkspaceSource>(
    workspaceSource ? workspaceSource() : { kind: 'project' },
  )
  useEffect(() => {
    if (!subscribeWorkspaceSource || !workspaceSource) return
    return subscribeWorkspaceSource(() => setSource(workspaceSource()))
  }, [subscribeWorkspaceSource, workspaceSource])

  const [repoList, setRepoList] = useState<ReadonlyArray<Repository>>(
    repositories ? repositories() : [],
  )
  const [selectedRepoId, setSelectedRepoId] = useState<string | null>(
    activeRepositoryId ? activeRepositoryId() : null,
  )
  useEffect(() => {
    if (!subscribeRepositories || !repositories) return
    return subscribeRepositories(() => {
      setRepoList(repositories())
      setSelectedRepoId(activeRepositoryId ? activeRepositoryId() : null)
    })
  }, [activeRepositoryId, repositories, subscribeRepositories])

  const [tick, setTick] = useState(0)
  useEffect(() => {
    const dispose = store.subscribe(() => setTick(n => n + 1))
    return dispose
  }, [store])

  const [filter, setFilter] = useState('')
  const [isScanningRepositories, setIsScanningRepositories] = useState(false)
  const [activeFile, setActiveFile] = useState(activeIdeFile.value)
  useEffect(() => activeIdeFile.subscribe(file => setActiveFile(file)), [])

  const [contextFocus, setContextFocus] = useState(ideContextFocus.value)
  useEffect(() => ideContextFocus.subscribe(focus => setContextFocus(focus)), [])

  const [cursorOverlay, setCursorOverlay] = useState(cursorOverlaySignal.value)
  useEffect(() => cursorOverlaySignal.subscribe(v => setCursorOverlay(v)), [])

  const handleRepositoryScan = async (): Promise<void> => {
    if (!onRepositoryScan || isScanningRepositories) return
    setIsScanningRepositories(true)
    try {
      const registered = await onRepositoryScan()
      showToast(
        registered.length > 0
          ? `${registered.length}개 저장소 등록 완료`
          : '새 저장소 없음',
        'success',
      )
    } catch (err) {
      const msg = err instanceof Error ? err.message : '저장소 스캔 실패'
      showToast(msg, 'error')
      throw err
    } finally {
      setIsScanningRepositories(false)
    }
  }

  // useMemo over `tick` so the visibleNodes call re-runs when the
  // store's expansion state changes; tick reference is intentional.
  const visible = useMemo(() => store.visibleNodes(), [store, tick])
  const filtered = useMemo(() => {
    const needle = filter.trim().toLowerCase()
    if (needle === '') return visible
    return visible.filter(n => n.label.toLowerCase().includes(needle))
  }, [visible, filter])
  const filtering = filter.trim() !== ''
  const visibleFileCount = visible.filter(n => !n.hasChildren).length
  const filteredFileCount = filtered.filter(n => !n.hasChildren).length
  const fileCountLabel = explorerFileCountLabel(visibleFileCount, filteredFileCount, filtering)
  const diffSummary = useMemo(() => store.diffSummary(), [store, tick])
  const scopeLabel = explorerScopeLabel(source, keeperName, repoList)

  // Reverse map: file_path → keepers currently focused on that file
  const keepersByFile = useMemo(() => {
    const map = new Map<string, Array<{ readonly keeperId: string; readonly color: string; readonly focusMode: string }>>()
    for (const [keeperId, cursor] of cursorOverlay.cursors) {
      if (!cursor.file_path) continue
      const entry = { keeperId, color: getKeeperColor(keeperId).cursor, focusMode: cursor.focus_mode }
      const existing = map.get(cursor.file_path)
      if (existing) existing.push(entry)
      else map.set(cursor.file_path, [entry])
    }
    return map
  }, [cursorOverlay])

  return html`
    <div
      class="ide-explorer"
      role="region"
      aria-label=${`EXPLORER ${scopeLabel.label}; ${fileCountLabel}`}
    >
      <header
        style=${{
          display: 'flex',
          justifyContent: 'space-between',
          color: 'var(--color-fg-muted)',
          font: 'var(--type-eyebrow)',
          paddingBottom: 'var(--sp-2)',
          borderBottom: '1px solid var(--color-border-divider)',
        }}
      >
        <span
          style=${{
            display: 'grid',
            gap: 'var(--sp-1)',
            minWidth: 0,
            width: '100%',
          }}
        >
          <span
            style=${{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: 'var(--sp-2)',
              minWidth: 0,
            }}
          >
            <span>EXPLORER</span>
            <span
              data-testid="ide-explorer-file-count"
              title="Files currently loaded in the visible tree; unopened directories load when expanded."
              aria-label=${fileCountLabel}
              style=${{
                flex: 'none',
                letterSpacing: '0.08em',
                whiteSpace: 'nowrap',
              }}
            >${fileCountLabel}</span>
          </span>
          <span
            data-testid="ide-explorer-source"
            title=${`Workspace source: ${scopeLabel.label}`}
            style=${{
              color: scopeLabel.tone === 'accent'
                ? 'var(--color-accent-fg)'
                : 'var(--color-fg-muted)',
              minWidth: 0,
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
            }}
          >${scopeLabel.label}</span>
        </span>
      </header>
      ${diffSummary.changedFiles > 0 ? ExplorerDiffSummary(diffSummary) : null}
      ${repoList.length > 0 || onRepositoryScan ? html`
        <div
          style=${{
            display: 'grid',
            gap: 'var(--sp-1)',
            color: 'var(--color-fg-muted)',
            font: 'var(--type-eyebrow)',
          }}
        >
          <div
            style=${{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: 'var(--sp-2)',
            }}
          >
            <span>Repository</span>
            ${onRepositoryScan ? html`
              <button
                type="button"
                class="v2-ide-action"
                title="base path 아래 git 저장소 스캔"
                aria-label="base path 아래 git 저장소 스캔"
                disabled=${isScanningRepositories}
                onClick=${() => { void handleRepositoryScan() }}
                style=${{
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 'var(--sp-1)',
                  height: '22px',
                  padding: '0 var(--sp-2)',
                  color: isScanningRepositories ? 'var(--color-fg-muted)' : 'var(--color-accent-fg)',
                  background: 'var(--color-bg-elevated)',
                  border: '1px solid var(--color-border-default)',
                  borderRadius: 'var(--r-1)',
                  cursor: isScanningRepositories ? 'not-allowed' : 'pointer',
                  opacity: isScanningRepositories ? 0.65 : 1,
                  font: 'var(--type-eyebrow)',
                }}
              >
                <${Search} size=${12} aria-hidden="true" />
                ${isScanningRepositories ? '스캔 중' : '스캔'}
              </button>
            ` : null}
          </div>
          ${repoList.length > 0 ? html`
            <select
              aria-label="IDE repository"
              value=${selectedRepoId ?? repoList[0]?.id ?? ''}
              onChange=${(event: Event) => {
                const next = (event.currentTarget as HTMLSelectElement).value || null
                setSelectedRepoId(next)
                onRepositoryChange?.(next)
              }}
              style=${{
                width: '100%',
                font: 'var(--type-body)',
                fontSize: 'var(--fs-11)',
                color: 'var(--color-fg-primary)',
                background: 'var(--color-bg-elevated)',
                border: '1px solid var(--color-border-default)',
                borderRadius: 'var(--r-1)',
                padding: 'var(--sp-1) var(--sp-2)',
              }}
            >
              ${repoList.map(repository => html`
                <option key=${repository.id} value=${repository.id}>
                  ${repository.name} · ${repository.local_path}
                </option>
              `)}
            </select>
          ` : html`
            <div
              role="status"
              style=${{
                font: 'var(--type-body)',
                fontSize: 'var(--fs-11)',
                color: 'var(--color-fg-muted)',
                background: 'var(--color-bg-muted)',
                borderRadius: 'var(--r-1)',
                padding: 'var(--sp-1) var(--sp-2)',
              }}
            >저장소 없음</div>
          `}
        </div>
      ` : null}
      ${SourceHint(source)}
      <input
        type="search"
        role="searchbox"
        aria-label="파일 트리 필터"
        placeholder="파일 이름 필터"
        value=${filter}
        onInput=${(e: Event) => setFilter((e.target as HTMLInputElement).value)}
        style=${{
          font: 'var(--type-body)',
          fontSize: 'var(--fs-11)',
          color: 'var(--color-fg-primary)',
          background: 'var(--color-bg-elevated)',
          border: '1px solid var(--color-border-default)',
          borderRadius: 'var(--r-1)',
          padding: 'var(--sp-1) var(--sp-2)',
        }}
      />
      <div class="ide-explorer-scroll" role="presentation">
        <ul
          class="ide-explorer-tree"
          role="tree"
          aria-label="File tree"
        >
          ${filtered.map(node => TreeRow(
            node,
            store.isExpanded(node.path),
            node.path === activeFile,
            () => {
              // store.toggle -> expand -> loadChildren fetches this directory's
              // children on first open (no-op if already present/in flight).
              if (node.hasChildren) store.toggle(node.path)
              else activeIdeFile.value = node.path
            },
            contextFocus?.file_path === node.path ? contextFocus : null,
            keepersByFile.get(node.path),
            store.isChildrenLoading(node.path),
          ))}
        </ul>
      </div>
    </div>
  `
}

function SourceHint(source: WorkspaceSource) {
  if (source.kind === 'project' || source.kind === 'playground' || source.kind === 'repository') return null
  const message = source.kind === 'repository_missing'
    ? `${source.repoId} repository 디렉토리가 아직 없어 base path tree로 fallback`
    : source.kind === 'repository_unknown'
      ? `${source.repoId} repository 설정을 찾지 못해 base path tree로 fallback`
      : source.kind === 'playground_missing'
    ? `@${source.keeper} 의 playground 디렉토리가 아직 없어 프로젝트 트리로 fallback`
    : `@${source.keeper} 키퍼 메타를 찾지 못해 프로젝트 트리로 fallback`
  return html`
    <div
      role="status"
      aria-live="polite"
      style=${{
        font: 'var(--type-body)',
        fontSize: 'var(--fs-11)',
        color: 'var(--color-fg-muted)',
        background: 'var(--color-bg-muted)',
        padding: 'var(--sp-1) var(--sp-2)',
        borderRadius: 'var(--r-1)',
      }}
    >${message}</div>
  `
}

function fileIcon(node: FileTreeNode, expanded: boolean): string {
  if (node.hasChildren) return expanded ? '📂' : '📁'
  const dot = node.label.lastIndexOf('.')
  const ext = dot >= 0 ? node.label.slice(dot) : ''
  const ICONS: Readonly<Record<string, string>> = {
    '.ts': '🟦', '.tsx': '🟦',
    '.js': '🟨', '.jsx': '🟨',
    '.py': '🐍',
    '.ml': '🐫', '.mli': '🐫',
    '.rs': '🦀', '.go': '🔵',
    '.json': '📋', '.md': '📝',
    '.html': '🌐', '.css': '🎨',
    '.toml': '⚙️', '.yaml': '⚙️', '.yml': '⚙️',
  }
  return ICONS[ext] ?? '📄'
}

function TreeRow(
  node: FileTreeNode,
  expanded: boolean,
  selected: boolean,
  onClick: () => void,
  contextFocus: IdeContextFocus | null,
  activeKeepers?: ReadonlyArray<{ readonly keeperId: string; readonly color: string; readonly focusMode: string }>,
  loadingChildren = false,
) {
  const indent = node.depth * 12
  // While a directory's children are being fetched (lazy expand), show a
  // pending glyph in the chevron slot so the expand reads as in-progress.
  const chevron = node.hasChildren
    ? (loadingChildren ? '◌' : (expanded ? '▾' : '▸'))
    : ''
  const onKeyDown = (e: KeyboardEvent): void => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      onClick()
    }
  }
  return html`
    <li
      class="ide-explorer-row v2-ide-row"
      role="treeitem"
      aria-expanded=${node.hasChildren ? (expanded ? 'true' : 'false') : undefined}
      aria-selected=${selected ? 'true' : undefined}
      tabIndex=${0}
      onClick=${onClick}
      onKeyDown=${onKeyDown}
      style=${{
        paddingLeft: `${4 + indent}px`,
      }}
    >
      <span aria-hidden="true" style=${{ color: 'var(--color-fg-muted)', width: '12px', textAlign: 'center' }}>${chevron}</span>
      ${node.keeperId
        ? html`<${KeeperBadge} id=${node.keeperId} variant="sigil" size="sm" />`
        : html`<span aria-hidden="true" style=${{ width: '14px', height: '14px', textAlign: 'center', fontSize: '12px', lineHeight: '14px' }}>${fileIcon(node, expanded)}</span>`}
      <span class="ide-explorer-row-label">${node.label}</span>
      ${contextFocus ? ExplorerContextChip(contextFocus) : null}
      ${activeKeepers && activeKeepers.length > 0
        ? html`<span
            aria-label=${`${activeKeepers.map(k => k.keeperId).join(', ')} focusing`}
            style=${{ display: 'inline-flex', gap: '2px', marginLeft: 'auto', flexShrink: 0 }}
          >${activeKeepers.map(k => html`
            <span
              key=${k.keeperId}
              title=${`${k.keeperId} (${k.focusMode})`}
              style=${{
                width: '6px',
                height: '6px',
                borderRadius: '50%',
                background: k.color,
                display: 'inline-block',
              }}
            />
          `)}</span>`
        : null}
      ${node.diff !== null
        ? html`<span
            aria-label=${`Git diff ${node.diff}`}
            title=${`Git diff ${node.diff}`}
            style=${{ color: 'var(--color-fg-muted)', font: 'var(--fs-11)' }}
          >${node.diff}</span>`
        : null}
    </li>
  `
}

function ExplorerDiffSummary(summary: FileTreeDiffSummary) {
  const parts = [
    `${summary.changedFiles} changed`,
    summary.additions > 0 ? `+${summary.additions}` : null,
    summary.deletions > 0 ? `-${summary.deletions}` : null,
    summary.binaryFiles > 0 ? `${summary.binaryFiles} bin` : null,
  ].filter((part): part is string => part !== null)
  return html`
    <div
      role="status"
      aria-label=${`Workspace git changes: ${parts.join(', ')}`}
      style=${{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 'var(--sp-2)',
        minHeight: '24px',
        padding: 'var(--sp-1) var(--sp-2)',
        color: 'var(--color-fg-secondary)',
        background: 'var(--color-bg-muted)',
        border: '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-1)',
        font: 'var(--type-eyebrow)',
        fontVariantNumeric: 'tabular-nums',
      }}
    >
      <span>Git changes</span>
      <span
        style=${{
          display: 'inline-flex',
          gap: 'var(--sp-2)',
          color: 'var(--color-fg-primary)',
        }}
      >
        ${parts.map(part => html`<span key=${part}>${part}</span>`)}
      </span>
    </div>
  `
}

function ExplorerContextChip(focus: IdeContextFocus) {
  const line = focus.line !== undefined ? `L${focus.line}` : null
  const routeLinks = focus.route_links ?? []
  const visibleLinks = routeLinks.slice(0, EXPLORER_CONTEXT_LINK_LIMIT)
  const overflowCount = Math.max(0, routeLinks.length - visibleLinks.length)
  const stopRouteClick = (event: MouseEvent): void => {
    event.stopPropagation()
  }
  const stopRouteKeyDown = (event: KeyboardEvent): void => {
    event.stopPropagation()
  }
  return html`
    <span
      class="ide-explorer-context-chip"
      aria-label=${explorerContextChipLabel(focus)}
      title=${`${focus.surface} · ${focus.label}`}
    >
      <span>${focus.surface}</span>
      ${line ? html`<span>${line}</span>` : null}
      ${visibleLinks.map(link => html`
        <button
          key=${link.id}
          type="button"
          class="v2-ide-action"
          title=${link.evidence}
          aria-label=${`Open ${link.evidence}`}
          onClick=${(event: MouseEvent) => {
            stopRouteClick(event)
            openIdeContextRouteLink(link)
          }}
          onKeyDown=${stopRouteKeyDown}
        >${link.label}</button>
      `)}
      ${overflowCount > 0 ? html`<span aria-label=${`${overflowCount} more context links`}>+${overflowCount}</span>` : null}
    </span>
  `
}

function explorerContextChipLabel(focus: IdeContextFocus): string {
  const line = focus.line !== undefined ? ` line ${focus.line}` : ''
  const links = focus.route_links?.length
    ? `, ${focus.route_links.length} route links`
    : ''
  return `Focused ${focus.surface}${line}: ${focus.label}${links}`
}
