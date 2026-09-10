import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { get } from '../api/core'
import { SandboxSetupCatalog } from './sandbox-setup-catalog'

vi.mock('../api/core', () => ({ get: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
const row = (id: string, advanced: boolean, configured = false) => ({ id, advanced, configured, recommended: configured,
  state: 'service_ready', reason: 'service observed', guest_verification: 'not_run', capabilities: { network_modes: ['inherit', 'none'] } })
const catalog = () => ({ schema: 'masc.sandbox_readiness.v1', configuration_error: null,
  configured_selection: { backend: 'docker', network_mode: 'none' }, candidates: [row('docker', false, true), row('remote_ssh', true)] })

it('shows service evidence and configured network without claiming guest execution', async () => {
  vi.mocked(get).mockResolvedValue(catalog())
  render(html`<${SandboxSetupCatalog} />`)
  await screen.findByText(/서비스 감지됨 · guest 준비와 실행 확인 필요/)
  expect(get).toHaveBeenCalledWith('/api/v1/setup/sandbox')
  expect(screen.getByText(/현재 설정:/).textContent).toContain('네트워크 차단')
  expect(screen.getByText(/모델 연결과 WebFetch는 별도의 서버 설정/)).toBeTruthy()
  expect(screen.queryByText('Remote SSH')).toBeNull()
  fireEvent.click(screen.getByText('고급 선택지 보기'))
  expect(screen.getByText('Remote SSH')).toBeTruthy()
})

it('keeps an existing advanced sandbox visible in common choices', async () => {
  const data = catalog()
  data.configured_selection = { backend: 'remote_ssh', network_mode: 'inherit' }
  data.candidates = [row('docker', false), row('remote_ssh', true, true)]
  vi.mocked(get).mockResolvedValue(data)
  render(html`<${SandboxSetupCatalog} />`)
  await screen.findByText(/현재 설정:/)
  expect(screen.getAllByText('Remote SSH')).toHaveLength(2)
})

it('refreshes prerequisite observations after an external installation', async () => {
  const missing = catalog()
  missing.candidates[0] = { ...missing.candidates[0]!, state: 'missing_prerequisite', reason: 'Docker needs installation' }
  vi.mocked(get).mockResolvedValueOnce(missing).mockResolvedValueOnce(catalog())
  render(html`<${SandboxSetupCatalog} />`)
  await screen.findByText('Docker needs installation')
  fireEvent.click(screen.getByText('sandbox 상태 새로고침'))
  await screen.findByText(/서비스 감지됨 · guest 준비와 실행 확인 필요/)
  expect(screen.queryByText('Docker needs installation')).toBeNull()
})

it('refuses an unrecognized readiness receipt and hides raw failures', async () => {
  const data = catalog()
  data.candidates[0]!.guest_verification = 'verified'
  vi.mocked(get).mockResolvedValueOnce(data).mockRejectedValueOnce(new Error('private-server-diagnostic'))
  render(html`<${SandboxSetupCatalog} />`)
  await screen.findByText(/sandbox 상태를 확인하지 못했습니다/)
  expect(screen.queryByText(/서비스 감지됨/)).toBeNull()
  fireEvent.click(screen.getByText('sandbox 상태 새로고침'))
  await screen.findByText(/sandbox 상태를 확인하지 못했습니다/)
  expect(document.body.textContent).not.toContain('private-server-diagnostic')
})
