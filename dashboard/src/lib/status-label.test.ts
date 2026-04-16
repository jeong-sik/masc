import { describe, it, expect } from 'vitest'
import { statusLabel, displayStatus, prettyJson } from './status-label'

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

describe('displayStatus', () => {
  it('maps core statuses', () => {
    expect(displayStatus('active')).toBe('진행 중')
    expect(displayStatus('paused')).toBe('일시정지')
    expect(displayStatus('done')).toBe('완료')
    expect(displayStatus('failed')).toBe('문제')
    expect(displayStatus('stopped')).toBe('중단됨')
    expect(displayStatus('offline')).toBe('오프라인')
    expect(displayStatus('idle')).toBe('대기')
  })
  it('maps unbooted', () => { expect(displayStatus('unbooted')).toBe('미기동') })
  it('returns 확인 필요 for empty/null', () => {
    expect(displayStatus('')).toBe('확인 필요')
    expect(displayStatus(null)).toBe('확인 필요')
  })
  it('passes through unrecognized', () => { expect(displayStatus('deploying')).toBe('deploying') })
  it('is case-insensitive', () => {
    expect(displayStatus('ACTIVE')).toBe('진행 중')
    expect(displayStatus('Paused')).toBe('일시정지')
  })
})

describe('prettyJson', () => {
  it('returns empty for null/undefined', () => {
    expect(prettyJson(null)).toBe('')
    expect(prettyJson(undefined)).toBe('')
  })
  it('passes through strings', () => { expect(prettyJson('hello')).toBe('hello') })
  it('formats objects', () => {
    const r = prettyJson({ a: 1 })
    expect(r).toContain('"a"')
    expect(r).toContain('1')
  })
  it('formats arrays', () => { expect(prettyJson([1, 2])).toBe('[\n  1,\n  2\n]') })
  it('formats numbers', () => { expect(prettyJson(42)).toBe('42') })
})
