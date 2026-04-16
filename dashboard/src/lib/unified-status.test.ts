import { describe, it, expect } from 'vitest'
import { resolveUnifiedStatus } from './unified-status'

describe('resolveUnifiedStatus', () => {
  // ── Offline ────────────────────────────────────────────────

  it('resolves offline keeper status', () => {
    const r = resolveUnifiedStatus('offline', 'active', 'live')
    expect(r.canonical).toBe('offline')
    expect(r.label).toBe('오프라인')
  })

  it('resolves inactive as offline', () => {
    const r = resolveUnifiedStatus('inactive', null, null)
    expect(r.canonical).toBe('offline')
  })

  it('offline with live signal adds note', () => {
    const r = resolveUnifiedStatus('offline', null, 'live')
    expect(r.description).toContain('미션 신호는 최근 수신됨')
  })

  // ── Active ─────────────────────────────────────────────────

  it('resolves active keeper status', () => {
    const r = resolveUnifiedStatus('active', null, null)
    expect(r.canonical).toBe('active')
    expect(r.label).toBe('진행 중')
  })

  it('resolves running keeper status', () => {
    const r = resolveUnifiedStatus('running', null, null)
    expect(r.canonical).toBe('running')
  })

  it('resolves busy/working as active', () => {
    expect(resolveUnifiedStatus('busy', null, null).canonical).toBe('busy')
    expect(resolveUnifiedStatus('working', null, null).canonical).toBe('working')
  })

  it('active with stale signal adds note', () => {
    const r = resolveUnifiedStatus('active', null, 'stale')
    expect(r.description).toContain('오래됨')
  })

  // ── Idle / Listening ───────────────────────────────────────

  it('resolves listening status', () => {
    const r = resolveUnifiedStatus('listening', null, null)
    expect(r.canonical).toBe('listening')
    expect(r.label).toBe('대기')
  })

  it('resolves idle status', () => {
    const r = resolveUnifiedStatus('idle', null, null)
    expect(r.canonical).toBe('idle')
    expect(r.label).toBe('대기')
  })

  it('idle with live signal adds note', () => {
    const r = resolveUnifiedStatus('idle', null, 'live')
    expect(r.description).toContain('미션 신호 수신 중')
  })

  // ── Transitional ───────────────────────────────────────────

  it('resolves compacting status', () => {
    const r = resolveUnifiedStatus('compacting', null, null)
    expect(r.canonical).toBe('compacting')
    expect(r.description).toContain('압축 중')
  })

  it('resolves handoff status', () => {
    const r = resolveUnifiedStatus('handoff', null, null)
    expect(r.canonical).toBe('handoff')
    expect(r.description).toContain('핸드오프')
  })

  // ── Fallback to agent status ───────────────────────────────

  it('falls back to agent status when keeper is null', () => {
    const r = resolveUnifiedStatus(null, 'running', null)
    expect(r.canonical).toBe('running')
  })

  // ── Signal-only fallback ───────────────────────────────────

  it('resolves to live when only signal is live', () => {
    const r = resolveUnifiedStatus(null, null, 'live')
    expect(r.canonical).toBe('live')
    expect(r.label).toContain('활성')
  })

  it('resolves to stale when only signal is stale', () => {
    const r = resolveUnifiedStatus(null, null, 'stale')
    expect(r.canonical).toBe('stale')
  })

  it('resolves to archived when only signal is archived', () => {
    const r = resolveUnifiedStatus(null, null, 'archived')
    expect(r.canonical).toBe('archived')
  })

  // ── Unknown ────────────────────────────────────────────────

  it('resolves to unknown when all inputs are null', () => {
    const r = resolveUnifiedStatus(null, null, null)
    expect(r.canonical).toBe('unknown')
    expect(r.label).toBe('확인 필요')
  })

  it('resolves to unknown when all inputs are empty', () => {
    const r = resolveUnifiedStatus('', '', '')
    expect(r.canonical).toBe('unknown')
  })

  it('is case-insensitive', () => {
    expect(resolveUnifiedStatus('OFFLINE', null, null).canonical).toBe('offline')
    expect(resolveUnifiedStatus('Active', null, null).canonical).toBe('active')
  })
})
