import { h, render } from 'preact'
import { beforeEach, describe, expect, it } from 'vitest'
import {
  AgentFailure,
  failureConfig,
  failureTypeFromDiagnostic,
  summarizeAgentFailure,
} from './agent-failure'

describe('AgentFailure typed states', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  it('uses blocked for an observed error without reading recoverability', () => {
    expect(failureTypeFromDiagnostic('err')).toBe('blocked')
    expect(failureTypeFromDiagnostic(null)).toBe('degraded')
  })

  it('summarizes the three operator states', () => {
    expect(summarizeAgentFailure('blocked').status).toBe('blocked')
    expect(summarizeAgentFailure('human_required').status).toBe('waiting_for_human')
    expect(summarizeAgentFailure('degraded').status).toBe('degraded')
    expect(failureConfig('blocked').label).toBe('진행 차단')
  })

  it('renders typed data attributes and no local attempt budget', () => {
    render(h(AgentFailure, { type: 'blocked', message: 'failed', testId: 'failure' }), container)
    const element = container.querySelector('[data-testid="failure"]')
    expect(element?.getAttribute('data-failure-type')).toBe('blocked')
    expect(element?.getAttribute('data-agent-failure-status')).toBe('blocked')
    expect(element?.getAttribute('data-agent-failure-retry-visible')).toBeNull()
  })
})
