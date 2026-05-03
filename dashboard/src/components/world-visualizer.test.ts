import { describe, expect, it } from 'vitest'
import { resolveYjsWebsocketUrl } from './world-visualizer'

describe('resolveYjsWebsocketUrl', () => {
  it('uses an explicitly configured URL', () => {
    expect(resolveYjsWebsocketUrl(' ws://127.0.0.1:8935/yjs ', true, {
      host: 'localhost:5173',
      protocol: 'http:',
    })).toBe('ws://127.0.0.1:8935/yjs')
  })

  it('falls back to the same-origin /yjs proxy in dev', () => {
    expect(resolveYjsWebsocketUrl(undefined, true, {
      host: 'localhost:5173',
      protocol: 'http:',
    })).toBe('ws://localhost:5173/yjs')
  })

  it('uses wss for https dev origins', () => {
    expect(resolveYjsWebsocketUrl(undefined, true, {
      host: 'dashboard.local',
      protocol: 'https:',
    })).toBe('wss://dashboard.local/yjs')
  })

  it('stays quiet outside dev without an explicit URL', () => {
    expect(resolveYjsWebsocketUrl(undefined, false, {
      host: 'dashboard.example',
      protocol: 'https:',
    })).toBeNull()
  })
})
