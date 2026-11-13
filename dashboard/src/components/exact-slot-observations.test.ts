import { html } from 'htm/preact'
import { cleanup, render, within } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { parseSlotMatrix, parseSlotObservations } from '../api/exact-slot-observations'
import { slotMatrix, slotObservation } from '../api/fixtures/exact-slot-observations'
import { ExactLaneSlotStates, ExactRunSlotObservations } from './exact-slot-observations'

afterEach(cleanup)
describe('exact-slot diagnostic views', () => {
  it('separates current and historical endpoints, preserves refusal, and exposes uncertain ordering', () => {
    const screen = render(html`<${ExactLaneSlotStates} value=${parseSlotMatrix(slotMatrix(), 1, 'board_attention_exact')} />`)
    const a = within(screen.getByRole('region', { name: 'A http' }))
    expect(within(a.getByLabelText('현재 설정 주소')).getByText('https://new.invalid/v1/responses')).toBeTruthy()
    const observed = within(a.getByRole('region', { name: '날짜가 확인된 마지막 관측' }))
    expect(observed.getByText('https://old.invalid/v1/responses')).toBeTruthy()
    expect(observed.getByText(/HTTP 429.*Rate_limited/)).toBeTruthy()
    expect(observed.getByText('original-run')).toBeTruthy()
    expect(a.getByText('순서 미확인 결과 (1)')).toBeTruthy()
    expect(a.getByText(/Runtime_unavailable/)).toBeTruthy()
    expect(screen.getByRole('status').textContent).toContain('1개 run')
    const unknown = within(screen.getByRole('region', { name: 'C http' }))
    expect(unknown.getByText(/실행 여부 미확인/)).toBeTruthy()
    expect(screen.queryAllByRole('button')).toHaveLength(0)
  })
  it('shows official-client invocation and leaves the remote endpoint and POST unobserved', () => {
    const value = parseSlotObservations({ state: 'available', observations: [slotObservation({
      binding: ['Official_client'], outcome: ['Accepted'],
    })] })
    const screen = render(html`<${ExactRunSlotObservations} value=${value} />`)
    expect(screen.getByText('공식 클라이언트 · 공급자 주소 미관측')).toBeTruthy()
    expect(screen.getByText(/클라이언트 호출: 관측됨 · 원격 POST 여부 미관측/)).toBeTruthy()
    expect(screen.getByText('call-A')).toBeTruthy()
  })
  it('shows missing or malformed observations without fabricating a successful execution', () => {
    const screen = render(html`<${ExactRunSlotObservations} />`)
    expect(screen.getByText(/실행 여부 미확인/)).toBeTruthy()
    screen.rerender(html`<${ExactRunSlotObservations} value=${parseSlotObservations({ state: 'available', observations: [{}] })} />`)
    expect(screen.getByRole('status').textContent).toContain('슬롯 관측을 읽지 못했습니다')
  })
})
