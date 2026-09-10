import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { post } from '../api/core'
import { modelSetupResumeState } from '../lib/model-setup-resume'
import { ModelSetupResumeControl } from './model-setup-resume-control'
vi.mock('../api/core', () => ({ post: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks(); modelSetupResumeState.value = { kind: 'idle' } })
it('resumes saved settings without declaring tool verification passed', async () => {
  vi.mocked(post).mockResolvedValue({ runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } })
  const completed = vi.fn()
  render(html`<${ModelSetupResumeControl} onComplete=${completed} />`)
  fireEvent.click(screen.getByRole('button', { name: '설정 재개' }))
  await screen.findByText(/저장한 모델 설정을 실행 중인 서버에 적용했습니다/)
  expect(post).toHaveBeenCalledWith('/api/v1/runtime/setup/resume', {})
  expect(screen.getByText(/모델 응답과 도구 검증 결과는 준비 상태에서 별도로/)).toBeTruthy()
  expect(completed).toHaveBeenCalledOnce()
})
it('rejects incomplete activation receipts and permits retry without showing server secrets', async () => {
  vi.mocked(post).mockResolvedValueOnce({ runtime_ready: true, secret: 'fixture-secret' })
    .mockRejectedValueOnce(new Error('fixture-secret'))
  render(html`<${ModelSetupResumeControl} />`)
  fireEvent.click(screen.getByRole('button', { name: '설정 재개' }))
  await screen.findByText(/모델 설정을 적용하지 못했습니다/)
  expect(document.body.textContent).not.toContain('fixture-secret')
  fireEvent.click(screen.getByRole('button', { name: '설정 재개' }))
  await screen.findByText(/모델 설정을 적용하지 못했습니다/)
  expect(document.body.textContent).not.toContain('fixture-secret')
})
it('identifies an older server instead of suggesting endless retries', async () => {
  vi.mocked(post).mockRejectedValue({ status: 404, message: 'private backend detail' })
  render(html`<${ModelSetupResumeControl} />`)
  fireEvent.click(screen.getByRole('button', { name: '설정 재개' }))
  await screen.findByText(/현재 서버 버전은 설정 재개를 지원하지 않습니다/)
  expect(document.body.textContent).not.toContain('private backend detail')
})
