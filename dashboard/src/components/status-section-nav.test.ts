// @vitest-environment happy-dom
//
// Reachability, not shape. Every Monitor section was already routable and
// every pure-function test over the section table passed, while no rendered
// link to 'internal-agents' existed anywhere in the app — the nav that drew
// section sublists was declared and never mounted. These cases render the
// surface and ask whether a user can click their way in.
import { cleanup, render, screen, within } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { html } from 'htm/preact'
import { route } from '../router'
import { visibleSectionItemsForTab } from '../config/navigation'
import { Status } from './status'

afterEach(cleanup)

function renderAt(section: string) {
  route.value = { tab: 'monitoring', params: { section }, postId: null }
  render(html`<${Status} />`)
  return screen.getByTestId('section-nav-monitoring')
}

describe('Monitor section navigation', () => {
  it('renders a link to every visible Monitor section', () => {
    const nav = renderAt('internal-agents')
    for (const item of visibleSectionItemsForTab('monitoring')) {
      expect(within(nav).getByText(item.label)).toBeTruthy()
    }
  })

  // The regression this fixes: 'internal-agents' carries librarian and judge
  // runs and had no rendered link, so it was reachable only by typing the hash.
  it('links to internal-agents with the section param the router expects', () => {
    const nav = renderAt('agents')
    const link = within(nav).getByText('Internal Agents').closest('a')
    expect(link).toBeTruthy()
    expect(link?.getAttribute('href')).toContain('section=internal-agents')
  })

  // 'agents' is where clicking Monitor lands, and that branch returns before
  // SurfaceHeader. A strip mounted in the header would be absent exactly here.
  it('renders on the agents landing, not only on the other sections', () => {
    expect(renderAt('agents')).toBeTruthy()
  })

  it('marks the section being viewed as current', () => {
    const nav = renderAt('runtime')
    const current = within(nav).getByText('Runtime').closest('a')
    expect(current?.getAttribute('aria-current')).toBe('page')
    const other = within(nav).getByText('Internal Agents').closest('a')
    expect(other?.getAttribute('aria-current')).toBeNull()
  })
})
