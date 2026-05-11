import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { Search } from 'lucide-preact'
import { activeKeeperName } from '../../keeper-state'
import { type FileTreeStore, type FileTreeNode } from './file-tree-store'
import { activeIdeFile } from './ide-shell'
import type { WorkspaceSource } from '../../api/workspace-source'
import type { Repository } from '../../api/repositories'
import { showToast } from '../common/toast'
import { KeeperBadge } from '../keeper-badge'

interface IdeExplorerProps {
  readonly fileTreeStore: FileTreeStore
  // Optional source-hint wiring: when provided, [SourceHint] renders a
  // small status block under the EXPLORER header on
  // [playground_missing] / [keeper_unknown] resolutions. Decoded from
  // the [X-Workspace-Source] header by the data coordinator. When
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
  const fileCount = filtered.filter(n => !n.hasChildren).length
  const scopeLabel = explorerScopeLabel(source, keeperName, repoList)

  return html`
    <div
      class="ide-explorer"
      role="region"
      aria-label="EXPLORER"
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
        <span>EXPLORER · <span
            style=${{
              color: scopeLabel.tone === 'accent'
                ? 'var(--color-accent-fg)'
                : 'var(--color-fg-muted)',
            }}
          >${scopeLabel.label}</span></span>
        <span>${fileCount} FILES</span>
      </header>
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
              if (node.hasChildren) store.toggle(node.path)
              else activeIdeFile.value = node.path
            },
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

function TreeRow(node: FileTreeNode, expanded: boolean, selected: boolean, onClick: () => void) {
  const indent = node.depth * 12
  const chevron = node.hasChildren ? (expanded ? '▾' : '▸') : ''
  const onKeyDown = (e: KeyboardEvent): void => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      onClick()
    }
  }
  return html`
    <li
      class="ide-explorer-row"
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
      ${node.diff !== null
        ? html`<span style=${{ color: 'var(--color-fg-muted)', font: 'var(--fs-11)' }}>${node.diff}</span>`
        : null}
    </li>
  `
}
