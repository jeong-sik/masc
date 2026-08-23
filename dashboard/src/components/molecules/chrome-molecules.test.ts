// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { html } from 'htm/preact'
import { MoleculeFeedbackRow, MoleculeNoted, MoleculeRegenTag } from './feedback-molecule'
import { MoleculeFsmLifeline, turnFsmLifelineSteps } from './fsm-lifeline'
import { MoleculeContextMenu } from './context-menu'
import { MoleculeSparkline, MoleculeTpsLive } from './streaming-molecule'
import { MoleculeWaterfallFoot } from './waterfall-legend'

describe('MoleculeFeedbackRow', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders the fbk row with vote + inspect buttons', () => {
    const onInspect = vi.fn()
    render(html`<${MoleculeFeedbackRow} onInspect=${onInspect} />`, host)
    const el = host.firstElementChild as HTMLElement
    expect(el.classList.contains('fbk')).toBe(true)
    const btns = el.querySelectorAll('.fbk-btn')
    expect(btns[0]!.classList.contains('up')).toBe(true)
    expect(btns[1]!.classList.contains('down')).toBe(true)
    expect(el.querySelector('.fbk-btn.inspect')!.textContent).toContain('턴 상세')
    ;(el.querySelector('.fbk-btn.inspect') as HTMLButtonElement).click()
    expect(onInspect).toHaveBeenCalledOnce()
  })

  it('toggles self-managed vote state and shows the transient noted chip', () => {
    render(html`<${MoleculeFeedbackRow} />`, host)
    const up = host.querySelector('.fbk-btn.up') as HTMLButtonElement
    fireEvent.click(up)
    expect(up.classList.contains('on')).toBe(true)
    expect(host.querySelector('.fbk-noted')!.textContent).toContain('피드백 기록됨')
    fireEvent.click(up)
    expect(up.classList.contains('on')).toBe(false)
  })

  it('is controlled when onChange is given', () => {
    const onChange = vi.fn()
    render(html`<${MoleculeFeedbackRow} value="down" onChange=${onChange} />`, host)
    expect(host.querySelector('.fbk-btn.down')!.classList.contains('on')).toBe(true)
    fireEvent.click(host.querySelector('.fbk-btn.up')!)
    expect(onChange).toHaveBeenCalledWith('up')
  })

  it('renders fbk-verify only when verified is passed from a real verdict', () => {
    render(html`<${MoleculeFeedbackRow} />`, host)
    expect(host.querySelector('.fbk-verify')).toBeNull()
    render(null, host)
    render(html`<${MoleculeFeedbackRow} verified=${true} />`, host)
    expect(host.querySelector('.fbk-verify')!.textContent).toContain('검증 통과')
  })
})

describe('MoleculeRegenTag / MoleculeNoted', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('render the design chips', () => {
    render(html`<div><${MoleculeRegenTag} /><${MoleculeNoted} /></div>`, host)
    expect(host.querySelector('.regen-tag')!.textContent).toBe('재생성됨')
    expect(host.querySelector('.fbk-noted')!.textContent).toBe('기록됨 ✓')
  })
})

describe('MoleculeFsmLifeline', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders fsm-step rows with done/cur pip states', () => {
    render(html`
      <${MoleculeFsmLifeline}
        steps=${[{ label: 'idle', state: 'done' }, { label: 'executing', state: 'cur' }, { label: 'finalizing', state: '' }]}
      />
    `, host)
    const steps = host.querySelectorAll('.fsm .fsm-step')
    expect(steps).toHaveLength(3)
    expect(steps[0]!.classList.contains('done')).toBe(true)
    expect(steps[1]!.classList.contains('cur')).toBe(true)
    expect(steps[0]!.querySelector('.pip')).not.toBeNull()
  })

  it('derives steps from a real backend turn phase', () => {
    const steps = turnFsmLifelineSteps('executing')!
    expect(steps).not.toBeNull()
    const cur = steps.find((s) => s.state === 'cur')!
    expect(cur.label).toBe('executing')
    expect(steps.find((s) => s.label === 'idle')!.state).toBe('done')
    expect(steps.find((s) => s.label === 'finalizing')!.state).toBe('')
  })

  it('maps awaiting_tool onto the UI state and returns null for unknown phases', () => {
    const steps = turnFsmLifelineSteps('awaiting_tool')!
    expect(steps.find((s) => s.state === 'cur')!.label).toBe('awaiting_tool_result')
    expect(turnFsmLifelineSteps('not-a-phase')).toBeNull()
    expect(turnFsmLifelineSteps(null)).toBeNull()
  })
})

describe('MoleculeContextMenu', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders kp-menu with header, items, danger tone, and separators', () => {
    const onRestart = vi.fn()
    render(html`
      <${MoleculeContextMenu}
        keeper=${{ slot: 3, mono: 'IC', name: 'iron-claw' }}
        items=${[
          { label: '턴 인스펙터 열기' },
          'sep',
          { label: '재시작', danger: true, onClick: onRestart },
        ]}
      />
    `, host)
    const el = host.firstElementChild as HTMLElement
    expect(el.classList.contains('kp-menu')).toBe(true)
    expect(el.querySelector('.kp-menu-h')!.textContent).toContain('iron-claw')
    expect(el.querySelector('.kp-menu-h .sigil')).not.toBeNull()
    expect(el.querySelector('.kp-menu-sep')).not.toBeNull()
    const items = el.querySelectorAll('.kp-menu-i')
    expect(items).toHaveLength(2)
    expect(items[1]!.classList.contains('danger')).toBe(true)
    ;(items[1] as HTMLButtonElement).click()
    expect(onRestart).toHaveBeenCalledOnce()
  })

  it('renders without a header when no keeper is given', () => {
    render(html`<${MoleculeContextMenu} items=${[{ label: 'a' }]} />`, host)
    expect(host.querySelector('.kp-menu-h')).toBeNull()
  })
})

describe('MoleculeTpsLive / MoleculeSparkline', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders the observed tok/s rate, nothing when unobserved', () => {
    render(html`<${MoleculeTpsLive} rate=${41.6} />`, host)
    expect(host.querySelector('.tps-live .tps-dot')).not.toBeNull()
    expect(host.querySelector('.tps-live .mono')!.textContent).toBe('42 tok/s')
    render(null, host)
    host.innerHTML = ''
    render(html`<${MoleculeTpsLive} rate=${null} />`, host)
    expect(host.querySelector('.tps-live')).toBeNull()
  })

  it('renders normalized sparkline bars from observed values only', () => {
    render(html`<${MoleculeSparkline} values=${[1, 2, 4]} label="rt" />`, host)
    const spark = host.querySelector('.tps-spark')!
    expect(spark.querySelectorAll('span:not(.tps-spark-rt)')).toHaveLength(3)
    expect(host.querySelector('.tps-spark-rt')!.textContent).toBe('rt')
    render(null, host)
    host.innerHTML = ''
    render(html`<${MoleculeSparkline} values=${[]} />`, host)
    expect(host.querySelector('.tps-spark')).toBeNull()
  })
})

describe('MoleculeWaterfallFoot', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders the full four-kind legend including ctx', () => {
    render(html`<${MoleculeWaterfallFoot} total="3.2s" />`, host)
    const el = host.firstElementChild as HTMLElement
    expect(el.classList.contains('ti-wf-foot')).toBe(true)
    expect(el.textContent).toContain('3.2s')
    const legend = el.querySelector('.ti-wf-legend')!
    expect(legend.querySelector('.ti-k-ctx')).not.toBeNull()
    expect(legend.querySelector('.ti-k-reason')).not.toBeNull()
    expect(legend.querySelector('.ti-k-tool')).not.toBeNull()
    expect(legend.querySelector('.ti-k-gen')).not.toBeNull()
  })
})
