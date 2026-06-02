// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { waitFor } from '@testing-library/preact'
import { axe } from 'jest-axe'
import type { GitGraphResponse } from '../../api/git-graph'
import { IdeBranchContextPanel } from './ide-branch-context-panel'

function graph(): GitGraphResponse {
  return {
    generated_at: '2026-05-06T00:00:00Z',
    repos: [{
      id: 'masc',
      root: '/workspace/masc-mcp',
      label: 'masc-mcp',
      current_branch: 'main',
      head: 'abc123',
      dirty: false,
      conflict_count: 0,
      branch_count: 2,
      commit_count: 8,
      worktree_count: 1,
    }],
    agents: [{
      id: 'main',
      label: 'main',
      branch: 'main',
      worktree_path: '/workspace/masc-mcp',
      color: '#d4a14a',
    }],
    nodes: [{
      id: 'branch-main',
      kind: 'branch',
      label: 'main',
      repo_id: 'masc',
      agent_id: 'main',
      color: '#d4a14a',
      status: 'current',
      conflict: false,
      sha: 'abc123',
      branch: 'main',
      detail: 'current branch',
    }],
    edges: [],
    stats: {
      repo_count: 1,
      agent_count: 1,
      branch_count: 2,
      commit_count: 8,
      conflict_count: 0,
      dirty_count: 0,
    },
    warnings: [],
  }
}

describe('IdeBranchContextPanel a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders loaded branch context without axe violations', async () => {
    const fetchGraph = vi.fn().mockResolvedValue(graph())

    render(
      html`<${IdeBranchContextPanel}
        activeRepositoryId=${() => 'masc'}
        fetchGraph=${fetchGraph}
        refreshMs=${null}
      />`,
      container,
    )

    await waitFor(() => expect(container.textContent).toContain('masc-mcp'))
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders error state without axe violations', async () => {
    const fetchGraph = vi.fn().mockRejectedValue(new Error('offline'))

    render(
      html`<${IdeBranchContextPanel}
        activeRepositoryId=${() => 'masc'}
        fetchGraph=${fetchGraph}
        refreshMs=${null}
      />`,
      container,
    )

    await waitFor(() => expect(container.textContent).toContain('git graph unavailable'))
    expect(await axe(container)).toHaveNoViolations()
  })
})
