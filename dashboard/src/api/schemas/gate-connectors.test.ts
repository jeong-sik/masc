// @ts-nocheck
import { describe, expect, it } from 'vitest'
import {
  parseGateConnectorsData,
  GateConnectorsSchemaDriftError,
} from './gate-connectors'

describe('parseGateConnectorsData', () => {
  const minimalConnector = {
    connector_id: 'c1',
    display_name: 'Test',
    channel: '#test',
  }

  const minimalOuter = {
    connectors: [minimalConnector],
    total: 1,
    active_count: 1,
    generated_at: '2024-01-01T00:00:00Z',
  }

  it('parses minimal valid data', () => {
    const result = parseGateConnectorsData(minimalOuter)
    expect(result.connectors).toHaveLength(1)
    expect(result.connectors[0].connector_id).toBe('c1')
    expect(result.connectors[0].capabilities).toEqual([])
    expect(result.connectors[0].trigger_policy).toBeNull()
    expect(result.connectors[0].available).toBe(false)
    expect(result.connectors[0].guild_count).toBe(0)
    expect(result.connectors[0].source_health).toEqual({
      storage_paths: 'fallback',
      runtime_summary: 'fallback',
      binding_summary: 'fallback',
      names: 'fallback',
      observed_channel: 'missing',
    })
    expect(result.total).toBe(1)
    expect(result.active_count).toBe(1)
    expect(result.generated_at).toBe('2024-01-01T00:00:00Z')
  })

  it('projects leaf trigger policy without retaining the legacy aggregate field', () => {
    const result = parseGateConnectorsData({
      ...minimalOuter,
      connectors: [{ ...minimalConnector, trigger_policy: 'all' }],
      discord_trigger_policy: 'mention_only',
    })
    expect(result.connectors[0].trigger_policy).toBe('all')
    expect('discord_trigger_policy' in result).toBe(false)
  })

  it('throws GateConnectorsSchemaDriftError when generated_at is empty', () => {
    expect(() =>
      parseGateConnectorsData({
        connectors: [],
        total: 0,
        active_count: 0,
        generated_at: '',
      }),
    ).toThrow(GateConnectorsSchemaDriftError)
  })

  it('throws GateConnectorsSchemaDriftError when generated_at is missing', () => {
    expect(() =>
      parseGateConnectorsData({
        connectors: [],
        total: 0,
        active_count: 0,
      }),
    ).toThrow(GateConnectorsSchemaDriftError)
  })

  it('returns empty connectors for non-array connectors field', () => {
    const result = parseGateConnectorsData({
      connectors: 'not-an-array',
      total: 0,
      active_count: 0,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors).toEqual([])
  })

  it('returns empty connectors when connectors field is null', () => {
    const result = parseGateConnectorsData({
      connectors: null,
      total: 0,
      active_count: 0,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors).toEqual([])
  })

  it('filters invalid connector entries (missing required fields)', () => {
    const result = parseGateConnectorsData({
      connectors: [
        minimalConnector,
        null,
        { connector_id: 'c2', display_name: 'Valid2', channel: '#valid2' },
        { missing: 'required' },
      ],
      total: 4,
      active_count: 2,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors).toHaveLength(2)
    expect(result.connectors[0].connector_id).toBe('c1')
    expect(result.connectors[1].connector_id).toBe('c2')
  })

  it('parses configured_bindings filtering invalid entries', () => {
    const result = parseGateConnectorsData({
      connectors: [
        {
          connector_id: 'c1',
          display_name: 'Test',
          channel: '#test',
          configured_bindings: [
            { channel_id: 'ch1', keeper_name: 'k1' },
            { channel_id: 'ch2' },
            'invalid',
          ],
        },
      ],
      total: 1,
      active_count: 1,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors[0].configured_bindings).toHaveLength(1)
    expect(result.connectors[0].configured_bindings[0]).toEqual({
      channel_id: 'ch1',
      keeper_name: 'k1',
    })
  })

  it('parses recent_audit filtering invalid entries', () => {
    const result = parseGateConnectorsData({
      connectors: [
        {
          connector_id: 'c1',
          display_name: 'Test',
          channel: '#test',
          recent_audit: [
            {
              timestamp: '2024-01-01',
              action: 'bind',
              guild_id: 'g1',
              channel_id: 'ch1',
              keeper_name: 'k1',
              actor_id: 'a1',
              actor_name: 'Alice',
              previous_keeper: 'old_k',
            },
            { timestamp: '2024-01-02' },
          ],
        },
      ],
      total: 1,
      active_count: 1,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors[0].recent_audit).toHaveLength(1)
    expect(result.connectors[0].recent_audit[0].previous_keeper).toBe('old_k')
  })

  it('parses storage_paths with defaults for missing input', () => {
    const result = parseGateConnectorsData(minimalOuter)
    expect(result.connectors[0].storage_paths).toEqual({
      status_path: '',
      binding_store_path: '',
      audit_path: '',
      names_path: '',
    })
  })

  it('parses storage_paths from provided object', () => {
    const result = parseGateConnectorsData({
      connectors: [
        {
          ...minimalConnector,
          storage_paths: {
            status_path: '/status',
            binding_store_path: '/bindings',
            audit_path: '/audit',
            names_path: '/names',
          },
        },
      ],
      total: 1,
      active_count: 1,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors[0].storage_paths).toEqual({
      status_path: '/status',
      binding_store_path: '/bindings',
      audit_path: '/audit',
      names_path: '/names',
    })
    expect(result.connectors[0].source_health.storage_paths).toBe('present')
  })

  it('parses runtime_summary with defaults when missing', () => {
    const result = parseGateConnectorsData(minimalOuter)
    expect(result.connectors[0].runtime_summary).toEqual({
      available: false,
      connected: false,
      stale: false,
      stale_after_sec: 0,
      status: '',
      error: '',
      updated_at: '',
      reply_mode: '',
      self_chat_guid: '',
      last_ready_at: '',
      bot_user_name: '',
      bot_user_id: '',
      guild_count: 0,
      gate_base_url: '',
      gate_healthy: null,
      gate_health_checked_at: '',
      pid: 0,
    })
  })

  it('parses runtime_summary from provided object', () => {
    const result = parseGateConnectorsData({
      connectors: [
        {
          ...minimalConnector,
          runtime_summary: {
            available: true,
            connected: true,
            stale: false,
            stale_after_sec: 300,
            status: 'ok',
            error: '',
            updated_at: '2024-01-01',
            reply_mode: 'auto',
            self_chat_guid: 'guid-1',
            last_ready_at: '2024-01-01',
            bot_user_name: 'Bot',
            bot_user_id: 'b1',
            guild_count: 5,
            gate_base_url: 'http://localhost:8080',
            gate_healthy: true,
            gate_health_checked_at: '2024-01-01',
            pid: 1234,
          },
        },
      ],
      total: 1,
      active_count: 1,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors[0].runtime_summary.available).toBe(true)
    expect(result.connectors[0].runtime_summary.connected).toBe(true)
    expect(result.connectors[0].runtime_summary.stale_after_sec).toBe(300)
    expect(result.connectors[0].runtime_summary.gate_healthy).toBe(true)
    expect(result.connectors[0].source_health.runtime_summary).toBe('present')
  })

  it('parses binding_summary with cross-field default for configured_bindings_count', () => {
    const result = parseGateConnectorsData({
      connectors: [
        {
          ...minimalConnector,
          configured_bindings: [
            { channel_id: 'ch1', keeper_name: 'k1' },
            { channel_id: 'ch2', keeper_name: 'k2' },
          ],
        },
      ],
      total: 1,
      active_count: 1,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors[0].binding_summary.configured_bindings_count).toBe(2)
    expect(result.connectors[0].binding_summary.binding_source).toBe('')
    expect(result.connectors[0].binding_summary.runtime_bindings_count).toBe(0)
  })

  it('parses binding_summary retaining provided configured_bindings_count', () => {
    const result = parseGateConnectorsData({
      connectors: [
        {
          ...minimalConnector,
          configured_bindings: [
            { channel_id: 'ch1', keeper_name: 'k1' },
          ],
          binding_summary: {
            binding_source: 'config',
            runtime_bindings_count: 3,
            configured_bindings_count: 5,
          },
        },
      ],
      total: 1,
      active_count: 1,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors[0].binding_summary.configured_bindings_count).toBe(5)
    expect(result.connectors[0].binding_summary.binding_source).toBe('config')
    expect(result.connectors[0].binding_summary.runtime_bindings_count).toBe(3)
    expect(result.connectors[0].source_health.binding_summary).toBe('present')
  })

  it('parses observed_channel as null when missing', () => {
    const result = parseGateConnectorsData(minimalOuter)
    expect(result.connectors[0].observed_channel).toBeNull()
    expect(result.connectors[0].source_health.observed_channel).toBe('missing')
  })

  it('filters names via filteredStringMap (drops empty strings and non-strings)', () => {
    const result = parseGateConnectorsData({
      connectors: [
        {
          ...minimalConnector,
          names: {
            guild_names: { g1: 'Guild One', g2: '', g3: null },
            channel_names: { c1: 'Channel One', c2: 123 },
            channel_to_guild: { c1: 'g1' },
            updated_at: '2024-01-01',
          },
        },
      ],
      total: 1,
      active_count: 1,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.connectors[0].names.guild_names).toEqual({ g1: 'Guild One' })
    expect(result.connectors[0].names.channel_names).toEqual({ c1: 'Channel One' })
    expect(result.connectors[0].names.channel_to_guild).toEqual({ c1: 'g1' })
    expect(result.connectors[0].names.updated_at).toBe('2024-01-01')
    expect(result.connectors[0].source_health.names).toBe('present')
  })

  it('returns default names when names field is missing', () => {
    const result = parseGateConnectorsData(minimalOuter)
    expect(result.connectors[0].names.guild_names).toEqual({})
    expect(result.connectors[0].names.channel_names).toEqual({})
    expect(result.connectors[0].names.channel_to_guild).toEqual({})
    expect(result.connectors[0].names.updated_at).toBe('')
  })

  it('preserves total and active_count from input', () => {
    const result = parseGateConnectorsData({
      connectors: [],
      total: 42,
      active_count: 7,
      generated_at: '2024-01-01T00:00:00Z',
    })
    expect(result.total).toBe(42)
    expect(result.active_count).toBe(7)
  })
})
