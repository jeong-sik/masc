// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Live } from './live'

describe('Live', () => {
  const makeContainer = () => document.createElement('div')

  it('renders full variant by default', () => {
    const container = makeContainer()
    render(html`<${Live} />`, container)
    expect(container.querySelector('[aria-label="라이브 협업 상태"]')).not.toBeNull()
    expect(container.querySelector('[aria-label="이벤트 펄스 현황"]')).not.toBeNull()
    render(null, container)
  })

  it('renders observatory variant without pulse strip', () => {
    const container = makeContainer()
    render(html`<${Live} variant="observatory" />`, container)
    expect(container.querySelector('[aria-label="라이브 협업 상태"]')).toBeNull()
    expect(container.querySelector('[aria-label="이벤트 펄스 현황"]')).toBeNull()
    render(null, container)
  })

  it('observatory variant shows activity stream and focus sidebar', () => {
    const container = makeContainer()
    render(html`<${Live} variant="observatory" />`, container)
    expect(container.querySelector('[aria-label="활동 스트림"]')).not.toBeNull()
    expect(container.textContent).toContain('에이전트 상태 상세')
    render(null, container)
  })

  it('full variant shows live-panels grid layout', () => {
    const container = makeContainer()
    render(html`<${Live} variant="full" />`, container)
    expect(container.querySelector('.live-panels')).not.toBeNull()
    expect(container.querySelector('[aria-label="활동 스트림"]')).not.toBeNull()
    expect(container.querySelector('[aria-label="에이전트 상태 사이드바"]')).not.toBeNull()
    render(null, container)
  })
})
