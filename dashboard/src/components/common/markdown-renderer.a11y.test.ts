// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { MarkdownContent } from './markdown-renderer'

describe('MarkdownContent a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders plain text accessibly', async () => {
    render(html`<${MarkdownContent} text="Hello world" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders heading accessibly', async () => {
    render(html`<${MarkdownContent} text="# Title" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders link with target and rel', async () => {
    render(html`<${MarkdownContent} text="[link](https://example.com)" />`, container)
    const anchor = container.querySelector('a')
    expect(anchor).not.toBeNull()
    expect(anchor?.getAttribute('target')).toBe('_blank')
    expect(anchor?.getAttribute('rel')).toBe('noopener noreferrer')
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders list accessibly', async () => {
    render(html`<${MarkdownContent} text="- one\n- two" />`, container)
    const ul = container.querySelector('ul')
    expect(ul).not.toBeNull()
    expect(ul?.querySelectorAll('li').length).toBe(2)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders table accessibly', async () => {
    render(html`<${MarkdownContent} text="| A | B |\n|---|---|\n| 1 | 2 |" />`, container)
    const table = container.querySelector('table')
    expect(table).not.toBeNull()
    expect(await axe(container)).toHaveNoViolations()
  })

  it('sanitizes script tags', async () => {
    render(html`<${MarkdownContent} text="<script>alert(1)</script>safe" />`, container)
    expect(container.querySelector('script')).toBeNull()
    expect(container.textContent).toContain('safe')
  })

  it('renders think block as details/summary', async () => {
    render(html`<${MarkdownContent} text="<think>hidden thought</think>" />`, container)
    const details = container.querySelector('details')
    expect(details).not.toBeNull()
    expect(details?.querySelector('summary')).not.toBeNull()
  })
})
