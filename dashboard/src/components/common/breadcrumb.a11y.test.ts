// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Breadcrumb } from './breadcrumb'

describe('Breadcrumb a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('link trail passes axe', async () => {
    render(
      html`<${Breadcrumb}
        items=${[
          { label: 'Command', href: '#command' },
          { label: 'Operations' },
        ]}
      />`,
      container,
    )

    expect(await axe(container)).toHaveNoViolations()
  })

  it('button trail passes axe', async () => {
    render(
      html`<${Breadcrumb}
        items=${[
          { label: 'Connectors', onClick: () => {} },
          { label: 'Discord' },
        ]}
      />`,
      container,
    )

    expect(await axe(container)).toHaveNoViolations()
  })

  it('marks the current item for screen readers', () => {
    render(
      html`<${Breadcrumb}
        items=${[
          { label: 'Cockpit', href: '#cockpit' },
          { label: 'Fleet' },
        ]}
      />`,
      container,
    )

    expect(container.querySelector('[aria-current="page"]')?.textContent).toBe('Fleet')
  })
})
