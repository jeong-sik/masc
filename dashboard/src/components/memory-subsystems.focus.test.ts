// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { MemorySubsystemsResponse } from '../api/dashboard'
import { MemorySubsystems } from './memory-subsystems'

const baseResponse: MemorySubsystemsResponse = {
  generated_at: '2026-05-13T00:00:00Z',
  hebbian: {
    synapses: [],
    last_consolidation: 0,
  },
  episodes: {
    total: 1,
    filtered: 1,
    shown: 1,
    limit: 100,
    items: [
      {
        id: 'episode-1',
        timestamp: 1,
        participants: ['keeper-alpha'],
        event_type: 'task_done',
        summary: 'Finished a task',
        outcome: 'success',
        learnings: ['ship focused changes'],
        context: {},
      },
    ],
  },
  memory_entries: {
    total: 1,
    filtered: 1,
    shown: 1,
    limit: 100,
    items: [
      {
        keeper: 'keeper-alpha',
        kind: 'verified',
        text: 'PR review addressed',
        priority: 90,
        ts_unix: 1,
      },
    ],
  },
  user_model: {
    schema: 'masc.user_model.memory_projection.v1',
    source: 'memory_os_facts',
    prompt: {
      enabled: true,
      block_id: 'user_model',
      injection: 'extra_system_context',
      runtime_hook: 'keeper_run_tools_hooks.before_turn_params',
      producer: 'keeper_user_model',
    },
    total: 2,
    filtered: 2,
    shown: 2,
    limit: 100,
    items: [
      {
        keeper: 'keeper-alpha',
        kind: 'preference',
        claim: 'User prefers terse operational summaries',
        source_ref: 'memory-os-fact://keeper-alpha/trace-1/user-prefers-terse-operational-summaries',
        source_trace_id: 'trace-1',
        source_turn: 7,
        first_seen: 1,
        last_verified_at: 2,
        observed_by: [],
      },
      {
        keeper: 'keeper-alpha',
        kind: 'constraint',
        claim: 'Use worktrees for repo changes',
        source_ref: 'memory-os-fact://keeper-alpha/trace-2/use-worktrees-for-repo-changes',
        source_trace_id: 'trace-2',
        source_turn: 8,
        first_seen: 1,
        last_verified_at: null,
        observed_by: [],
      },
    ],
    errors: [],
  },
  draft_skill_candidates: {
    total: 1,
    shown: 1,
    limit: 100,
    index_path: '<base-path>/.masc/draft-skills/index.jsonl',
    items: [
      {
        id: 'skill-candidate-repeatable-debug-loop',
        agent_name: 'keeper-alpha',
        source_kind: 'procedure',
        source_ref: 'procedure://keeper-alpha/repeatable-debug-loop',
        promotion_state: 'candidate',
        dir: '<base-path>/.masc/draft-skills/skill-candidate-repeatable-debug-loop',
        json_path: '<base-path>/.masc/draft-skills/skill-candidate-repeatable-debug-loop/candidate.json',
        toml_path: '<base-path>/.masc/draft-skills/skill-candidate-repeatable-debug-loop/candidate.toml',
        skill_md_path: '<base-path>/.masc/draft-skills/skill-candidate-repeatable-debug-loop/SKILL.md',
        created_at: 1,
      },
    ],
    error: null,
  },
  filters: {
    keepers: ['keeper-alpha'],
    outcomes: ['success'],
    memory_kinds: ['verified'],
  },
}

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('MemorySubsystems focus targets', () => {
  let container: HTMLDivElement
  let originalScrollIntoView: typeof HTMLElement.prototype.scrollIntoView | undefined
  let originalFocus: typeof HTMLElement.prototype.focus | undefined
  let scrollIntoViewMock: ReturnType<typeof vi.fn>
  let focusMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    originalScrollIntoView = HTMLElement.prototype.scrollIntoView
    originalFocus = HTMLElement.prototype.focus
    scrollIntoViewMock = vi.fn()
    focusMock = vi.fn()
    Object.defineProperty(HTMLElement.prototype, 'scrollIntoView', {
      configurable: true,
      value: scrollIntoViewMock,
    })
    Object.defineProperty(HTMLElement.prototype, 'focus', {
      configurable: true,
      value: focusMock,
    })
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    if (originalScrollIntoView) {
      Object.defineProperty(HTMLElement.prototype, 'scrollIntoView', {
        configurable: true,
        value: originalScrollIntoView,
      })
    } else {
      Reflect.deleteProperty(HTMLElement.prototype, 'scrollIntoView')
    }
    if (originalFocus) {
      Object.defineProperty(HTMLElement.prototype, 'focus', {
        configurable: true,
        value: originalFocus,
      })
    } else {
      Reflect.deleteProperty(HTMLElement.prototype, 'focus')
    }
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('requests sensitive memory entries and focuses that section for entries focus', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(baseResponse))
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} focus=${'entries'} />`, container)

    await vi.waitFor(() => {
      const requestUrls = fetchMock.mock.calls.map(call =>
        new URL(call[0] as string, 'http://dashboard.local'),
      )
      expect(requestUrls.some(url => url.searchParams.get('include_memory_entries') === 'true')).toBe(true)
    })
    await vi.waitFor(() => {
      expect(container.textContent).toContain('PR review addressed')
    })

    const target = container.querySelector('[data-memory-focus-target="entries"]')
    expect(target).not.toBeNull()
    expect(container.querySelector('[data-testid="memory-entries"]')).not.toBeNull()
    await vi.waitFor(() => {
      expect(focusMock.mock.contexts).toContain(target)
      expect(scrollIntoViewMock.mock.contexts).toContain(target)
    })
  })

  it('renders user model projection rows from memory facts', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(baseResponse))
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} />`, container)

    await vi.waitFor(() => {
      expect(container.textContent).toContain('User model')
      expect(container.textContent).toContain('prompt on · user_model')
      expect(container.textContent).toContain('User prefers terse operational summaries')
      expect(container.textContent).toContain('Use worktrees for repo changes')
    })
    expect(container.querySelector('[data-testid="user-model-projection"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="user-model-prompt-surface"]')).not.toBeNull()
  })

  it('renders draft skill candidates from the memory subsystem payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(baseResponse))
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} />`, container)

    await vi.waitFor(() => {
      expect(container.textContent).toContain('skill-candidate-repeatable-debug-loop')
      expect(container.textContent).toContain('candidate')
      expect(container.textContent).toContain('<base-path>/.masc/draft-skills/skill-candidate-repeatable-debug-loop/SKILL.md')
    })
    expect(container.querySelector('[data-testid="draft-skill-candidates"]')).not.toBeNull()
  })

  it('renders draft skill candidate empty and error states', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse({
        ...baseResponse,
        draft_skill_candidates: {
          total: 0,
          shown: 0,
          limit: 100,
          index_path: '<base-path>/.masc/draft-skills/index.jsonl',
          items: [],
          error: 'draft skill index read failed',
        },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} />`, container)

    await vi.waitFor(() => {
      expect(container.querySelector('[data-testid="draft-skill-candidates"]')).not.toBeNull()
      expect(container.querySelector('[role="alert"]')?.textContent).toContain(
        'draft skill index read failed',
      )
      expect(container.textContent).toContain('draft skill 후보 없음')
      expect(container.textContent).toContain('total 0 · shown 0')
    })
  })

  it('renders non-candidate draft skill states with nullable creation time', async () => {
    const original = baseResponse.draft_skill_candidates!.items[0]!
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse({
        ...baseResponse,
        draft_skill_candidates: {
          ...baseResponse.draft_skill_candidates!,
          total: 2,
          shown: 2,
          items: [
            {
              ...original,
              id: 'skill-promoted-debug-loop',
              promotion_state: 'promoted',
              skill_md_path: '<base-path>/.masc/skills/debug-loop/SKILL.md',
              created_at: null,
            },
            {
              ...original,
              id: 'skill-rejected-debug-loop',
              promotion_state: 'rejected',
              skill_md_path: '<base-path>/.masc/draft-skills/rejected/SKILL.md',
              created_at: null,
            },
          ],
        },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} />`, container)

    await vi.waitFor(() => {
      expect(container.textContent).toContain('skill-promoted-debug-loop')
      expect(container.textContent).toContain('promoted')
      expect(container.textContent).toContain('skill-rejected-debug-loop')
      expect(container.textContent).toContain('rejected')
      expect(container.textContent).toContain('<base-path>/.masc/skills/debug-loop/SKILL.md')
    })
  })

  it('focuses the episodes section without requesting memory entries for episodes focus', async () => {
    const responseWithoutEntries: MemorySubsystemsResponse = {
      ...baseResponse,
      memory_entries: undefined,
      filters: {
        keepers: ['keeper-alpha'],
        outcomes: ['success'],
      },
    }
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(responseWithoutEntries))
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} focus=${'episodes'} />`, container)

    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalled()
      const requestUrls = fetchMock.mock.calls.map(call =>
        new URL(call[0] as string, 'http://dashboard.local'),
      )
      expect(requestUrls.some(url => url.searchParams.has('include_memory_entries'))).toBe(false)
    })
    await vi.waitFor(() => {
      expect(container.textContent).toContain('Finished a task')
    })

    const target = container.querySelector('[data-memory-focus-target="episodes"]')
    expect(target).not.toBeNull()
    expect(container.querySelector('[data-memory-focus-target="entries"]')).toBeNull()
    await vi.waitFor(() => {
      expect(focusMock.mock.contexts).toContain(target)
      expect(scrollIntoViewMock.mock.contexts).toContain(target)
    })
  })

  it('does not show the entries panel from an unrequested empty memory_entries payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({
      ...baseResponse,
      memory_entries: {
        total: 0,
        filtered: 0,
        shown: 0,
        limit: 100,
        items: [],
      },
    }))
    vi.stubGlobal('fetch', fetchMock)

    render(html`<${MemorySubsystems} />`, container)

    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalled()
      const requestUrls = fetchMock.mock.calls.map(call =>
        new URL(call[0] as string, 'http://dashboard.local'),
      )
      expect(requestUrls.some(url => url.searchParams.has('include_memory_entries'))).toBe(false)
    })
    await vi.waitFor(() => {
      expect(container.textContent).toContain('Finished a task')
    })

    expect(container.querySelector('[data-memory-focus-target="entries"]')).toBeNull()
    expect(container.querySelector('[data-testid="memory-entries"]')).toBeNull()
  })
})
