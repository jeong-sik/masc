// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { html } from 'htm/preact'
import { MoleculeTrace, traceMoleculeDur } from './trace-molecule'
import type { ChatTraceStep } from '../../types'

describe('MoleculeTrace', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(() => {
    render(null, host)
    host.remove()
  })

  const steps: ChatTraceStep[] = [
    { kind: 'think', text: '경로를 확인한다' },
    { kind: 'reason', text: '두 후보 중 <b>안전한</b> 쪽', detail: '근거 상세' },
    { kind: 'tool', name: 'Read', status: 'ok', dur: '0.4s', args: '{"path":"a.ts"}', result: '"ok"' },
  ]

  function mount(trace: ChatTraceStep[] = steps, omitted = 0): HTMLElement {
    render(html`<${MoleculeTrace} trace=${trace} omitted=${omitted} />`, host)
    return host.firstElementChild as HTMLElement
  }

  it('renders the design trace chrome: trace-hd/chev/glyph/tlabel/tcount/tmeta', () => {
    const el = mount()
    expect(el.classList.contains('trace')).toBe(true)
    expect(el.classList.contains('open')).toBe(true)
    expect(el.querySelector('.trace-hd')).not.toBeNull()
    expect(el.querySelector('.trace-hd .chev')).not.toBeNull()
    expect(el.querySelector('.trace-hd .glyph')!.textContent).toBe('◆')
    expect(el.querySelector('.tlabel')!.textContent).toBe('작업 과정')
    expect(el.querySelector('.tcount')!.textContent).toBe('3단계')
    expect(el.querySelector('.tmeta')!.textContent).toContain('도구 1')
    expect(el.querySelector('.trace-steps .trace-rail')).not.toBeNull()
  })

  it('renders think/reason/tool steps with the design step vocabulary', () => {
    const el = mount()
    expect(el.querySelector('.tstep.think .tnode')).not.toBeNull()
    expect(el.querySelector('.tstep.think .tstep-kind')!.textContent).toBe('Thinking')
    expect(el.querySelector('.tstep.reason .tstep-text')).not.toBeNull()
    const tool = el.querySelector('.tstep.tool')!
    expect(tool.querySelector('.tstep-main .tstep-row .tname')!.textContent).toBe('Read')
    expect(tool.querySelector('.tdur')!.textContent).toBe('0.4s')
    expect(tool.querySelector('.dot2.ok')).not.toBeNull()
  })

  it('expands the tool body on click with args/result folds', () => {
    const el = mount()
    const row = el.querySelector('.tstep.tool .tstep-row') as HTMLElement
    expect(el.querySelector('.tool-body2')).toBeNull()
    fireEvent.click(row)
    const body = el.querySelector('.tool-body2')!
    expect(body).not.toBeNull()
    expect(body.querySelectorAll('.tk')).toHaveLength(2)
    expect(el.querySelector('.tstep.tool')!.classList.contains('exp')).toBe(true)
  })

  it('expands the reason detail fold on click', () => {
    const el = mount()
    const row = el.querySelector('.tstep.reason .tstep-row') as HTMLElement
    expect(el.querySelector('.reason-detail')).toBeNull()
    fireEvent.click(row)
    expect(el.querySelector('.reason-detail')!.textContent).toContain('근거 상세')
  })

  it('marks a pending tool step busy and an err step bad', () => {
    const el = mount([
      { kind: 'tool', name: 'A', status: 'pending' },
      { kind: 'tool', name: 'B', status: 'err' },
    ])
    expect(el.querySelector('.tstep.tool .dot2.busy')).not.toBeNull()
    expect(el.querySelectorAll('.tstep.tool .dot2.bad')).toHaveLength(1)
  })

  it('renders the omitted-steps notice instead of pretending the trace is whole', () => {
    const el = mount(steps, 4)
    expect(el.textContent).toContain('앞 4단계')
  })

  it('renders contentWithheld think steps with the 비공개 marker', () => {
    const el = mount([{ kind: 'think', text: '', contentWithheld: true }])
    expect(el.querySelector('.tstep.think .tstep-text')!.textContent).toBe('내부 판단 단계 (내용 비공개)')
  })

  it('keeps progress steps visible with think styling', () => {
    const el = mount([{ kind: 'progress', text: '도구 응답 대기' }])
    expect(el.querySelector('.tstep.think .tstep-kind')!.textContent).toBe('Progress')
    expect(el.textContent).toContain('도구 응답 대기')
  })
})

describe('traceMoleculeDur', () => {
  it('sums tool durations and returns null without any', () => {
    expect(traceMoleculeDur([
      { kind: 'tool', name: 'a', dur: '0.4s' },
      { kind: 'tool', name: 'b', dur: '1.2s' },
    ])).toBe('1.6s')
    expect(traceMoleculeDur([{ kind: 'think', text: 'x' }])).toBeNull()
  })
})
