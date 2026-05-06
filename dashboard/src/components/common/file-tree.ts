// FileTree — AX molecule for visualizing agent file systems.
//
// Kimi design system sec02 reference: 2.1.2 virtualized + collapsible file tree
// with git status badges.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
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
  'aria-label'?: string
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
  row: FileTreeRow,
  rowIndex: number,
  rows: ReadonlyArray<FileTreeRow>,
  expanded: ReadonlySet<string>,
  setActiveId: (id: string) => void,
  onSelect?: (node: FileNode) => void,
  onToggle?: (id: string) => void,
): void {
  const node = row.node
  const focusRow = (nextIndex: number) => {
    const next = rows[nextIndex]
    if (!next) return
    setActiveId(next.node.id)
    const root = (e.currentTarget as HTMLElement).closest('[data-file-tree]')
    root?.querySelector<HTMLElement>(`[data-file-tree-index="${nextIndex}"]`)?.focus()
  }

  switch (e.key) {
    case 'Enter':
    case ' ':
      e.preventDefault()
      activateNode(node, onSelect, onToggle)
      break
    case 'ArrowRight':
      e.preventDefault()
      if (node.type === 'directory') {
        if (!expanded.has(node.id)) onToggle?.(node.id)
        else if (rows[rowIndex + 1]?.depth === row.depth + 1) focusRow(rowIndex + 1)
      }
      break
    case 'ArrowLeft':
      e.preventDefault()
      if (node.type === 'directory' && expanded.has(node.id)) {
        onToggle?.(node.id)
      } else {
        const parentIndex = rows
          .slice(0, rowIndex)
          .map((candidate, index) => ({ candidate, index }))
          .reverse()
          .find(({ candidate }) => candidate.depth === row.depth - 1)?.index
        if (parentIndex != null) focusRow(parentIndex)
      }
      break
    case 'ArrowDown':
      e.preventDefault()
      focusRow(Math.min(rowIndex + 1, rows.length - 1))
      break
    case 'ArrowUp':
      e.preventDefault()
      focusRow(Math.max(rowIndex - 1, 0))
      break
    case 'Home':
      e.preventDefault()
      focusRow(0)
      break
    case 'End':
      e.preventDefault()
      focusRow(rows.length - 1)
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
  rowIndex: number,
  activeId: string | null,
  rows: ReadonlyArray<FileTreeRow>,
  expanded: ReadonlySet<string>,
  setActiveId: (id: string) => void,
  onSelect?: (node: FileNode) => void,
  onToggle?: (id: string) => void,
): ReturnType<typeof html> {
  const { node, depth, posInSet, setSize } = row
  const isExpanded = expanded.has(node.id)
  const isActive = node.id === activeId
  const paddingLeft = `${depth * 16}px`

  return html`
    <div
      key=${node.id}
      class="flex min-w-0 cursor-pointer items-center gap-1 rounded-[var(--r-1)] py-0.5 pr-2 hover:bg-[var(--color-bg-hover)]"
      style=${{ paddingLeft }}
      onClick=${() => activateNode(node, onSelect, onToggle)}
      onFocus=${() => setActiveId(node.id)}
      role="treeitem"
      aria-expanded=${node.type === 'directory' ? isExpanded : undefined}
      aria-level=${depth + 1}
      aria-posinset=${posInSet}
      aria-setsize=${setSize}
      data-file-tree-row=${node.id}
      data-file-tree-index=${rowIndex}
      data-file-tree-depth=${depth}
      tabindex=${isActive ? 0 : -1}
      onKeyDown=${(e: KeyboardEvent) =>
        handleTreeRowKeyDown(e, row, rowIndex, rows, expanded, setActiveId, onSelect, onToggle)}
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
  'aria-label': ariaLabel = '파일 트리',
}: FileTreeProps) {
  const [activeId, setActiveId] = useState<string | null>(null)
  const expanded = new Set(expandedIds)
  const rows = visibleFileTreeRows(nodes, expanded)
  const visibleActiveId = rows.some(row => row.node.id === activeId)
    ? activeId
    : rows[0]?.node.id ?? null

  return html`
    <div
      class="overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2"
      data-file-tree
      data-testid=${testId}
      role="tree"
      aria-label=${ariaLabel}
    >
      ${rows.map((row, rowIndex) =>
        renderRow(row, rowIndex, visibleActiveId, rows, expanded, setActiveId, onSelect, onToggle))}
    </div>
  `
}
