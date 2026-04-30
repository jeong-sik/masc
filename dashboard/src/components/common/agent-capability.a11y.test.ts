// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentCapability } from './agent-capability'

describe('AgentCapability a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly with known tools', async () => {
    render(
      html`<${AgentCapability}
        tools=${['file_read', 'shell', 'web_search']}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with overflow', async () => {
    render(
      html`<${AgentCapability}
        tools=${['file_read', 'file_write', 'shell', 'web_search', 'db_query']}
        maxVisible=${2}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for empty tools', async () => {
    render(html`<${AgentCapability} tools=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for null tools', async () => {
    render(html`<${AgentCapability} tools=${null} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for unknown tools (fallback)', async () => {
    render(
      html`<${AgentCapability} tools=${['custom_tool', null, 'another_one']} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with deduplication', async () => {
    render(
      html`<${AgentCapability}
        tools=${['shell', 'shell', '  shell  ', 'web_search']}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
