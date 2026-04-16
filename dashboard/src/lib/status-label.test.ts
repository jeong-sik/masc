import { describe, it, expect } from 'vitest'
import { statusLabel, displayStatus, prettyJson } from './status-label'

// ── statusLabel ───────────────────────────────────────────────

describe('statusLabel', () => {
  it('maps ok/healthy/green to 안정', () => {
    expect(statusLabel('ok')).toBe('안정')
    expect(statusLabel('healthy')).toBe('안정')
    expect(statusLabel('green')).toBe('안정')
  })

  it('maps active/running to 진행 중', () => {
    expect(statusLabel('active')).toBe('진행 중')
    expect(statusLabel('running')).toBe('진행 중')
  })

  it('maps paused to 일시정지', () => {
    expect(statusLabel('paused')).toBe('일시정지')
  })

  it('maps error/failed to 오류', () => {
    expect(statusLabel('error')).toBe('오류')
    expect(statusLabel('failed')).toBe('오류')
  })

  it('maps warn/warning/degraded to 주의', () => {
    expect(statusLabel('warn')).toBe('주의')
    expect(statusLabel('warning')).toBe('주의')
    expect(statusLabel('degraded')).toBe('주의')
  })

  it('maps done/completed/ended to 완료', () => {
    expect(statusLabel('done')).toBe('완료')
    expect(statusLabel('completed')).toBe('완료')
    expect(statusLabel('ended')).toBe('완료')
  })

  it('maps offline/inactive to 오프라인', () => {
    expect(statusLabel('offline')).toBe('오프라인')
    expect(statusLabel('inactive')).toBe('오프라인')
  })

  it('maps compacting to 컴팩팅', () => {
    expect(statusLabel('compacting')).toBe('컴팩팅')
  })

  it('maps awaiting_verification to 검증 대기', () => {
    expect(statusLabel('awaiting_verification')).toBe('검증 대기')
  })

  it('maps null/undefined/empty/unknown to 확인 필요', () => {
    expect(statusLabel(null)).toBe('확인 필요')
    expect(statusLabel(undefined)).toBe('확인 필요')
    expect(statusLabel('')).toBe('확인 필요')
    expect(statusLabel('unknown')).toBe('확인 필요')
  })

  it('passes through unknown values', () => {
    expect(statusLabel('CustomState')).toBe('CustomState')
  })

  it('is case-insensitive', () => {
    expect(statusLabel('OK')).toBe('안정')
    expect(statusLabel('Running')).toBe('진행 중')
    expect(statusLabel('PAUSED')).toBe('일시정지')
  })

  it('trims whitespace', () => {
    expect(statusLabel('  ok  ')).toBe('안정')
  })
})

// ── displayStatus ─────────────────────────────────────────────

describe('displayStatus', () => {
  it('maps active/running to 진행 중', () => {
    expect(displayStatus('active')).toBe('진행 중')
    expect(displayStatus('running')).toBe('진행 중')
  })

  it('maps paused to 일시정지', () => {
    expect(displayStatus('paused')).toBe('일시정지')
  })

  it('maps done/completed/ended to 완료', () => {
    expect(displayStatus('done')).toBe('완료')
    expect(displayStatus('completed')).toBe('완료')
    expect(displayStatus('ended')).toBe('완료')
  })

  it('maps failed/error to 문제', () => {
    expect(displayStatus('failed')).toBe('문제')
    expect(displayStatus('error')).toBe('문제')
  })

  it('maps stopped to 중단됨', () => {
    expect(displayStatus('stopped')).toBe('중단됨')
  })

  it('maps unbooted to 미기동', () => {
    expect(displayStatus('unbooted')).toBe('미기동')
  })

  it('maps null/undefined/empty to 확인 필요', () => {
    expect(displayStatus(null)).toBe('확인 필요')
    expect(displayStatus(undefined)).toBe('확인 필요')
    expect(displayStatus('')).toBe('확인 필요')
  })

  it('passes through unknown values', () => {
    expect(displayStatus('CustomStatus')).toBe('CustomStatus')
  })

  it('is case-insensitive', () => {
    expect(displayStatus('ACTIVE')).toBe('진행 중')
    expect(displayStatus('Paused')).toBe('일시정지')
  })
})

// ── prettyJson ────────────────────────────────────────────────

describe('prettyJson', () => {
  it('returns empty string for null', () => {
    expect(prettyJson(null)).toBe('')
  })

  it('returns empty string for undefined', () => {
    expect(prettyJson(undefined)).toBe('')
  })

  it('returns string as-is', () => {
    expect(prettyJson('hello')).toBe('hello')
  })

  it('formats objects as pretty JSON', () => {
    const result = prettyJson({ a: 1 })
    expect(result).toBe('{\n  "a": 1\n}')
  })

  it('formats arrays as pretty JSON', () => {
    const result = prettyJson([1, 2])
    expect(result).toBe('[\n  1,\n  2\n]')
  })

  it('formats numbers as JSON', () => {
    expect(prettyJson(42)).toBe('42')
  })

  it('formats booleans as JSON', () => {
    expect(prettyJson(true)).toBe('true')
  })
})
