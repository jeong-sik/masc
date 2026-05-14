import { fireEvent } from '@testing-library/preact'
import { h } from 'preact'
import { render } from 'preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { IdeToolbar } from './ide-toolbar'
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
          id: 'task:task-runtime',
          label: 'Task',
          tab: 'workspace',
          params: { section: 'planning', view: 'default', task: 'task-runtime' },
          evidence: 'Task task-runtime',
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
      .toBe('Current IDE context: Task line 42, task task-runtime, keeper sangsu, 2 route links')
    expect(focus?.textContent).toContain('Task')
    expect(focus?.textContent).toContain('L42')
    expect(focus?.textContent).toContain('task task-runtime')
    expect(focus?.textContent).toContain('keeper sangsu')

    const routeLinks = [...container.querySelectorAll<HTMLButtonElement>('.ide-toolbar-context-links button')]
    expect(routeLinks.map(link => link.textContent)).toEqual(['Task', 'Telemetry'])

    fireEvent.click(routeLinks.find(link => link.textContent === 'Telemetry')!)
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
      .find(option => option.textContent === 'Open context: Goal')
    expect(command).toBeTruthy()
  })
})
