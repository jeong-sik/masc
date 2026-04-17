import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'

import {
  buildResolvedAllowlistGroups,
  filterResolvedTools,
  ResolvedPreview,
} from './tool-allowlist-editor'

afterEach(() => {
  cleanup()
})

describe('buildResolvedAllowlistGroups', () => {
  it('groups tools by category and sorts larger groups first', () => {
    const groups = buildResolvedAllowlistGroups(
      ['board-a', 'misc-a', 'board-b'],
      new Map([
        ['board-a', 'board'],
        ['board-b', 'board'],
        ['misc-a', 'misc'],
      ]),
    )

    expect(groups).toEqual([
      { category: 'board', names: ['board-a', 'board-b'] },
      { category: 'misc', names: ['misc-a'] },
    ])
  })
})

describe('filterResolvedTools', () => {
  const catMap = new Map<string, string>([
    ['board-post', 'board'],
    ['board-read', 'board'],
    ['shell-exec', 'shell'],
    ['memory-store', 'memory'],
    ['Graph-Query', 'graph'],
  ])

  it('returns input reference when query is empty', () => {
    const tools = ['board-post', 'shell-exec']
    expect(filterResolvedTools(tools, catMap, '')).toBe(tools)
  })

  it('returns input reference when query is whitespace', () => {
    const tools = ['board-post', 'shell-exec']
    expect(filterResolvedTools(tools, catMap, '   ')).toBe(tools)
  })

  it('matches tool name substring case-insensitively', () => {
    const tools = ['board-post', 'board-read', 'shell-exec']
    expect(filterResolvedTools(tools, catMap, 'BOARD')).toEqual(['board-post', 'board-read'])
  })

  it('matches category substring case-insensitively', () => {
    const tools = ['board-post', 'shell-exec', 'memory-store']
    expect(filterResolvedTools(tools, catMap, 'MEM')).toEqual(['memory-store'])
  })

  it('matches mixed-case tool names', () => {
    const tools = ['Graph-Query', 'shell-exec']
    expect(filterResolvedTools(tools, catMap, 'graph')).toEqual(['Graph-Query'])
  })

  it('returns empty array when nothing matches', () => {
    const tools = ['board-post', 'shell-exec']
    expect(filterResolvedTools(tools, catMap, 'zzznope')).toEqual([])
  })

  it('handles tools without a category entry (no crash, no category match)', () => {
    const tools = ['orphan-tool', 'board-post']
    expect(filterResolvedTools(tools, catMap, 'board')).toEqual(['board-post'])
    expect(filterResolvedTools(tools, catMap, 'orphan')).toEqual(['orphan-tool'])
  })

  it('does not mutate the input array', () => {
    const tools = ['board-post', 'shell-exec', 'memory-store']
    const snapshot = [...tools]
    filterResolvedTools(tools, catMap, 'board')
    expect(tools).toEqual(snapshot)
  })

  it('trims query before matching', () => {
    const tools = ['board-post', 'shell-exec']
    expect(filterResolvedTools(tools, catMap, '  board  ')).toEqual(['board-post'])
  })
})

describe('ResolvedPreview', () => {
  it('shows only a collapsed subset until expanded', () => {
    const tools = [
      'board-1',
      'board-2',
      'board-3',
      'board-4',
      'board-5',
      'board-6',
      'board-7',
      'shell-1',
      'shell-2',
      'shell-3',
      'shell-4',
      'shell-5',
      'shell-6',
      'shell-7',
      'memory-1',
      'memory-2',
      'memory-3',
      'memory-4',
      'memory-5',
      'memory-6',
      'memory-7',
      'graph-1',
      'graph-2',
      'graph-3',
      'graph-4',
      'graph-5',
      'graph-6',
      'graph-7',
      'extra-1',
    ]
    const catMap = new Map<string, string>()
    for (const name of tools) {
      if (name.startsWith('board')) catMap.set(name, 'board')
      else if (name.startsWith('shell')) catMap.set(name, 'shell')
      else if (name.startsWith('memory')) catMap.set(name, 'memory')
      else if (name.startsWith('graph')) catMap.set(name, 'graph')
      else catMap.set(name, 'extra')
    }

    render(h(ResolvedPreview, { tools, catMap }))

    expect(screen.getByText('board-1')).toBeInTheDocument()
    expect(screen.getByText('board-6')).toBeInTheDocument()
    expect(screen.queryByText('board-7')).not.toBeInTheDocument()
    expect(screen.queryByText('extra (1)')).not.toBeInTheDocument()
    const toggle = screen.getByRole('button', { name: `resolved allowlist 전체 ${tools.length}개 보기` })
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(screen.getByText(`전체 ${tools.length}개 보기`)).toBeInTheDocument()

    fireEvent.click(toggle)

    expect(screen.getByText('board-7')).toBeInTheDocument()
    expect(screen.getByText('extra (1)')).toBeInTheDocument()
    expect(screen.getByText('접기')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'resolved allowlist 접기' })).toHaveAttribute('aria-expanded', 'true')
  })
})
