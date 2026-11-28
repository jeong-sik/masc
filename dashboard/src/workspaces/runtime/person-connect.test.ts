import { describe, expect, it } from 'vitest'
import { keyConnectableRows, personConnectRows } from './person-connect'
import type { MultiAccountIntegration } from './types'

function integration(overrides: Partial<MultiAccountIntegration> = {}): MultiAccountIntegration {
  return {
    integration_id: 'claude_code',
    display_name: 'Claude Code',
    connect: ['login'],
    models: [],
    calls: 'allowed',
    ...overrides,
  }
}

describe('personConnectRows', () => {
  it('keeps the server order and marks the providers the person already connected', () => {
    const rows = personConnectRows(
      [integration(), integration({ integration_id: 'ollama_cloud', display_name: 'Ollama Cloud', connect: ['key'] })],
      new Set(['ollama_cloud']),
    )
    expect(rows.map((row) => [row.integrationId, row.ways, row.connected])).toEqual([
      ['claude_code', ['login'], false],
      ['ollama_cloud', ['key'], true],
    ])
  })

  it('shows a way it does not know without offering a button for it', () => {
    const [row] = personConnectRows([integration({ connect: ['login', 'device_code', 'login'] })], new Set())
    expect(row?.ways).toEqual(['login'])
    expect(row?.unknownWays).toEqual(['device_code'])
  })

  it('reads a refused provider with its code, and one without a code as refused', () => {
    const rows = personConnectRows(
      [
        integration({ calls: 'refused', refusal: 'native_unavailable' }),
        integration({ integration_id: 'x', calls: 'refused' }),
      ],
      new Set(),
    )
    expect(rows.map((row) => row.calls)).toEqual([
      { kind: 'refused', code: 'native_unavailable' },
      { kind: 'refused', code: null },
    ])
  })
})

describe('keyConnectableRows', () => {
  it('offers only providers that take a key and whose calls the server allows', () => {
    const rows = personConnectRows(
      [
        integration({ integration_id: 'login_only', connect: ['login'] }),
        integration({ integration_id: 'key_ok', connect: ['key'] }),
        integration({ integration_id: 'key_refused', connect: ['key'], calls: 'refused' }),
        integration({ integration_id: 'both', connect: ['login', 'key'] }),
      ],
      new Set(),
    )
    expect(keyConnectableRows(rows).map((row) => row.integrationId)).toEqual(['key_ok', 'both'])
  })
})
