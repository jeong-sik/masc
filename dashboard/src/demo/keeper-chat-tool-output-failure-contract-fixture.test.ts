import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import {
  COVERAGE_GAP_COVERED_THROUGH_MS,
  COVERAGE_GAP_ORDER_SIGNATURE,
  HYDRATION_FAILED_ORDER_SIGNATURE,
  TOOL_OUTPUT_FAILURE_REASON,
  ToolOutputFailureContractFixture,
  coverageGapEntries,
  coverageGapToolCount,
  hydrationFailedEntries,
  hydrationFailedToolCount,
  installToolOutputFailureFixtureStore,
  toolOutputFailureFixtureStatus,
} from './keeper-chat-tool-output-failure-contract-fixture'
import { resetToolCallOutputs } from '../tool-call-output-store'

describe('Keeper Chat tool output failure contract fixture', () => {
  let container: HTMLDivElement | null = null

  afterEach(() => {
    if (container) {
      render(null, container)
      container.remove()
      container = null
    }
    resetToolCallOutputs()
  })

  it('keeps deterministic failure-state fixture rows', () => {
    expect(hydrationFailedEntries).toHaveLength(2)
    expect(coverageGapEntries).toHaveLength(2)
    expect(hydrationFailedToolCount).toBe(1)
    expect(coverageGapToolCount).toBe(1)
    expect(toolOutputFailureFixtureStatus).toBe('ok')

    const hydrationAssistant = hydrationFailedEntries.find(entry => entry.id === 'assistant-hydration-failed')
    const coverageAssistant = coverageGapEntries.find(entry => entry.id === 'assistant-coverage-gap')
    expect(hydrationAssistant?.traceSteps?.map(step => step.kind)).toEqual(['tool'])
    expect(coverageAssistant?.traceSteps?.map(step => step.kind)).toEqual(['tool'])
    const hydrationToolStep = hydrationAssistant?.traceSteps?.find(step => step.kind === 'tool')
    const coverageToolStep = coverageAssistant?.traceSteps?.find(step => step.kind === 'tool')
    expect(hydrationToolStep?.toolCallId).toBe('tc-hydration-failed')
    expect(coverageToolStep?.toolCallId).toBe('tc-coverage-gap')
  })

  it('renders hydration-failed and coverage-gap states without silent pending fallback', () => {
    container = document.createElement('div')
    document.body.append(container)
    installToolOutputFailureFixtureStore()

    render(html`<${ToolOutputFailureContractFixture} />`, container)

    expect(
      container.querySelector(
        '[data-tool-output-failure-contract-fixture-status="ok"][data-tool-output-failure-hydration-failed-count="1"][data-tool-output-failure-coverage-gap-count="1"]',
      ),
    ).not.toBeNull()

    const hydrationScenario = container.querySelector(
      '[data-tool-output-failure-scenario="hydration-failed"]',
    ) as HTMLElement | null
    const hydrationTrace = hydrationScenario?.querySelector('[data-chat-work-trace]') as HTMLElement | null
    expect(hydrationTrace?.getAttribute('data-chat-turn-order-signature')).toBe(HYDRATION_FAILED_ORDER_SIGNATURE)
    expect(hydrationTrace?.getAttribute('data-chat-tool-output-hydration-source')).toBe('tool_calls_endpoint')
    expect(hydrationTrace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('failed')
    expect(hydrationTrace?.getAttribute('data-chat-tool-output-hydration-failure')).toBe(TOOL_OUTPUT_FAILURE_REASON)
    expect(hydrationScenario?.textContent).toContain('출력 hydration 실패 1')

    const hydrationTool = hydrationScenario?.querySelector('[data-chat-trace-step="tool"]') as HTMLElement | null
    expect(hydrationTool?.getAttribute('data-chat-turn-order-index')).toBe('0')
    expect(hydrationTool?.getAttribute('data-chat-turn-order-kind')).toBe('tool')
    expect(hydrationTool?.getAttribute('data-chat-trace-tool-call-id')).toBe('tc-hydration-failed')
    expect(hydrationTool?.getAttribute('data-chat-trace-entry-id')).toBe('tool-tc-hydration-failed')
    expect(hydrationTool?.getAttribute('data-chat-trace-link-state')).toBe('joined')
    expect(hydrationTool?.getAttribute('data-chat-trace-output-state')).toBe('hydration-failed')
    expect(hydrationTool?.getAttribute('data-chat-trace-output-coverage')).toBe('hydration-failed')
    expect(hydrationTool?.querySelector('.chat-block-tstep-status.hydration-failed')).not.toBeNull()
    expect(hydrationTool?.querySelector('.chat-block-tstep-status.pending')).toBeNull()

    const hydrationToolRow = hydrationTool?.querySelector('.chat-block-tstep-row') as HTMLElement | null
    expect(hydrationToolRow).not.toBeNull()
    if (!hydrationToolRow) {
      throw new Error('expected hydration failure tool row')
    }
    fireEvent.click(hydrationToolRow)
    expect(hydrationTool?.textContent).toContain(`출력 hydration 실패 — ${TOOL_OUTPUT_FAILURE_REASON}`)

    const coverageScenario = container.querySelector(
      '[data-tool-output-failure-scenario="coverage-gap"]',
    ) as HTMLElement | null
    const coverageTrace = coverageScenario?.querySelector('[data-chat-work-trace]') as HTMLElement | null
    expect(coverageTrace?.getAttribute('data-chat-turn-order-signature')).toBe(COVERAGE_GAP_ORDER_SIGNATURE)
    expect(coverageTrace?.getAttribute('data-chat-tool-output-hydration-source')).toBe('tool_calls_endpoint')
    expect(coverageTrace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('hydrated')
    expect(coverageTrace?.getAttribute('data-chat-tool-output-covered-through')).toBe(String(COVERAGE_GAP_COVERED_THROUGH_MS))
    expect(coverageScenario?.textContent).toContain('출력 범위 밖 1')

    const coverageTool = coverageScenario?.querySelector('[data-chat-trace-step="tool"]') as HTMLElement | null
    expect(coverageTool?.getAttribute('data-chat-turn-order-index')).toBe('0')
    expect(coverageTool?.getAttribute('data-chat-turn-order-kind')).toBe('tool')
    expect(coverageTool?.getAttribute('data-chat-trace-tool-call-id')).toBe('tc-coverage-gap')
    expect(coverageTool?.getAttribute('data-chat-trace-entry-id')).toBe('tool-tc-coverage-gap')
    expect(coverageTool?.getAttribute('data-chat-trace-link-state')).toBe('joined')
    expect(coverageTool?.getAttribute('data-chat-trace-output-state')).toBe('coverage-gap')
    expect(coverageTool?.getAttribute('data-chat-trace-output-coverage')).toBe('coverage-gap')
    expect(coverageTool?.querySelector('.chat-block-tstep-status.coverage-gap')).not.toBeNull()
    expect(coverageTool?.querySelector('.chat-block-tstep-status.pending')).toBeNull()
    expect(coverageTool?.querySelector('.chat-block-tstep-status.missing')).toBeNull()

    const coverageToolRow = coverageTool?.querySelector('.chat-block-tstep-row') as HTMLElement | null
    expect(coverageToolRow).not.toBeNull()
    if (!coverageToolRow) {
      throw new Error('expected coverage gap tool row')
    }
    fireEvent.click(coverageToolRow)
    expect(coverageTool?.textContent).toContain('출력 tail 범위 밖')
  })
})
