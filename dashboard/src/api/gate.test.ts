import { describe, it, expect } from 'vitest'
import {
  decodeGateStatusData,
  decodeGateKeepersData,
  decodeGateConnectorsData,
} from './gate'

describe('decodeGateStatusData', () => {
  it('returns null for null', () => {
    expect(decodeGateStatusData(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(decodeGateStatusData(undefined)).toBeNull()
  })

  it('returns null for non-object', () => {
    expect(decodeGateStatusData('string')).toBeNull()
    expect(decodeGateStatusData(42)).toBeNull()
  })

  it('decodes empty status data', () => {
    const raw = {}
    const result = decodeGateStatusData(raw)
    expect(result).not.toBeNull()
    expect(result!.channels).toEqual([])
    expect(result!.bindings).toEqual([])
    expect(result!.recent_events).toEqual([])
    expect(result!.total_messages).toBe(0)
    expect(result!.total_success).toBe(0)
    expect(result!.total_errors).toBe(0)
    expect(result!.total_duplicates).toBe(0)
    expect(result!.success_rate_pct).toBe(0)
    expect(result!.dedup_table_size).toBe(0)
    expect(result!.uptime_seconds).toBe(0)
  })

  it('decodes full status data with channels', () => {
    const raw = {
      channels: [
        {
          channel: 'discord:guild1:chan1',
          message_count: 100,
          success_count: 90,
          error_count: 5,
          duplicate_count: 5,
          validation_error_count: 1,
          keeper_error_count: 2,
          dispatch_unavailable_count: 1,
          internal_error_count: 1,
          last_activity: '2026-04-17T10:00:00Z',
          last_success: '2026-04-17T10:00:00Z',
          last_error_at: '2026-04-17T09:50:00Z',
          last_keeper: 'janitor',
          last_room_id: 'room-1',
          last_error: 'timeout',
          last_error_kind: 'network',
          last_outcome: 'error',
          avg_duration_ms: 250,
          max_duration_ms: 1200,
          slow_count: 3,
          slow_rate_pct: 3.0,
          success_rate_pct: 90.0,
          room_count: 2,
          health: 'healthy',
        },
      ],
      bindings: [],
      recent_events: [],
      total_messages: 100,
      total_success: 90,
      total_errors: 5,
      total_duplicates: 5,
      success_rate_pct: 90.0,
      dedup_table_size: 42,
      uptime_seconds: 86400,
    }
    const result = decodeGateStatusData(raw)
    expect(result).not.toBeNull()
    expect(result!.channels).toHaveLength(1)
    expect(result!.channels[0].channel).toBe('discord:guild1:chan1')
    expect(result!.channels[0].message_count).toBe(100)
    expect(result!.channels[0].success_rate_pct).toBe(90.0)
    expect(result!.channels[0].health).toBe('healthy')
    expect(result!.dedup_table_size).toBe(42)
    expect(result!.uptime_seconds).toBe(86400)
  })

  it('skips channel missing channel name', () => {
    const raw = { channels: [{ message_count: 5 }] }
    const result = decodeGateStatusData(raw)
    expect(result).not.toBeNull()
    expect(result!.channels).toEqual([])
  })

  it('decodes bindings', () => {
    const raw = {
      bindings: [
        {
          channel: 'discord:g:c',
          room_id: 'room-1',
          keeper: 'janitor',
          message_count: 50,
          success_count: 48,
          error_count: 2,
          duplicate_count: 0,
          last_activity: '2026-04-17T10:00:00Z',
          last_success: '2026-04-17T10:00:00Z',
          last_error_at: '',
          last_error: '',
          last_error_kind: '',
          last_outcome: 'ok',
          avg_duration_ms: 100,
          max_duration_ms: 500,
          success_rate_pct: 96.0,
          health: 'healthy',
        },
      ],
    }
    const result = decodeGateStatusData(raw)
    expect(result!.bindings).toHaveLength(1)
    expect(result!.bindings[0].channel).toBe('discord:g:c')
    expect(result!.bindings[0].keeper).toBe('janitor')
    expect(result!.bindings[0].room_id).toBe('room-1')
  })

  it('skips binding missing required fields', () => {
    const raw = { bindings: [{ channel: 'discord:g:c' }] }
    const result = decodeGateStatusData(raw)
    expect(result!.bindings).toEqual([])
  })

  it('decodes recent_events', () => {
    const raw = {
      recent_events: [
        {
          seq: 1,
          timestamp: '2026-04-17T10:00:00Z',
          channel: 'discord:g:c',
          room_id: 'room-1',
          keeper: 'janitor',
          outcome: 'success',
          error_kind: '',
          error: '',
          duration_ms: 150,
        },
      ],
    }
    const result = decodeGateStatusData(raw)
    expect(result!.recent_events).toHaveLength(1)
    expect(result!.recent_events[0].seq).toBe(1)
    expect(result!.recent_events[0].outcome).toBe('success')
    expect(result!.recent_events[0].duration_ms).toBe(150)
  })

  it('skips event missing required fields', () => {
    const raw = { recent_events: [{ seq: 1, channel: 'discord:g:c' }] }
    const result = decodeGateStatusData(raw)
    expect(result!.recent_events).toEqual([])
  })

  it('uses defaults for missing numeric fields', () => {
    const raw = { total_messages: null, uptime_seconds: undefined }
    const result = decodeGateStatusData(raw)
    expect(result!.total_messages).toBe(0)
    expect(result!.uptime_seconds).toBe(0)
  })

  it('handles channel with default health', () => {
    const raw = { channels: [{ channel: 'test' }] }
    const result = decodeGateStatusData(raw)
    expect(result!.channels[0].health).toBe('idle')
  })
})

describe('decodeGateKeepersData', () => {
  it('returns null for null', () => {
    expect(decodeGateKeepersData(null)).toBeNull()
  })

  it('returns null for non-object', () => {
    expect(decodeGateKeepersData(42)).toBeNull()
  })

  it('decodes empty keepers data', () => {
    const result = decodeGateKeepersData({})
    expect(result).not.toBeNull()
    expect(result!.count).toBe(0)
    expect(result!.keepers).toEqual([])
  })

  it('decodes keepers with required name', () => {
    const raw = {
      count: 2,
      keepers: [
        { name: 'janitor', status: 'active', keepalive_running: true, last_turn_ago_s: 30 },
        { name: 'dreamer', status: 'idle', agent_name: 'agent-1' },
      ],
    }
    const result = decodeGateKeepersData(raw)
    expect(result!.count).toBe(2)
    expect(result!.keepers).toHaveLength(2)
    expect(result!.keepers[0].name).toBe('janitor')
    expect(result!.keepers[0].status).toBe('active')
    expect(result!.keepers[0].keepalive_running).toBe(true)
    expect(result!.keepers[0].last_turn_ago_s).toBe(30)
    expect(result!.keepers[1].name).toBe('dreamer')
    expect(result!.keepers[1].agent_name).toBe('agent-1')
  })

  it('skips keeper without name', () => {
    const raw = { keepers: [{ status: 'active' }, { name: 'janitor' }] }
    const result = decodeGateKeepersData(raw)
    expect(result!.keepers).toHaveLength(1)
    expect(result!.keepers[0].name).toBe('janitor')
  })

  it('handles missing optional fields as undefined', () => {
    const raw = { keepers: [{ name: 'minimal' }] }
    const result = decodeGateKeepersData(raw)
    const keeper = result!.keepers[0]
    expect(keeper.name).toBe('minimal')
    expect(keeper.agent_name).toBeUndefined()
    expect(keeper.status).toBeUndefined()
    expect(keeper.model).toBeUndefined()
    expect(keeper.keepalive_running).toBeUndefined()
    expect(keeper.last_turn_ago_s).toBeNull()
  })

  it('handles null last_turn_ago_s', () => {
    const raw = { keepers: [{ name: 'test', last_turn_ago_s: null }] }
    const result = decodeGateKeepersData(raw)
    expect(result!.keepers[0].last_turn_ago_s).toBeNull()
  })

  it('uses default count 0', () => {
    const raw = { keepers: [{ name: 'test' }] }
    const result = decodeGateKeepersData(raw)
    expect(result!.count).toBe(0)
  })
})

describe('decodeGateConnectorsData', () => {
  it('returns null for null', () => {
    expect(decodeGateConnectorsData(null)).toBeNull()
  })

  it('returns null for non-object', () => {
    expect(decodeGateConnectorsData('x')).toBeNull()
  })

  it('returns null when generated_at is missing', () => {
    const raw = { connectors: [], total: 0, active_count: 0 }
    expect(decodeGateConnectorsData(raw)).toBeNull()
  })

  it('returns null when generated_at is empty', () => {
    const raw = { generated_at: '', connectors: [] }
    expect(decodeGateConnectorsData(raw)).toBeNull()
  })

  it('decodes minimal connectors data', () => {
    const raw = { generated_at: '2026-04-17T10:00:00Z' }
    const result = decodeGateConnectorsData(raw)
    expect(result).not.toBeNull()
    expect(result!.generated_at).toBe('2026-04-17T10:00:00Z')
    expect(result!.connectors).toEqual([])
    expect(result!.total).toBe(0)
    expect(result!.active_count).toBe(0)
  })

  it('decodes full connector with bindings and audit', () => {
    const raw = {
      generated_at: '2026-04-17T10:00:00Z',
      total: 1,
      active_count: 1,
      connectors: [
        {
          connector_id: 'discord-main',
          display_name: 'Discord Main',
          channel: 'discord',
          capabilities: ['send', 'receive'],
          status: 'connected',
          available: true,
          connected: true,
          stale: false,
          stale_after_sec: 120,
          error: '',
          configured_bindings: [
            { channel_id: 'ch-1', keeper_name: 'janitor' },
          ],
          recent_audit: [
            {
              timestamp: '2026-04-17T09:00:00Z',
              action: 'bind',
              guild_id: 'g-1',
              channel_id: 'ch-1',
              keeper_name: 'janitor',
              actor_id: 'actor-1',
              actor_name: 'Admin',
              previous_keeper: 'old-keeper',
            },
          ],
          storage_paths: {
            status_path: '/data/status.json',
            binding_store_path: '/data/bindings.json',
            audit_path: '/data/audit.jsonl',
            names_path: '/data/names.json',
          },
          runtime_summary: {
            available: true,
            connected: true,
            stale: false,
            stale_after_sec: 120,
            status: 'ready',
            bot_user_name: 'TestBot',
            bot_user_id: 'bot-123',
            guild_count: 3,
            pid: 12345,
          },
          binding_summary: {
            binding_source: 'config',
            runtime_bindings_count: 1,
            configured_bindings_count: 1,
          },
          names: {
            guild_names: { 'g-1': 'Test Guild' },
            channel_names: { 'ch-1': 'general' },
            channel_to_guild: { 'ch-1': 'g-1' },
            updated_at: '2026-04-17T08:00:00Z',
          },
        },
      ],
    }
    const result = decodeGateConnectorsData(raw)
    expect(result!.connectors).toHaveLength(1)
    const conn = result!.connectors[0]
    expect(conn.connector_id).toBe('discord-main')
    expect(conn.display_name).toBe('Discord Main')
    expect(conn.channel).toBe('discord')
    expect(conn.capabilities).toEqual(['send', 'receive'])
    expect(conn.available).toBe(true)
    expect(conn.configured_bindings).toHaveLength(1)
    expect(conn.configured_bindings[0].channel_id).toBe('ch-1')
    expect(conn.recent_audit).toHaveLength(1)
    expect(conn.recent_audit[0].action).toBe('bind')
    expect(conn.recent_audit[0].previous_keeper).toBe('old-keeper')
    expect(conn.storage_paths.status_path).toBe('/data/status.json')
    expect(conn.runtime_summary.bot_user_name).toBe('TestBot')
    expect(conn.runtime_summary.guild_count).toBe(3)
    expect(conn.binding_summary.binding_source).toBe('config')
    expect(conn.names.guild_names['g-1']).toBe('Test Guild')
    expect(conn.names.channel_names['ch-1']).toBe('general')
  })

  it('skips connector missing required fields', () => {
    const raw = {
      generated_at: '2026-04-17T10:00:00Z',
      connectors: [
        { connector_id: 'x' },
        { connector_id: 'y', display_name: 'Y' },
        { connector_id: 'z', display_name: 'Z', channel: 'discord' },
      ],
    }
    const result = decodeGateConnectorsData(raw)
    expect(result!.connectors).toHaveLength(1)
    expect(result!.connectors[0].connector_id).toBe('z')
  })

  it('skips configured_binding missing required fields', () => {
    const raw = {
      generated_at: '2026-04-17T10:00:00Z',
      connectors: [{
        connector_id: 'c1',
        display_name: 'C1',
        channel: 'discord',
        configured_bindings: [{ channel_id: 'ch-1' }],
      }],
    }
    const result = decodeGateConnectorsData(raw)
    expect(result!.connectors[0].configured_bindings).toEqual([])
  })

  it('skips audit entry missing required fields', () => {
    const raw = {
      generated_at: '2026-04-17T10:00:00Z',
      connectors: [{
        connector_id: 'c1',
        display_name: 'C1',
        channel: 'discord',
        recent_audit: [{ timestamp: '2026-04-17T09:00:00Z', action: 'bind' }],
      }],
    }
    const result = decodeGateConnectorsData(raw)
    expect(result!.connectors[0].recent_audit).toEqual([])
  })

  it('handles missing storage_paths gracefully', () => {
    const raw = {
      generated_at: '2026-04-17T10:00:00Z',
      connectors: [{
        connector_id: 'c1',
        display_name: 'C1',
        channel: 'discord',
      }],
    }
    const result = decodeGateConnectorsData(raw)
    const sp = result!.connectors[0].storage_paths
    expect(sp.status_path).toBe('')
    expect(sp.binding_store_path).toBe('')
  })

  it('handles missing names gracefully', () => {
    const raw = {
      generated_at: '2026-04-17T10:00:00Z',
      connectors: [{
        connector_id: 'c1',
        display_name: 'C1',
        channel: 'discord',
      }],
    }
    const result = decodeGateConnectorsData(raw)
    expect(result!.connectors[0].names.guild_names).toEqual({})
    expect(result!.connectors[0].names.channel_names).toEqual({})
  })

  it('filters non-string values from string maps', () => {
    const raw = {
      generated_at: '2026-04-17T10:00:00Z',
      connectors: [{
        connector_id: 'c1',
        display_name: 'C1',
        channel: 'discord',
        names: {
          guild_names: { valid: 'Guild A', invalid: 42, empty: '' },
        },
      }],
    }
    const result = decodeGateConnectorsData(raw)
    const gn = result!.connectors[0].names.guild_names
    expect(gn['valid']).toBe('Guild A')
    expect('invalid' in gn).toBe(false)
    expect('empty' in gn).toBe(false)
  })

  it('uses configured_bindings length as fallback for binding_summary count', () => {
    const raw = {
      generated_at: '2026-04-17T10:00:00Z',
      connectors: [{
        connector_id: 'c1',
        display_name: 'C1',
        channel: 'discord',
        configured_bindings: [
          { channel_id: 'ch-1', keeper_name: 'k1' },
          { channel_id: 'ch-2', keeper_name: 'k2' },
        ],
      }],
    }
    const result = decodeGateConnectorsData(raw)
    // binding_summary is missing, so configured_bindings_count should fallback to 2
    expect(result!.connectors[0].binding_summary.configured_bindings_count).toBe(2)
  })
})
