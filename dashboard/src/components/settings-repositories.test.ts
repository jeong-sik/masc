// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'

const fetchRepositoriesList = vi.fn()
const addRepository = vi.fn()
const removeRepository = vi.fn()
const requestConfirm = vi.fn()
const showToast = vi.fn()

vi.mock('../api/repositories', () => ({
  fetchRepositoriesList: (...args: unknown[]) => fetchRepositoriesList(...args),
  addRepository: (...args: unknown[]) => addRepository(...args),
  removeRepository: (...args: unknown[]) => removeRepository(...args),
}))
vi.mock('./common/confirm-dialog', () => ({
  requestConfirm: (...args: unknown[]) => requestConfirm(...args),
}))
vi.mock('./common/toast', () => ({
  showToast: (...args: unknown[]) => showToast(...args),
}))

import {
  SettingsRepositoriesSection,
  refreshSettingsRepositories,
  _resetSettingsRepositoriesForTests,
} from './settings-repositories'

const REPO_MASC = {
  id: 'masc',
  name: 'masc',
  url: 'https://github.com/jeong-sik/masc.git',
  local_path: '.masc/repos/masc',
  default_branch: 'main',
  status: 'active',
  auto_sync: true,
  sync_interval: 300,
  created_at: null,
  updated_at: null,
}

const REPO_MANUAL = {
  ...REPO_MASC,
  id: 'oas',
  name: 'oas',
  url: 'https://github.com/jeong-sik/oas.git',
  auto_sync: false,
}

async function flush(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

describe('SettingsRepositoriesSection', () => {
  let container: HTMLElement

  beforeEach(async () => {
    vi.clearAllMocks()
    _resetSettingsRepositoriesForTests()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  async function mount(repos: unknown[] | Error = [REPO_MASC, REPO_MANUAL]): Promise<void> {
    if (repos instanceof Error) fetchRepositoriesList.mockRejectedValue(repos)
    else fetchRepositoriesList.mockResolvedValue(repos)
    await refreshSettingsRepositories()
    render(html`<${SettingsRepositoriesSection} />`, container)
    await flush()
  }

  it('renders live repositories with branch pill and sync posture', async () => {
    await mount()

    const rows = container.querySelectorAll('[data-testid="settings-repo-row"]')
    expect(rows).toHaveLength(2)

    const first = rows[0]!
    expect(first.getAttribute('data-repo-id')).toBe('masc')
    expect(first.querySelector('.set-repo-name')?.textContent).toContain('masc')
    expect(first.querySelector('.set-repo-branch')?.textContent).toBe('main')
    expect(first.querySelector('.set-repo-url')?.textContent).toBe('https://github.com/jeong-sik/masc.git')
    expect(first.querySelector('.set-repo-sync')?.classList.contains('on')).toBe(true)
    expect(first.querySelector('.set-repo-sync')?.textContent).toBe('자동 · 300s')

    const second = rows[1]!
    expect(second.querySelector('.set-repo-sync')?.classList.contains('on')).toBe(false)
    expect(second.querySelector('.set-repo-sync')?.textContent).toBe('수동')
  })

  it('renders the empty state without inventing rows', async () => {
    await mount([])

    expect(container.querySelector('[data-testid="settings-repos-empty"]')?.textContent)
      .toBe('등록된 저장소 없음')
    expect(container.querySelectorAll('[data-testid="settings-repo-row"]')).toHaveLength(0)
  })

  it('surfaces list load failures instead of rendering an empty list', async () => {
    await mount(new Error('boom'))

    const error = container.querySelector('[data-testid="settings-repos-error"]')
    expect(error).not.toBeNull()
    expect(error?.textContent).toContain('boom')
    expect(container.querySelector('[data-testid="settings-repo-list"]')).toBeNull()
  })

  it('keeps submit disabled until name and url are present', async () => {
    await mount([])

    ;(container.querySelector('[data-testid="settings-repo-add"]') as HTMLButtonElement).click()
    await flush()

    const submit = () => container.querySelector('[data-testid="settings-repo-form-submit"]') as HTMLButtonElement
    expect(submit().disabled).toBe(true)

    const nameInput = container.querySelector('[data-testid="settings-repo-name-input"]') as HTMLInputElement
    nameInput.value = 'my-project'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    expect(submit().disabled).toBe(true)

    const urlInput = container.querySelector('[data-testid="settings-repo-url-input"]') as HTMLInputElement
    urlInput.value = 'https://github.com/o/r.git'
    urlInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    expect(submit().disabled).toBe(false)
  })

  it('submits the add-repo payload with clamped interval and omitted empty local_path', async () => {
    addRepository.mockResolvedValue(undefined)
    await mount([])

    ;(container.querySelector('[data-testid="settings-repo-add"]') as HTMLButtonElement).click()
    await flush()

    const type = (testid: string, value: string) => {
      const input = container.querySelector(`[data-testid="${testid}"]`) as HTMLInputElement
      input.value = value
      input.dispatchEvent(new Event('input', { bubbles: true }))
    }
    type('settings-repo-name-input', ' my-project ')
    type('settings-repo-url-input', ' https://github.com/o/r.git ')
    type('settings-repo-branch-input', '')
    await flush()

    for (let i = 0; i < 10; i += 1) {
      const minus = container.querySelector('[data-testid="settings-repo-interval-stepper"] button') as HTMLButtonElement
      minus.click()
      await flush()
    }
    expect(container.querySelector('[data-testid="settings-repo-interval-value"]')?.textContent).toBe('60')

    ;(container.querySelector('[data-testid="settings-repo-form-submit"]') as HTMLButtonElement).click()
    await flush()

    expect(addRepository).toHaveBeenCalledWith({
      name: 'my-project',
      url: 'https://github.com/o/r.git',
      default_branch: 'main',
      auto_sync: true,
      sync_interval: 60,
    })
    expect(fetchRepositoriesList.mock.calls.length).toBeGreaterThanOrEqual(2)
    expect(container.querySelector('[data-testid="settings-repo-form"]')).toBeNull()
  })

  it('shows a visible form error when registration fails', async () => {
    addRepository.mockRejectedValue(new Error('clone failed'))
    await mount([])

    ;(container.querySelector('[data-testid="settings-repo-add"]') as HTMLButtonElement).click()
    await flush()
    const type = (testid: string, value: string) => {
      const input = container.querySelector(`[data-testid="${testid}"]`) as HTMLInputElement
      input.value = value
      input.dispatchEvent(new Event('input', { bubbles: true }))
    }
    type('settings-repo-name-input', 'p')
    type('settings-repo-url-input', 'https://x/y.git')
    await flush()

    ;(container.querySelector('[data-testid="settings-repo-form-submit"]') as HTMLButtonElement).click()
    await flush()

    const error = container.querySelector('[data-testid="settings-repo-form-error"]')
    expect(error?.textContent).toBe('clone failed')
    expect(container.querySelector('[data-testid="settings-repo-form"]')).not.toBeNull()
    expect(showToast).toHaveBeenCalledWith('clone failed', 'error')
  })

  it('hides the interval stepper when auto sync is toggled off', async () => {
    await mount([])

    ;(container.querySelector('[data-testid="settings-repo-add"]') as HTMLButtonElement).click()
    await flush()
    expect(container.querySelector('[data-testid="settings-repo-interval-stepper"]')).not.toBeNull()

    ;(container.querySelector('[data-testid="settings-repo-autosync-toggle"]') as HTMLButtonElement).click()
    await flush()
    expect(container.querySelector('[data-testid="settings-repo-interval-stepper"]')).toBeNull()
  })

  it('deletes a repository only after operator confirmation', async () => {
    requestConfirm.mockResolvedValue(true)
    removeRepository.mockResolvedValue(undefined)
    await mount()

    const del = container.querySelector('[data-repo-id="masc"] .set-repo-del') as HTMLButtonElement
    del.click()
    await flush()

    expect(requestConfirm).toHaveBeenCalledWith(expect.objectContaining({ tone: 'danger' }))
    expect(removeRepository).toHaveBeenCalledWith('masc')
    expect(fetchRepositoriesList.mock.calls.length).toBeGreaterThanOrEqual(2)
  })

  it('does not delete when the confirmation is declined', async () => {
    requestConfirm.mockResolvedValue(false)
    await mount()

    const del = container.querySelector('[data-repo-id="masc"] .set-repo-del') as HTMLButtonElement
    del.click()
    await flush()

    expect(removeRepository).not.toHaveBeenCalled()
  })
})
