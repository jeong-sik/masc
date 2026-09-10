import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { get, postControlPlane } from '../api/core'
import { SandboxSetupCatalog } from './sandbox-setup-catalog'

vi.mock('../api/core', () => ({ get: vi.fn(), postControlPlane: vi.fn() }))
vi.mock('../api/keeper-lifecycle', () => ({ bootKeeper: vi.fn() }))
vi.mock('../lib/model-setup-resume', () => ({ resumeSavedModelSetup: vi.fn() }))
import { bootKeeper } from '../api/keeper-lifecycle'
import { resumeSavedModelSetup } from '../lib/model-setup-resume'
afterEach(() => { cleanup(); vi.resetAllMocks() })
const row = (id: string, advanced: boolean, configured = false) => ({ id, advanced, configured, recommended: configured,
  state: 'service_ready', reason: 'service observed', guest_verification: 'not_run', capabilities: { network_modes: ['inherit', 'none'] } })
const catalog = () => ({ schema: 'masc.sandbox_readiness.v1', selection_revision: 'fixture-revision', configuration_error: null,
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

it('lets a timed-out observation retry without inferring an authentication failure', async () => {
  vi.mocked(get).mockRejectedValueOnce(new Error('Request timed out')).mockResolvedValueOnce(catalog())
  render(html`<${SandboxSetupCatalog} />`)
  await screen.findByText(/서버 연결과 sandbox 실행 도구의 상태를 확인한 뒤 다시 시도하세요/)
  expect(document.body.textContent).not.toContain('로그인')
  fireEvent.click(screen.getByText('sandbox 상태 새로고침'))
  await screen.findByText(/서비스 감지됨 · guest 준비와 실행 확인 필요/)
  expect(screen.queryByText(/sandbox 상태를 확인하지 못했습니다/)).toBeNull()
})

it('prepares chosen sandbox before existing model resume and boot, keeping saved result when boot fails', async () => {
  vi.mocked(get).mockResolvedValue(catalog())
  vi.mocked(postControlPlane).mockResolvedValue({ schema: 'masc.sandbox_preparation.v1', configuration_saved: true, image_prepared: true,
    backend: 'docker', network_mode: 'none', model_verification: 'not_run', guest_verification: 'not_run' })
  vi.mocked(resumeSavedModelSetup).mockResolvedValue({ kind: 'active', exactOutputAvailable: false })
  vi.mocked(bootKeeper).mockResolvedValue({ ok: false, error: 'fixture-private-diagnostic' })
  render(html`<${SandboxSetupCatalog} />`)
  fireEvent.click(await screen.findByText('Docker 선택'))
  fireEvent.change(screen.getByLabelText('선택한 sandbox 네트워크'), { target: { value: 'none' } })
  fireEvent.click(screen.getByText('sandbox 준비 후 imp 시작'))
  await screen.findByText(/sandbox 준비·저장은 완료했지만 imp 시작을 확인하지 못했습니다/)
  expect(postControlPlane).toHaveBeenCalledWith('/api/v1/setup/sandbox/prepare', { backend: 'docker', network_mode: 'none', revision: 'fixture-revision' })
  expect(vi.mocked(resumeSavedModelSetup).mock.invocationCallOrder[0]).toBeGreaterThan(vi.mocked(postControlPlane).mock.invocationCallOrder[0]!)
  expect(vi.mocked(bootKeeper).mock.invocationCallOrder[0]).toBeGreaterThan(vi.mocked(resumeSavedModelSetup).mock.invocationCallOrder[0]!)
  expect(document.body.textContent).not.toContain('fixture-private-diagnostic')
})
it('does not boot after an unconfirmed prepare and clears selection when refreshed', async () => {
  vi.mocked(get).mockResolvedValue(catalog())
  vi.mocked(postControlPlane).mockRejectedValue(new Error('private refusal'))
  render(html`<${SandboxSetupCatalog} />`)
  fireEvent.click(await screen.findByText('Docker 선택'))
  fireEvent.click(screen.getByText('sandbox 준비 후 imp 시작'))
  await screen.findByText(/sandbox 준비 결과를 확인하지 못했습니다/)
  expect(bootKeeper).not.toHaveBeenCalled(); expect(resumeSavedModelSetup).not.toHaveBeenCalled()
  fireEvent.click(screen.getByText('sandbox 상태 새로고침'))
  await waitFor(() => expect(screen.queryByText('sandbox 준비 후 imp 시작')).toBeNull())
})
