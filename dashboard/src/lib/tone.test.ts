import { describe, it, expect } from 'vitest'
import {
  toneClass, chainStatusTone, sessionStatusTone,
  expiryTone, toneBorder, toneBg, governanceToneClass,
} from './tone'

describe('toneClass', () => {
  it('classifies bad tones', () => {
    for (const t of ['bad','error','failed','fatal','offline','stopped','critical','risk']) {
      expect(toneClass(t)).toBe('bad')
    }
  })
  it('classifies warn tones', () => {
    for (const t of ['warn','warning','pending','degraded','interrupted','watch','paused','blocked','unbooted']) {
      expect(toneClass(t)).toBe('warn')
    }
  })
  it('classifies ok tones', () => {
    for (const t of ['ok','healthy','active','running','done','idle']) {
      expect(toneClass(t)).toBe('ok')
    }
  })
  it('defaults to ok for null/undefined/empty', () => {
    expect(toneClass(null)).toBe('ok')
    expect(toneClass(undefined)).toBe('ok')
    expect(toneClass('')).toBe('ok')
  })
})

describe('chainStatusTone', () => {
  it('detects bad via substring', () => {
    expect(chainStatusTone('task_failed')).toBe('bad')
    expect(chainStatusTone('error_state')).toBe('bad')
    expect(chainStatusTone('disconnected')).toBe('bad')
    expect(chainStatusTone('process_stopped')).toBe('bad')
  })
  it('detects warn via substring', () => {
    expect(chainStatusTone('is_running')).toBe('warn')
    expect(chainStatusTone('active_node')).toBe('warn')
    expect(chainStatusTone('degraded_perf')).toBe('warn')
    expect(chainStatusTone('pending_review')).toBe('warn')
  })
  it('defaults to ok for normal', () => {
    expect(chainStatusTone('completed')).toBe('ok')
    expect(chainStatusTone('healthy')).toBe('ok')
  })
  it('returns warn for null/empty', () => {
    expect(chainStatusTone('')).toBe('warn')
    expect(chainStatusTone(null)).toBe('warn')
  })
  it('is case-insensitive', () => {
    expect(chainStatusTone('FAILED')).toBe('bad')
    expect(chainStatusTone('Running')).toBe('warn')
  })
})

describe('sessionStatusTone', () => {
  it('detects bad', () => {
    expect(sessionStatusTone('failed')).toBe('bad')
    expect(sessionStatusTone('error')).toBe('bad')
    expect(sessionStatusTone('stopped')).toBe('bad')
    expect(sessionStatusTone('paused')).toBe('bad')
  })
  it('detects ok', () => {
    expect(sessionStatusTone('active')).toBe('ok')
    expect(sessionStatusTone('running')).toBe('ok')
    expect(sessionStatusTone('healthy')).toBe('ok')
    expect(sessionStatusTone('ok')).toBe('ok')
  })
  it('defaults to warn for unknown', () => {
    expect(sessionStatusTone('unknown')).toBe('warn')
    expect(sessionStatusTone('')).toBe('warn')
    expect(sessionStatusTone(null)).toBe('warn')
  })
})

describe('expiryTone', () => {
  it('returns bad for past', () => { expect(expiryTone('2020-01-01T00:00:00Z')).toBe('bad') })
  it('returns ok for future', () => { expect(expiryTone('2099-12-31T23:59:59Z')).toBe('ok') })
  it('returns warn for null', () => { expect(expiryTone(null)).toBe('warn') })
  it('returns warn for invalid', () => { expect(expiryTone('not-a-date')).toBe('warn') })
})

describe('toneBorder', () => {
  it('maps tones', () => {
    expect(toneBorder('bad')).toBe('tone-border-bad')
    expect(toneBorder('warn')).toBe('tone-border-warn')
    expect(toneBorder('ok')).toBe('tone-border-ok')
  })
  it('defaults to ok', () => { expect(toneBorder('random')).toBe('tone-border-ok') })
})

describe('toneBg', () => {
  it('maps tones', () => {
    expect(toneBg('bad')).toBe('tone-bg-bad')
    expect(toneBg('warn')).toBe('tone-bg-warn')
    expect(toneBg('ok')).toBe('tone-bg-ok')
  })
  it('defaults to ok', () => { expect(toneBg(null)).toBe('tone-bg-ok') })
})

describe('governanceToneClass', () => {
  it('classifies negative', () => {
    expect(governanceToneClass('blocked')).toBe('negative')
    expect(governanceToneClass('deny')).toBe('negative')
    expect(governanceToneClass('closed')).toBe('negative')
  })
  it('classifies positive', () => {
    expect(governanceToneClass('supported')).toBe('positive')
    expect(governanceToneClass('approved')).toBe('positive')
    expect(governanceToneClass('ready')).toBe('positive')
    expect(governanceToneClass('executed')).toBe('positive')
    expect(governanceToneClass('done')).toBe('positive')
  })
  it('defaults to neutral', () => {
    expect(governanceToneClass('pending')).toBe('neutral')
    expect(governanceToneClass(null)).toBe('neutral')
    expect(governanceToneClass(undefined)).toBe('neutral')
  })
  it('is case-insensitive', () => {
    expect(governanceToneClass('BLOCKED')).toBe('negative')
    expect(governanceToneClass('Approved')).toBe('positive')
  })
})
