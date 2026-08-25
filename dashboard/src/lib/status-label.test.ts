import { describe, it, expect } from 'vitest'
import { statusLabel } from './status-label'

describe('statusLabel', () => {
  it('maps ok variants', () => {
    expect(statusLabel('ok')).toBe('안정')
    expect(statusLabel('healthy')).toBe('안정')
    expect(statusLabel('green')).toBe('안정')
  })
  it('maps running variants', () => {
    expect(statusLabel('active')).toBe('진행 중')
    expect(statusLabel('running')).toBe('진행 중')
  })
  it('maps paused', () => { expect(statusLabel('paused')).toBe('일시정지') })
  // These three reach the surface from types/health_status.ml and
  // keeper/keeper_status_runtime.ml. The default arm returns the wire token
  // unchanged, so a missing case is not a missing label — it is the English
  // token printed inside a Korean surface (#27165). The expectations are
  // literals: comparing against statusLabel's own output would pass either way.
  it('maps health tokens the backend emits', () => {
    expect(statusLabel('warming')).toBe('예열 중')
    expect(statusLabel('snapshot_not_ready')).toBe('스냅샷 준비 안 됨')
    expect(statusLabel('zombie')).toBe('좀비')
    expect(statusLabel('timeout')).toBe('시간 초과')
    expect(statusLabel('settled')).toBe('정리됨')
  })
  it('maps error variants', () => {
    expect(statusLabel('error')).toBe('오류')
    expect(statusLabel('failed')).toBe('오류')
  })
  it('maps offline variants', () => {
    expect(statusLabel('offline')).toBe('오프라인')
    expect(statusLabel('inactive')).toBe('오프라인')
  })
  it('maps completion variants', () => {
    expect(statusLabel('done')).toBe('완료')
    expect(statusLabel('completed')).toBe('완료')
    expect(statusLabel('ended')).toBe('완료')
  })
  it('maps compacting', () => { expect(statusLabel('compacting')).toBe('컴팩팅') })
  it('maps handoff', () => { expect(statusLabel('handoff')).toBe('핸드오프') })
  it('returns 확인 필요 for unknown/empty', () => {
    expect(statusLabel('unknown')).toBe('확인 필요')
    expect(statusLabel('')).toBe('확인 필요')
  })
  it('passes through unrecognized non-empty', () => { expect(statusLabel('custom_status')).toBe('custom_status') })
  it('handles null/undefined', () => {
    expect(statusLabel(null)).toBe('확인 필요')
    expect(statusLabel(undefined)).toBe('확인 필요')
  })
  it('is case-insensitive', () => {
    expect(statusLabel('OK')).toBe('안정')
    expect(statusLabel('Running')).toBe('진행 중')
    expect(statusLabel('FAILED')).toBe('오류')
  })
  it('trims whitespace', () => { expect(statusLabel('  ok  ')).toBe('안정') })
})

describe('statusLabel collision fixes (Iter#36)', () => {
  // Before this PR three pairs of distinct English keys collapsed onto the
  // same Korean label, making the dashboard label ambiguous.
  it('listening / idle / todo no longer all map to 대기', () => {
    expect(statusLabel('listening')).toBe('수신 대기')
    expect(statusLabel('idle')).toBe('대기')
    expect(statusLabel('todo')).toBe('예정')
  })
  it('interrupted (run aborted mid-flight) is distinct from stopped (clean termination)', () => {
    expect(statusLabel('interrupted')).toBe('인터럽트됨')
    expect(statusLabel('stopped')).toBe('중단됨')
  })
  it('in_progress aliases active/running', () => {
    expect(statusLabel('in_progress')).toBe('진행 중')
  })
})
