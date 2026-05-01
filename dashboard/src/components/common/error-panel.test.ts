// @ts-nocheck
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { ErrorPanel } from './error-panel'
import { errors } from './error-notification-state'

function makeError(overrides: Partial<ReturnType<typeof errors.value>[0]> = {}) {
  return {
    id: 'err-1',
    fingerprint: 'fp-1',
    agentName: 'Alpha',
    taskId: 'task-1',
    message: 'something broke',
    errorCode: 'internal_error' as const,
    severity: 'critical' as const,
    timestamp: Date.now() - 30000,
    acknowledged: false,
    count: 1,
    lastSeen: Date.now() - 30000,
    ...overrides,
  }
}

describe('ErrorPanel', () => {
  beforeEach(() => {
    errors.value = []
  })

  it('renders empty state when no errors', () => {
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    expect(container.textContent).toContain('에러 없음')
    expect(container.textContent).toContain('모든 에러를 확인했습니다')
  })

  it('renders error count', () => {
    errors.value = [makeError(), makeError({ id: 'err-2', message: 'another' })]
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    expect(container.textContent).toContain('미확인 에러')
    expect(container.textContent).toContain('2')
  })

  it('renders error message', () => {
    errors.value = [makeError()]
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    expect(container.textContent).toContain('something broke')
  })

  it('renders agent name', () => {
    errors.value = [makeError()]
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    expect(container.textContent).toContain('Alpha')
  })

  it('renders error code label', () => {
    errors.value = [makeError({ errorCode: 'timeout', severity: 'warning' })]
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    expect(container.textContent).toContain('지연')
  })

  it('renders task id when present', () => {
    errors.value = [makeError()]
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    expect(container.textContent).toContain('task-1')
  })

  it('renders count badge when count > 1', () => {
    errors.value = [makeError({ count: 3 })]
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    expect(container.textContent).toContain('×3')
  })

  it('acknowledges error on check click', () => {
    errors.value = [makeError()]
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    const btn = container.querySelector('[aria-label="에러 확인"]') as HTMLElement
    btn?.click()
    expect(errors.value[0]?.acknowledged).toBe(true)
  })

  it('clears all errors on 모두 확인 click', () => {
    errors.value = [makeError(), makeError({ id: 'err-2' })]
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose }), container)
    const btn = Array.from(container.querySelectorAll('button')).find(b => b.textContent?.includes('모두 확인'))
    btn?.click()
    expect(errors.value.every(e => e.acknowledged)).toBe(true)
    expect(onClose).toHaveBeenCalled()
  })

  it('calls onClose on X click', () => {
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose }), container)
    const btn = container.querySelector('[aria-label="에러 패널 닫기"]') as HTMLElement
    btn?.click()
    expect(onClose).toHaveBeenCalled()
  })

  it('renders info severity with Info icon', () => {
    errors.value = [makeError({ severity: 'info', errorCode: 'not_found' })]
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    expect(container.textContent).toContain('404')
  })

  it('renders alert role when errors present', () => {
    errors.value = [makeError()]
    const container = document.createElement('div')
    render(h(ErrorPanel, { onClose: vi.fn() }), container)
    expect(container.querySelector('[role="alert"]')).not.toBeNull()
  })
})
