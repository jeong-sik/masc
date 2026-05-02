// FileTree — AX molecule for visualizing agent file systems.
//
// Kimi design system sec02 reference: 2.1.2 virtualized + collapsible file tree
// with git status badges.

import { html } from 'htm/preact'

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

function gitStatusColor(status?: string): string {
  switch (status) {
    case 'modified':
      return 'var(--warn-10)'
    case 'added':
      return 'var(--ok-10)'
    case 'deleted':
      return 'var(--error-10)'
    default:
      return 'var(--color-fg-muted)'
  }
}

function renderNode(
  node: FileNode,
  depth: number,
  expanded: Set<string>,
  onSelect?: (node: FileNode) => void,
  onToggle?: (id: string) => void,
): ReturnType<typeof html>[] {
  const isExpanded = expanded.has(node.id)
  const paddingLeft = `${depth * 16}px`

  const row = html`
    <div
      key=${node.id}
      class="flex cursor-pointer items-center rounded py-0.5 pr-2 hover:bg-[var(--white-6)]"
      style=${{ paddingLeft }}
      onClick=${() =>
        node.type === 'directory' ? onToggle?.(node.id) : onSelect?.(node)}
      role="treeitem"
      aria-expanded=${node.type === 'directory' ? isExpanded : undefined}
      aria-selected="false"
      tabindex="0"
      onKeyDown=${(e: KeyboardEvent) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          node.type === 'directory' ? onToggle?.(node.id) : onSelect?.(node)
        }
      }}
    >
      <span class="inline-block w-4 text-center text-[var(--color-fg-secondary)]" aria-hidden="true">
        ${node.type === 'directory' ? (isExpanded ? '▼' : '▶') : ' '}
      </span>
      <span class="text-sm text-[var(--color-fg-primary)]">${node.name}</span>
      ${node.gitStatus
        ? html`
            <span
              class="ml-2 inline-block h-1.5 w-1.5 rounded-full"
              style=${{ background: gitStatusColor(node.gitStatus) }}
              title=${node.gitStatus}
            ></span>
          `
        : null}
    </div>
  `

  const children: ReturnType<typeof html>[] = []
  children.push(row)

  if (node.type === 'directory' && node.children && isExpanded) {
    for (const child of node.children) {
      children.push(...renderNode(child, depth + 1, expanded, onSelect, onToggle))
    }
  }

  return children
}

export function FileTree({
  nodes,
  onSelect,
  expandedIds = [],
  onToggle,
  testId,
}: FileTreeProps) {
  const expanded = new Set(expandedIds)

  return html`
    <div
      class="overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2"
      data-file-tree
      data-testid=${testId}
      role="tree"
      aria-label="파일 트리"
    >
      ${nodes.flatMap(n => renderNode(n, 0, expanded, onSelect, onToggle))}
    </div>
  `
}
