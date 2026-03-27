import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { ConfigResolutionPanel } from './config-resolution-panel'

describe('ConfigResolutionPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders resolved paths and warnings', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'warn',
          warnings: ['Using legacy config fallback from ME_ROOT-style path: /tmp/legacy/config'],
          config_root: { path: '/tmp/legacy/config', exists: true, source: 'legacy_me_root' },
          cascade: { path: '/tmp/legacy/config/cascade.json', exists: true, source: 'legacy_me_root' },
          prompts: { path: '/tmp/legacy/config/prompts', exists: true, source: 'legacy_me_root' },
          keepers: { path: '/tmp/legacy/config/keepers', exists: false, source: 'legacy_me_root' },
          personas: { path: '/tmp/custom-personas', exists: false, source: 'invalid_env' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('설정 경로')
    expect(container.textContent).toContain('/tmp/legacy/config')
    expect(container.textContent).toContain('Using legacy config fallback from ME_ROOT-style path')
    expect(container.textContent).toContain('/tmp/custom-personas')
    expect(container.textContent).toContain('INVALID ENV')
  })

  it('renders home config source label', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/home/test/.masc/config', exists: true, source: 'home_masc' },
          cascade: { path: '/home/test/.masc/config/cascade.json', exists: true, source: 'home_masc' },
          prompts: { path: '/home/test/.masc/config/prompts', exists: true, source: 'home_masc' },
          keepers: { path: '/home/test/.masc/config/keepers', exists: true, source: 'home_masc' },
          personas: { path: '/home/test/.masc/config/personas', exists: true, source: 'home_masc' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('HOME')
    expect(container.textContent).toContain('/home/test/.masc/config')
  })
})
