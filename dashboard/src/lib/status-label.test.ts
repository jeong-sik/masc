import { describe, it, expect } from 'vitest'
import {
  statusLabel,
  displayStatus,
  prettyJson,
  actionLabel,
  actionTooltip,
  type KeeperActionVerb,
} from './status-label'

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
  // displayStatus now delegates to statusLabel — same key, same label.
  // The prior `failed → '문제'` divergence is intentionally removed; both
  // call sites get `'오류'` so operators see one consistent surface.
  it('maps core statuses (delegates to statusLabel)', () => {
    expect(displayStatus('active')).toBe('진행 중')
    expect(displayStatus('paused')).toBe('일시정지')
    expect(displayStatus('done')).toBe('완료')
    expect(displayStatus('failed')).toBe('오류') // was '문제' — unified
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

describe('actionLabel (RFC-0135 PR-7 noun/verb 분리)', () => {
  it('verb buttons carry 하기 suffix to distinguish from state nouns', () => {
    // The state badge for a paused keeper reads "일시정지" (noun).
    // The button to pause a running keeper must NOT read the same
    // word, or RFC-0135 §1.2 collision returns. The fix is the 하기
    // suffix for the verbs that have state-noun twins.
    expect(actionLabel('pause').text).toBe('일시정지하기')
    expect(actionLabel('resume').text).toBe('재개하기')
    expect(actionLabel('boot').text).toBe('기동하기')
    expect(actionLabel('shutdown').text).toBe('종료하기')
  })

  it('wakeup keeps the concise form because no state-noun collides', () => {
    expect(actionLabel('wakeup').text).toBe('깨우기')
  })

  it('past-tense form drops the 하기 suffix and adds 됨 for toast confirmation', () => {
    expect(actionLabel('pause').pastTense).toBe('일시정지됨')
    expect(actionLabel('resume').pastTense).toBe('재개됨')
    expect(actionLabel('boot').pastTense).toBe('기동됨')
    expect(actionLabel('shutdown').pastTense).toBe('종료됨')
    expect(actionLabel('wakeup').pastTense).toBe('깨워짐')
  })

  it('every verb declares precondition and effect tooltips', () => {
    const verbs: KeeperActionVerb[] = [
      'pause',
      'resume',
      'wakeup',
      'boot',
      'shutdown',
    ]
    for (const verb of verbs) {
      const entry = actionLabel(verb)
      expect(entry.precondition.length).toBeGreaterThan(0)
      expect(entry.effect.length).toBeGreaterThan(0)
      expect(entry.icon.length).toBeGreaterThan(0)
    }
  })

  it('actionTooltip combines label + precondition + effect for the title attribute', () => {
    const tip = actionTooltip('pause')
    expect(tip).toContain('일시정지하기')
    expect(tip).toContain('사전조건')
    expect(tip).toContain('효과')
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
