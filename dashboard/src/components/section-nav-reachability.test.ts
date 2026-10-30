// @vitest-environment happy-dom
//
// Reachability, not shape. #27547 counted 23 routable sections with no
// rendered link; the Monitor strip closed 19 of them and left 4, all on the
// two other tabs that carry more than one visible section:
//
//   workspace/verification, lab/performance,
//   lab/keeper-memory-health
//
// Every pure-function test over the section table passed the whole time. The
// registry always knew those sections existed — what was missing was a
// component that turned the registry into links, so these cases render the
// surface a user actually lands on and ask whether they can click their way
// in. Mounting the strip is the assertion; remove it from either surface and
// these fail.
import { cleanup, render, screen, within } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { html } from 'htm/preact'
import { route } from '../router'
import { visibleSectionItemsForTab } from '../config/navigation'
import type { TabId } from '../types'
import { Lab } from './lab'
import { Work } from './work'

afterEach(cleanup)

const SURFACES: Array<{ tab: TabId, name: string, landing: string, Surface: unknown }> = [
  { tab: 'lab', name: 'Lab', landing: 'tools', Surface: Lab },
  { tab: 'workspace', name: 'Work', landing: 'work', Surface: Work },
]

for (const { tab, name, landing, Surface } of SURFACES) {
  describe(`${name} section navigation`, () => {
    function renderAt(section: string) {
      route.value = { tab, params: { section }, postId: null }
      render(html`<${Surface} />`)
      return screen.getByTestId(`section-nav-${tab}`)
    }

    it('renders a link to every visible section', () => {
      const nav = renderAt(landing)
      for (const item of visibleSectionItemsForTab(tab)) {
        expect(within(nav).getByText(item.label)).toBeTruthy()
      }
    })

    // The landing is where clicking the tab puts you. A strip that only
    // rendered on the non-default sections would leave the one screen users
    // arrive at with no way out — the exact shape of the original defect.
    it('renders on the landing section, not only on the others', () => {
      expect(renderAt(landing)).toBeTruthy()
    })

    it('marks the section being viewed as current', () => {
      const items = visibleSectionItemsForTab(tab)
      const target = items.find(item => item.params.section !== landing)
      expect(target).toBeTruthy()
      const section = target?.params.section as string
      const nav = renderAt(section)
      const active = within(nav).getByText(target?.label as string).closest('a')
      expect(active?.getAttribute('aria-current')).toBe('page')
    })
  })
}

// Named rather than derived: the point is that these four specific sections
// were unreachable, and a loop over the registry would keep passing if one of
// them were quietly dropped from it.
describe('sections that #27547 left unreachable', () => {
  const ORPHANS: Array<[TabId, string, string, unknown]> = [
    ['workspace', 'verification', 'work', Work],
    ['lab', 'performance', 'tools', Lab],
    ['lab', 'keeper-memory-health', 'tools', Lab],
  ]

  for (const [tab, section, landing, Surface] of ORPHANS) {
    it(`links to ${tab}/${section} from the landing`, () => {
      route.value = { tab, params: { section: landing }, postId: null }
      render(html`<${Surface} />`)
      const nav = screen.getByTestId(`section-nav-${tab}`)
      const item = visibleSectionItemsForTab(tab)
        .find(entry => entry.params.section === section)
      expect(item).toBeTruthy()
      const link = within(nav).getByText(item?.label as string).closest('a')
      expect(link).toBeTruthy()
      expect(link?.getAttribute('href')).toContain(`section=${section}`)
    })
  }
})
