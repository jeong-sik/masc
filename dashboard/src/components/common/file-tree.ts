// FileTree — AX molecule for visualizing agent file systems.
//
// Kimi design system sec02 reference: 2.1.2 virtualized + collapsible file tree
// with git status badges.

import { html } from 'htm/preact'
import { StatusChip, type StatusChipTone } from './status-chip'

export interface FileNode {
  id: string
  name: string
  type: 'file' | 'directory'
  children?: FileNode[]
  gitStatus?: 'modified' | 'added' | 'deleted' | 'untracked'
}

interface FileTreeProps {
  nodes: FileNode[]
  onSelect?: (node: FileNode) => void
  expandedIds?: string[]
  onToggle?: (id: string) => void
  testId?: string
}

type GitStatus = NonNullable<FileNode['gitStatus']>

export interface FileTreeRow {
  readonly node: FileNode
  readonly depth: number
  readonly posInSet: number
  readonly setSize: number
}

const GIT_STATUS_META: Record<
  GitStatus,
  { readonly label: string; readonly shortLabel: string; readonly tone: StatusChipTone }
> = {
  modified: { label: 'modified', shortLabel: 'M', tone: 'warn' },
  added: { label: 'added', shortLabel: 'A', tone: 'ok' },
  deleted: { label: 'deleted', shortLabel: 'D', tone: 'bad' },
  untracked: { label: 'untracked', shortLabel: 'U', tone: 'neutral' },
}

export function visibleFileTreeRows(
  nodes: ReadonlyArray<FileNode>,
  expanded: ReadonlySet<string>,
  depth: number = 0,
): FileTreeRow[] {
  const rows: FileTreeRow[] = []
  const setSize = nodes.length
  nodes.forEach((node, index) => {
    rows.push({
      node,
      depth,
      posInSet: index + 1,
      setSize,
    })
    if (node.type === 'directory' && node.children && expanded.has(node.id)) {
      rows.push(...visibleFileTreeRows(node.children, expanded, depth + 1))
    }
  })
  return rows
}

function activateNode(
  node: FileNode,
  onSelect?: (node: FileNode) => void,
  onToggle?: (id: string) => void,
): void {
  if (node.type === 'directory') onToggle?.(node.id)
  else onSelect?.(node)
}

function handleTreeRowKeyDown(
  e: KeyboardEvent,
  node: FileNode,
  expanded: ReadonlySet<string>,
  onSelect?: (node: FileNode) => void,
  onToggle?: (id: string) => void,
): void {
  switch (e.key) {
    case 'Enter':
    case ' ':
      e.preventDefault()
      activateNode(node, onSelect, onToggle)
      break
    case 'ArrowRight':
      if (node.type === 'directory' && !expanded.has(node.id)) {
        e.preventDefault()
        onToggle?.(node.id)
      }
      break
    case 'ArrowLeft':
      if (node.type === 'directory' && expanded.has(node.id)) {
        e.preventDefault()
        onToggle?.(node.id)
      }
      break
  }
}

function renderGitStatus(status: GitStatus) {
  const meta = GIT_STATUS_META[status]
  return html`
    <span
      class="ml-auto shrink-0"
      data-file-tree-git-status=${status}
      aria-label=${`${meta.label} git status`}
      title=${`${meta.label} git status`}
    >
      <${StatusChip} tone=${meta.tone} uppercase=${false} class="font-mono">
        ${meta.shortLabel}
      </${StatusChip}>
    </span>
  `
}

function renderRow(
  row: FileTreeRow,
  expanded: ReadonlySet<string>,
  onSelect?: (node: FileNode) => void,
  onToggle?: (id: string) => void,
): ReturnType<typeof html> {
  const { node, depth, posInSet, setSize } = row
  const isExpanded = expanded.has(node.id)
  const paddingLeft = `${depth * 16}px`

  return html`
    <div
      key=${node.id}
      class="flex min-w-0 cursor-pointer items-center gap-1 rounded-[var(--r-1)] py-0.5 pr-2 hover:bg-[var(--color-bg-hover)]"
      style=${{ paddingLeft }}
      onClick=${() => activateNode(node, onSelect, onToggle)}
      role="treeitem"
      aria-expanded=${node.type === 'directory' ? isExpanded : undefined}
      aria-selected="false"
      aria-level=${depth + 1}
      aria-posinset=${posInSet}
      aria-setsize=${setSize}
      data-file-tree-row=${node.id}
      data-file-tree-depth=${depth}
      tabindex="0"
      onKeyDown=${(e: KeyboardEvent) =>
        handleTreeRowKeyDown(e, node, expanded, onSelect, onToggle)}
    >
      <span class="inline-block w-4 shrink-0 text-center text-[var(--color-fg-secondary)]" aria-hidden="true">
        ${node.type === 'directory' ? (isExpanded ? '▼' : '▶') : ' '}
      </span>
      <span class="min-w-0 truncate text-sm text-[var(--color-fg-primary)]">${node.name}</span>
      ${node.gitStatus ? renderGitStatus(node.gitStatus) : null}
    </div>
  `
}

export function FileTree({
  nodes,
  onSelect,
  expandedIds = [],
  onToggle,
  testId,
}: FileTreeProps) {
  const expanded = new Set(expandedIds)
  const rows = visibleFileTreeRows(nodes, expanded)

  return html`
    <div
      class="overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2"
      data-file-tree
      data-testid=${testId}
      role="tree"
      aria-label="파일 트리"
    >
      ${rows.map(row => renderRow(row, expanded, onSelect, onToggle))}
    </div>
  `
}
