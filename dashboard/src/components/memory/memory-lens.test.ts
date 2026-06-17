import { describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { MemoryLens } from './memory-lens'

const nodeTypes = {
  memory: { kr: '기억', g: '◆', c: '#e0b057' },
  goal: { kr: '골', g: '◎', c: '#5b9cf0' },
  task: { kr: '태스크', g: '▣', c: '#22c55e' },
}

const nodes = {
  mem: { type: 'memory', title: 'insight checkpoint', kp: 'nick0cave', meta: 'insight', ns: 'core/scheduler' },
  goal: { type: 'goal', title: 'scheduler p95 jitter < 50ms', kp: 'nick0cave', meta: '진행 47%', ns: 'core/scheduler' },
  task1: { type: 'task', title: 'isolate compact() call', kp: 'sangsu', meta: 'open', ns: 'core/runtime' },
  task2: { type: 'task', title: 'add regression test', kp: 'nick0cave', meta: 'done', ns: 'core/scheduler' },
}

const edges = [
  { source: 'mem', target: 'goal', rel: '진단' },
  { source: 'mem', target: 'task1', rel: '파생' },
  { source: 'mem', target: 'task2', rel: '검증' },
]

describe('MemoryLens', () => {
  afterEach(() => {
    cleanup()
  })

  it('renders empty state when no nodes are provided', () => {
    render(html`<${MemoryLens} nodes=${{}} edges=${[]} nodeTypes=${nodeTypes} testId="lens-empty" />`)
    expect(screen.getByTestId('lens-empty').textContent).toContain('연결할 메모리 노드가 없습니다')
  })

  it('renders the anchor node and satellite nodes from props', () => {
    render(html`<${MemoryLens} nodes=${nodes} edges=${edges} nodeTypes=${nodeTypes} start="mem" testId="lens" />`)
    const board = screen.getByTestId('lens')
    expect(board.textContent).toContain('insight checkpoint')
    expect(board.textContent).toContain('isolate compact() call')
    expect(board.textContent).toContain('add regression test')
    expect(board.textContent).toContain('scheduler p95 jitter < 50ms')
  })

  it('renders edge relation labels', () => {
    render(html`<${MemoryLens} nodes=${nodes} edges=${edges} nodeTypes=${nodeTypes} start="mem" />`)
    expect(screen.getByText('진단')).not.toBeNull()
    expect(screen.getByText('파생')).not.toBeNull()
    expect(screen.getByText('검증')).not.toBeNull()
  })

  it('re-centers anchor when a satellite node is clicked', () => {
    render(html`<${MemoryLens} nodes=${nodes} edges=${edges} nodeTypes=${nodeTypes} start="mem" testId="lens" />`)
    const board = screen.getByTestId('lens')
    expect(board.textContent).toContain('insight checkpoint')

    const goalCard = screen.getByText('scheduler p95 jitter < 50ms').closest('.mg-node')
    expect(goalCard).not.toBeNull()
    fireEvent.click(goalCard!)

    expect(board.textContent).toContain('scheduler p95 jitter < 50ms')
    // The previous anchor should now be a satellite title in the board.
    expect(board.textContent).toContain('insight checkpoint')
  })

  it('calls onSelectNode when a satellite node is clicked', () => {
    const onSelectNode = vi.fn()
    render(html`<${MemoryLens}
      nodes=${nodes}
      edges=${edges}
      nodeTypes=${nodeTypes}
      start="mem"
      onSelectNode=${onSelectNode}
    />`)

    const goalCard = screen.getByText('scheduler p95 jitter < 50ms').closest('.mg-node')
    fireEvent.click(goalCard!)
    expect(onSelectNode).toHaveBeenCalledWith('goal')
  })

  it('ignores edges that reference missing nodes', () => {
    const edgesWithMissing = [
      ...edges,
      { source: 'mem', target: 'missing', rel: 'orphan' },
    ]
    render(html`<${MemoryLens}
      nodes=${nodes}
      edges=${edgesWithMissing}
      nodeTypes=${nodeTypes}
      start="mem"
      testId="lens"
    />`)
    expect(screen.getByTestId('lens').textContent).not.toContain('orphan')
  })
})
