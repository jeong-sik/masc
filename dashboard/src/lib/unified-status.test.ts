import { describe, it, expect } from 'vitest'
import { resolveUnifiedStatus } from './unified-status'

describe('resolveUnifiedStatus', () => {
  it('resolves offline from keeper status', () => {
    const r = resolveUnifiedStatus('offline', 'running', 'live')
    expect(r.canonical).toBe('offline')
    expect(r.label).toBe('오프라인')
  })

  it('resolves offline with live signal annotation', () => {
    const r = resolveUnifiedStatus('offline', null, 'live')
    expect(r.description).toContain('미션 신호는 최근 수신됨')
  })

  it('resolves inactive as offline', () => {
    const r = resolveUnifiedStatus('inactive', null, null)
    expect(r.canonical).toBe('offline')
  })

  it('resolves running status', () => {
    const r = resolveUnifiedStatus('running', null, null)
    expect(r.canonical).toBe('running')
    expect(r.label).toBe('진행 중')
  })

  it('resolves active status with stale annotation', () => {
    const r = resolveUnifiedStatus('active', null, 'stale')
    expect(r.description).toContain('오래됨')
  })

  it('resolves busy as active', () => {
    const r = resolveUnifiedStatus('busy', null, null)
    expect(r.canonical).toBe('busy')
  })

  it('resolves working as active', () => {
    const r = resolveUnifiedStatus('working', null, null)
    expect(r.canonical).toBe('working')
  })

  it('resolves listening with live signal', () => {
    const r = resolveUnifiedStatus('listening', null, 'live')
    expect(r.description).toContain('미션 신호 수신 중')
  })

  it('resolves idle without live signal', () => {
    const r = resolveUnifiedStatus('idle', null, null)
    expect(r.description).toBe('대기 중')
  })

  it('resolves compacting transitional', () => {
    const r = resolveUnifiedStatus('compacting', null, null)
    expect(r.description).toBe('컨텍스트 압축 중')
  })

  it('resolves handoff transitional', () => {
    const r = resolveUnifiedStatus('handoff', null, null)
    expect(r.description).toBe('핸드오프 진행 중')
  })

  it('falls back to agent status when keeper is null', () => {
    const r = resolveUnifiedStatus(null, 'running', null)
    expect(r.canonical).toBe('running')
  })

  it('falls back to signal_truth when no keeper/agent status', () => {
    const r = resolveUnifiedStatus(null, null, 'live')
    expect(r.canonical).toBe('live')
    expect(r.label).toBe('활성 (신호)')
  })

  it('resolves stale signal fallback', () => {
    const r = resolveUnifiedStatus(null, null, 'stale')
    expect(r.canonical).toBe('stale')
  })

  it('resolves archived signal fallback', () => {
    const r = resolveUnifiedStatus(null, null, 'archived')
    expect(r.canonical).toBe('archived')
    expect(r.description).toContain('미션 종료')
  })

  it('returns unknown for all null', () => {
    const r = resolveUnifiedStatus(null, null, null)
    expect(r.canonical).toBe('unknown')
    expect(r.label).toBe('확인 필요')
  })

  it('returns unknown for empty strings', () => {
    const r = resolveUnifiedStatus('', '', '')
    expect(r.canonical).toBe('unknown')
  })
})
