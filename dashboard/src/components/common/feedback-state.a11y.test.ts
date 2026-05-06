// @vitest-environment happy-dom
//
// jest-axe coverage for FeedbackState primitives. EmptyState renders
// `role="status"` so axe verifies the live-region attribute is on a
// proper container; ErrorState/Recoverable/Fatal carry retry/reload
// buttons whose accessible names this test pins.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import {
  EmptyState,
  LoadingState,
  ErrorState,
  ErrorRecoverable,
  ErrorFatal,
} from './feedback-state'

describe('EmptyState a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default render passes axe', async () => {
    render(html`<${EmptyState} message="No items yet" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('compact + icon passes axe (icon is aria-hidden, message is text)', async () => {
    render(
      html`<${EmptyState} icon="📭" message="Inbox is empty" compact=${true} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

describe('LoadingState a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly with default content', async () => {
    render(html`<${LoadingState}>로딩 중<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})

describe('ErrorState a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('with message passes axe', async () => {
    render(
      html`<${ErrorState} message="Network unavailable" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

describe('ErrorRecoverable a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('with retry callback passes axe', async () => {
    render(
      html`<${ErrorRecoverable}
        title="Sync failed"
        onRetry=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

describe('ErrorFatal a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('with reload callback passes axe', async () => {
    render(
      html`<${ErrorFatal}
        title="Session expired"
        onReload=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
