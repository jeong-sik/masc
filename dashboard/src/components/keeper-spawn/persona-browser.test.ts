import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'

vi.mock('../../store', () => ({
  shellAuthSummary: { value: null },
}))

vi.mock('../../lib/dashboard-auth-access', () => ({
  dashboardAuthAccess: () => ({
    allowed: true,
    required_role: 'worker',
    effective_role: 'worker',
    reason: null,
  }),
}))

// Mutable signal-backed mock of the spawn store so each test can flip
// loading / error / list states before rendering. Hoisted because vi.mock
// factories run before module-level variable initialization.
const personasMock = await vi.hoisted(async () => {
  const { signal } = await import('@preact/signals')
  return {
    personas: signal<Array<{
      persona_name: string
      display_name: string
      role: string | null
      trait: string | null
      profile_path: string
      has_keeper_defaults: boolean
    }>>([]),
    personasLoading: signal(false),
    personasError: signal<string | null>(null),
    loadPersonas: vi.fn(async () => {}),
    spawnKeeperFromPersona: vi.fn(async () => {}),
    spawning: signal(false),
    spawnResult: signal<{ success: boolean; message: string } | null>(null),
    showCreateForm: signal(false),
    editingPersona: signal<unknown>(null),
    deletePersona: vi.fn(async () => {}),
  }
})

vi.mock('./keeper-spawn-state', () => personasMock)

vi.mock('./persona-form', () => ({
  PersonaForm: () => html`<div data-testid="persona-form-stub"></div>`,
}))

import { filterPersonas, PersonaBrowser } from './persona-browser'
import type { PersonaSummary } from './keeper-spawn-state'

function persona(
  persona_name: string,
  display_name: string,
  role: string | null,
  trait: string | null,
): PersonaSummary {
  return {
    persona_name,
    display_name,
    role,
    trait,
    profile_path: `/personas/${persona_name}/profile.json`,
    has_keeper_defaults: false,
  }
}

const sample: PersonaSummary[] = [
  persona('analyst', 'Analyst', 'analysis', 'inspects harness metrics'),
  persona('executor', 'Executor', 'action', 'runs code edits'),
  persona('scholar', 'Scholar', 'research', 'reads papers and memory'),
  persona('verifier', 'Verifier', 'guard', 'validates outputs'),
  persona('uranium666', 'Uranium 666', 'lab', 'experimental sandbox persona'),
  persona('bare-persona', 'Bare Persona', null, null),
]

describe('filterPersonas', () => {
  it('returns the input reference when query is empty', () => {
    expect(filterPersonas(sample, '')).toBe(sample)
    expect(filterPersonas(sample, '   ')).toBe(sample)
  })

  it('matches case-insensitive substring on name', () => {
    const out = filterPersonas(sample, 'URANIUM')
    expect(out.map(p => p.persona_name)).toEqual(['uranium666'])
  })

  it('matches on display_name', () => {
    const out = filterPersonas(sample, 'Scholar')
    expect(out.map(p => p.persona_name)).toEqual(['scholar'])
  })

  it('matches on role', () => {
    const out = filterPersonas(sample, 'research')
    expect(out.map(p => p.persona_name)).toEqual(['scholar'])
  })

  it('matches on trait', () => {
    const out = filterPersonas(sample, 'papers')
    expect(out.map(p => p.persona_name)).toEqual(['scholar'])
  })

  it('trims surrounding whitespace before matching', () => {
    const out = filterPersonas(sample, '  action  ')
    expect(out.map(p => p.persona_name)).toEqual(['executor'])
  })

  it('returns empty array when nothing matches', () => {
    expect(filterPersonas(sample, 'no-such-token-xyz')).toEqual([])
  })

  it('matches entries whose nullable fields are absent', () => {
    const out = filterPersonas(sample, 'bare')
    expect(out.map(p => p.persona_name)).toEqual(['bare-persona'])
  })

  it('does not mutate the input array', () => {
    const snapshot = sample.slice()
    filterPersonas(sample, 'analyst')
    expect(sample).toEqual(snapshot)
  })

  it('returns a fresh array (not the input) when filtering narrows rows', () => {
    const out = filterPersonas(sample, 'analysis')
    expect(out).not.toBe(sample)
    expect(out.length).toBeLessThan(sample.length)
  })
})

describe('PersonaBrowser create UI availability', () => {
  let host: HTMLElement

  beforeEach(() => {
    host = document.createElement('div')
    personasMock.personas.value = []
    personasMock.personasLoading.value = false
    personasMock.personasError.value = null
    personasMock.showCreateForm.value = false
    personasMock.editingPersona.value = null
    personasMock.spawnResult.value = null
  })

  afterEach(() => {
    render(null, host)
  })

  function expectCreateUiVisible() {
    expect(host.textContent).toContain('+ 새 페르소나')
    expect(host.querySelector('[data-testid="persona-form-stub"]')).not.toBeNull()
    expect(host.querySelector('input[type="search"]')).not.toBeNull()
  }

  it('always renders the create UI when the persona list is empty', () => {
    render(html`<${PersonaBrowser} />`, host)
    expectCreateUiVisible()
    expect(host.textContent).toContain('등록된 페르소나가 없습니다.')
  })

  it('always renders the create UI when the persona list errors', () => {
    personasMock.personasError.value = 'fetch failed'
    render(html`<${PersonaBrowser} />`, host)
    expectCreateUiVisible()
    expect(host.textContent).toContain('fetch failed')
    expect(host.textContent).toContain('재시도')
  })

  it('always renders the create UI while loading', () => {
    personasMock.personasLoading.value = true
    render(html`<${PersonaBrowser} />`, host)
    expectCreateUiVisible()
    expect(host.textContent).toContain('페르소나 로딩 중')
  })

  it('renders persona cards alongside the create UI on success', () => {
    personasMock.personas.value = [persona('analyst', 'Analyst', 'analysis', 'x')]
    render(html`<${PersonaBrowser} />`, host)
    expectCreateUiVisible()
    expect(host.textContent).toContain('Analyst')
  })
})
