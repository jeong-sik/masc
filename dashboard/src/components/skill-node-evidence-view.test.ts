import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { SkillExecutorSettlement } from '../api/dashboard-skills'
import { SkillNodeEvidenceView } from './skill-node-evidence-view'

afterEach(cleanup)

function settlement(): SkillExecutorSettlement {
  return {
    node_id: 'selected-node', execution_id: 'executor-1', execution_origin: 'retained_completion',
    tool_name: 'read', input: { path: 'kept.txt', offset: 0, optional: null, enabled: false },
    schedule: { planned_index: 2, batch_index: 1, batch_size: 2, execution_mode: 'concurrent' },
    result: { disposition: 'completed', tool_name: 'read', duration_ms: 0, data: '' },
    tool_use_id: 'read-1', failure_effect_disposition: null, deferred_kind: null,
    result_bytes: 273, truncated_to: 0,
  }
}

describe('retained node evidence', () => {
  it('keeps exact input and result available when the aggregate only exports a summary', async () => {
    const node = settlement()
    const view = render(html`<${SkillNodeEvidenceView} nodes=${[node]} />`)
    const detail = view.container.querySelector('details')!
    expect(view.container.querySelectorAll('pre')).toHaveLength(0)
    detail.open = true
    fireEvent(detail, new Event('toggle'))
    await waitFor(() => expect(view.container.querySelectorAll('pre')).toHaveLength(2))
    const originals = [...view.container.querySelectorAll('pre')].map(pre => JSON.parse(pre.textContent!))
    expect(originals).toEqual([node.input, node.result])
    expect(view.container.textContent).toContain('Truncated to 0 bytes')
    expect(view.container.textContent).toContain('273')
    expect(view.container.textContent).toContain('Retained completion')
  })

  it('preserves failure evidence rather than projecting it as a successful output', async () => {
    const node: SkillExecutorSettlement = {
      ...settlement(), execution_origin: 'dispatch_refused', failure_effect_disposition: 'proven_pre_effect',
      truncated_to: null,
      result: {
        disposition: 'failed', tool_name: 'read', duration_ms: 0.125, data: null,
        effect_disposition: 'proven_pre_effect', failure_class: 'policy_rejection', message: 'Read denied',
      },
    }
    const view = render(html`<${SkillNodeEvidenceView} nodes=${[node]} />`)
    const detail = view.container.querySelector('details')!
    detail.open = true
    fireEvent(detail, new Event('toggle'))
    await waitFor(() => expect(view.container.querySelectorAll('pre')).toHaveLength(2))
    expect(JSON.parse(view.container.querySelectorAll('pre')[1]!.textContent!)).toEqual(node.result)
    expect(view.container.textContent).toContain('Dispatch refused')
    expect(view.container.textContent).toContain('No truncation recorded')
  })
})
