import { describe, expect, it } from 'vitest'
import { accountLine } from './quotas-tab'

describe('accountLine', () => {
  it('joins the email and the plan labels the client reported', () => {
    expect(accountLine({ integration_id: 'codex_a', state: 'read', email: 'a@example.com', plan: ['promax'] }))
      .toBe('a@example.com · promax')
  })
  it('shows only the email when the client reports no plan', () => {
    expect(accountLine({ integration_id: 'agy', state: 'read', email: 'g@example.com', plan: [] }))
      .toBe('g@example.com')
  })
  it('shows the email when the inventory omits the plan field', () => {
    expect(accountLine({ integration_id: 'codex_a', state: 'read', email: 'a@example.com' }))
      .toBe('a@example.com')
  })
  it('names the cause when the login file was not read', () => {
    expect(accountLine({ integration_id: 'claude', state: 'not_read', cause: 'environment_credential' }))
      .toBe('계정 미확인 (environment_credential)')
  })
  it('draws nothing for a provider with no account row', () => {
    expect(accountLine(undefined)).toBeNull()
  })
})
