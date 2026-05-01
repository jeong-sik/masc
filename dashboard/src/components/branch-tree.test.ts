import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { BranchTree } from './branch-tree'

describe('BranchTree', () => {
  const makeContainer = () => document.createElement('div')

  it('renders empty state when branches is empty', () => {
    const container = makeContainer()
    render(html`<${BranchTree} repository_id="r1" branches=${[]} />`, container)
    expect(container.textContent).toContain('브랜치가 없습니다')
  })

  it('renders branch count in header', () => {
    const container = makeContainer()
    render(html`<${BranchTree} repository_id="r1" branches=${['main', 'dev']} />`, container)
    expect(container.textContent).toContain('2개')
  })

  it('puts default branch first in sorted list', () => {
    const container = makeContainer()
    render(
      html`<${BranchTree} repository_id="r1" branches=${['dev', 'main', 'feature']} default_branch="main" />`,
      container,
    )
    const items = container.querySelectorAll('li')
    expect(items.length).toBe(3)
    expect(items[0]!.textContent).toContain('main')
  })

  it('marks default branch with 기본 label', () => {
    const container = makeContainer()
    render(
      html`<${BranchTree} repository_id="r1" branches=${['main']} default_branch="main" />`,
      container,
    )
    expect(container.textContent).toContain('기본')
  })

  it('does not mark non-default branches with 기본 label', () => {
    const container = makeContainer()
    render(
      html`<${BranchTree} repository_id="r1" branches=${['dev']} default_branch="main" />`,
      container,
    )
    expect(container.textContent).not.toContain('기본')
  })

  it('sets data-repo-id attribute on wrapper', () => {
    const container = makeContainer()
    render(html`<${BranchTree} repository_id="repo-42" branches=${['main']} />`, container)
    const wrapper = container.querySelector('[data-repo-id]')
    expect(wrapper).not.toBeNull()
    expect(wrapper!.getAttribute('data-repo-id')).toBe('repo-42')
  })

  it('sorts non-default branches alphabetically', () => {
    const container = makeContainer()
    render(
      html`<${BranchTree} repository_id="r1" branches=${['zebra', 'apple', 'main']} default_branch="main" />`,
      container,
    )
    const items = container.querySelectorAll('li')
    expect(items.length).toBe(3)
    expect(items[0]!.textContent).toContain('main')
    expect(items[1]!.textContent).toContain('apple')
    expect(items[2]!.textContent).toContain('zebra')
  })
})
