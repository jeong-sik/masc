// @vitest-environment happy-dom
//
// jest-axe coverage for ErrorPanel — dropdown listing unacknowledged
// errors. role="alert" on the wrapper (so AT announces when the
// panel opens with content) and per-row icon-color + domain badge.
// Tests pin the empty state, both severities, and an unmodelled domain.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ErrorPanel } from './error-panel'
import { errors } from './error-notification-state'
import type { DashboardError } from '../../types/error'

function makeError(overrides: Partial<DashboardError> = {}): DashboardError {
  const now = Date.now()
  return {
    id: 'test-id',
    fingerprint: 'fp',
    agentName: 'sigma',
    taskId: null,
    message: 'Test error',
    errorCode: 'exception',
    domain: 'internal',
    severity: 'critical',
    timestamp: now,
    acknowledged: false,
    count: 1,
    lastSeen: now,
    ...overrides,
  }
}

describe('ErrorPanel a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    errors.value = []
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    errors.value = []
  })

  it('empty state passes axe', async () => {
    render(html`<${ErrorPanel} onClose=${() => {}} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('single critical error passes axe', async () => {
    errors.value = [makeError({ severity: 'critical', message: 'Connection refused' })]
    render(html`<${ErrorPanel} onClose=${() => {}} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('mixed severities and an unmodelled domain pass axe', async () => {
    errors.value = [
      makeError({ id: 'a', severity: 'critical', domain: 'internal', errorCode: 'exception', message: 'Boom' }),
      makeError({ id: 'b', severity: 'warning', domain: 'provider', errorCode: 'anthropic:overloaded_error', message: 'Slow down' }),
      makeError({ id: 'c', severity: 'critical', domain: null, errorCode: 'quantum_flux', message: 'Missing' }),
    ]
    render(html`<${ErrorPanel} onClose=${() => {}} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('error with taskId + count > 1 passes axe', async () => {
    errors.value = [makeError({
      taskId: 'task-42',
      count: 3,
      message: 'Repeated timeout',
      errorCode: 'timeout',
      severity: 'warning',
    })]
    render(html`<${ErrorPanel} onClose=${() => {}} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
