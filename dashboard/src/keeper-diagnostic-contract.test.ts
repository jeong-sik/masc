import { describe, expect, it } from 'vitest'
import { normalizeKeeperDiagnostic } from './keeper-state'

const base = {
  health_state: 'healthy',
  last_reply_status: 'delivered',
  continuity_state: 'healthy',
}

describe('keeper diagnostic wire contract', () => {
  it('accepts every next_action_path the server emits', () => {
    for (const path of [
      'auto_restart',
      'recover',
      'probe',
      'direct_message',
    ]) {
      expect(
        normalizeKeeperDiagnostic({ ...base, next_action_path: path }),
        `next_action_path=${path}`,
      ).not.toBeNull()
    }
  })

  it('accepts every quiet_reason the server emits', () => {
    for (const reason of [
      'disabled',
      'not_running',
      'startup',
      'never_started',
    ]) {
      const parsed = normalizeKeeperDiagnostic({
        ...base,
        next_action_path: 'recover',
        quiet_reason: reason,
      })
      expect(parsed?.quiet_reason, `quiet_reason=${reason}`).toBe(reason)
    }
  })
})
