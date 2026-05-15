import { fireEvent } from '@testing-library/preact'
import { h } from 'preact'
import { render } from 'preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { deriveToolbarContextRouteGroups, IdeToolbar } from './ide-toolbar'
import { ideContextFocus } from './ide-state'

let container: HTMLDivElement | null = null

afterEach(() => {
  if (container) render(null, container)
  container = null
  ideContextFocus.value = null
  window.location.hash = ''
})

describe('IdeToolbar', () => {
  it('renders current IDE context focus and routes through its operational links', () => {
    ideContextFocus.value = {
      file_path: 'lib/runtime.ml',
      line: 42,
      surface: 'Task',
      label: 'task task-runtime',
      source_id: 'event-1',
      keeper_id: 'sangsu',
      activated_at_ms: Date.now(),
      route_links: [
        {
          id: 'code:lib/runtime.ml:42',
          label: 'Code',
          tab: 'code',
          params: {
            section: 'ide-shell',
            view: 'source',
            file: 'lib/runtime.ml',
            line: '42',
          },
          evidence: 'Code lib/runtime.ml:42',
        },
        {
          id: 'task:task-runtime',
          label: 'Task',
          tab: 'workspace',
          params: { section: 'planning', view: 'default', task: 'task-runtime' },
          evidence: 'Task task-runtime',
        },
        {
          id: 'pr:15035',
          label: 'PR',
          tab: 'workspace',
          params: { section: 'repositories', view: 'graph', pr: '15035' },
          evidence: 'PR 15035',
        },
        {
          id: 'telemetry:turn-9',
          label: 'Telemetry',
          tab: 'monitoring',
          params: { section: 'fleet-health', view: 'event-log', q: 'turn-9' },
          evidence: 'Fleet telemetry event log · query turn-9',
        },
      ],
    }
    container = document.createElement('div')

    render(h(IdeToolbar, {
      activeView: 'source',
      activeLayers: new Set<string>(),
      onViewChange: vi.fn(),
      onLayersChange: vi.fn(),
    }), container)

    const focus = container.querySelector('[data-testid="ide-toolbar-context-focus"]')
    expect(focus?.getAttribute('aria-label'))
      .toBe('Current IDE context: Task line 42, task task-runtime, keeper sangsu, 4 route links')
    expect(focus?.textContent).toContain('Task')
    expect(focus?.textContent).toContain('L42')
    expect(focus?.textContent).toContain('task task-runtime')
    expect(focus?.textContent).toContain('keeper sangsu')

    const routeGroups = [...container.querySelectorAll<HTMLSpanElement>('.ide-toolbar-context-route-groups > span')]
    expect(routeGroups.map(group => group.getAttribute('aria-label'))).toEqual([
      'Code: 1 route link',
      'Plan: 1 route link',
      'Repo: 1 route link',
      'Runtime: 1 route link',
    ])
    const routeGroupButtons = [...container.querySelectorAll<HTMLButtonElement>(
      '.ide-toolbar-context-route-group-action',
    )]
    expect(routeGroupButtons.map(group => group.getAttribute('aria-label'))).toEqual([
      'Open Code lib/runtime.ml:42',
      'Open Task task-runtime',
      'Open PR 15035',
      'Open Fleet telemetry event log · query turn-9',
    ])

    const routeLinks = [...container.querySelectorAll<HTMLButtonElement>('.ide-toolbar-context-links button')]
    expect(container.querySelector('.ide-toolbar-context-route-count')?.textContent).toBe('CTX 4')
    expect(routeLinks.map(link => link.getAttribute('aria-label'))).toEqual([
      'Open Code lib/runtime.ml:42',
      'Open Task task-runtime',
      'Open PR 15035',
      'Open Fleet telemetry event log · query turn-9',
    ])
    expect(routeLinks[0]?.querySelector('.ide-toolbar-context-link-evidence')?.textContent)
      .toBe('lib/runtime.ml:42')
    expect(routeLinks[1]?.querySelector('.ide-toolbar-context-link-evidence')?.textContent)
      .toBe('task-runtime')
    expect(routeLinks[3]?.querySelector('.ide-toolbar-context-link-evidence')?.textContent)
      .toBe('query turn-9')

    fireEvent.click(routeGroupButtons.find(group => group.getAttribute('aria-label')?.includes('telemetry'))!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&q=turn-9')

    fireEvent.click(routeLinks.find(link => link.getAttribute('aria-label')?.includes('telemetry'))!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&q=turn-9')
  })

  it('adds current context route links to the command bar', () => {
    ideContextFocus.value = {
      file_path: 'lib/runtime.ml',
      line: 12,
      surface: 'Goal',
      label: 'Runtime goal',
      source_id: 'event-2',
      activated_at_ms: Date.now(),
      route_links: [{
        id: 'goal:goal-runtime',
        label: 'Goal',
        tab: 'workspace',
        params: { section: 'planning', goal: 'goal-runtime' },
        evidence: 'Goal goal-runtime',
      }],
    }
    container = document.createElement('div')

    render(h(IdeToolbar, {
      activeView: 'source',
      activeLayers: new Set<string>(),
      onViewChange: vi.fn(),
      onLayersChange: vi.fn(),
    }), container)

    const input = container.querySelector('[data-testid="ide-command-bar"] input') as HTMLInputElement
    fireEvent.focus(input)
    fireEvent.input(input, { target: { value: 'goal-runtime' } })

    const command = [...container.querySelectorAll('[role="option"]')]
      .find(option => option.textContent === 'Open context: Goal · goal-runtime')
    expect(command).toBeTruthy()
  })

  it('groups focused context links by operational surface', () => {
    const groups = deriveToolbarContextRouteGroups({
      file_path: 'lib/runtime.ml',
      surface: 'Comment',
      label: 'runtime note',
      source_id: 'event-1',
      activated_at_ms: Date.now(),
      route_links: [
        {
          id: 'comment:comment-1',
          label: 'Comment',
          tab: 'workspace',
          params: { section: 'board', comment: 'comment-1' },
          evidence: 'Comment comment-1',
        },
        {
          id: 'goal:goal-runtime',
          label: 'Goal',
          tab: 'workspace',
          params: { section: 'planning', goal: 'goal-runtime' },
          evidence: 'Goal goal-runtime',
        },
        {
          id: 'log:turn-9',
          label: 'Log',
          tab: 'monitoring',
          params: { section: 'runtime', view: 'audit', log_id: 'turn-9' },
          evidence: 'Log turn-9',
        },
        {
          id: 'git:abc123',
          label: 'Git',
          tab: 'workspace',
          params: { section: 'repositories', view: 'graph', ref: 'abc123' },
          evidence: 'Git abc123',
        },
      ],
    })

    expect(groups.map(group => ({
      id: group.id,
      label: group.label,
      count: group.count,
      evidence: group.evidence,
      routeLinkId: group.routeLink.id,
    }))).toEqual([
      { id: 'planning', label: 'Plan', count: 1, evidence: 'Goal goal-runtime', routeLinkId: 'goal:goal-runtime' },
      { id: 'board', label: 'Board', count: 1, evidence: 'Comment comment-1', routeLinkId: 'comment:comment-1' },
      { id: 'repo', label: 'Repo', count: 1, evidence: 'Git abc123', routeLinkId: 'git:abc123' },
      { id: 'runtime', label: 'Runtime', count: 1, evidence: 'Log turn-9', routeLinkId: 'log:turn-9' },
    ])
  })
})
