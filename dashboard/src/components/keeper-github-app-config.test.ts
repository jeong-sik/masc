import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { KeeperGithubAppConfigPanel } from './keeper-github-app-config'
import type { KeeperSecretProjection } from '../api/schemas/keeper-composite'

describe('KeeperGithubAppConfigPanel', () => {
  const mockProjectionEmpty: KeeperSecretProjection = {
    status: 'ready',
    configured: true,
    root: '/mock/workspace/.masc/secrets/sangsu',
    source: 'workspace_masc_secrets',
    effective_roots: [],
    env_count: 0,
    file_count: 0,
    env_names: [],
    file_mounts: [],
    values_validated: true,
    error: null,
    next_action: 'none',
  }

  const mockProjectionConfigured: KeeperSecretProjection = {
    status: 'ready',
    configured: true,
    root: '/mock/workspace/.masc/secrets/sangsu',
    source: 'workspace_masc_secrets',
    effective_roots: [],
    env_count: 2,
    file_count: 1,
    env_names: ['MASC_GITHUB_APP_ID', 'MASC_GITHUB_APP_INSTALLATION_ID'],
    file_mounts: [
      {
        host_path: '/mock/workspace/.masc/secrets/sangsu/files/github-app/private-key.pem',
        container_path: '/github-app/private-key.pem',
      },
    ],
    values_validated: true,
    error: null,
    next_action: 'none',
  }

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  it('renders correctly when credentials are not configured', () => {
    render(h(KeeperGithubAppConfigPanel, {
      projection: mockProjectionEmpty,
      keeperName: 'sangsu',
    }))

    expect(screen.getByTestId('keeper-github-app-config-panel')).toBeInTheDocument()
    expect(screen.getAllByText('Not Configured').length).toBe(2)
    expect(screen.getByText('Not Uploaded')).toBeInTheDocument()
  })

  it('renders correctly when credentials are configured', () => {
    render(h(KeeperGithubAppConfigPanel, {
      projection: mockProjectionConfigured,
      keeperName: 'sangsu',
    }))

    expect(screen.getByText('configured / unvalidated')).toBeInTheDocument()
    expect(screen.queryByText('active')).not.toBeInTheDocument()
    expect(screen.getAllByText('Configured').length).toBe(2)
    expect(screen.getByText('Uploaded')).toBeInTheDocument()
  })

  it('calls setSecretEnv and setSecretFile when form is submitted', async () => {
    const setSecretEnv = vi.fn().mockResolvedValue(mockProjectionConfigured)
    const setSecretFile = vi.fn().mockResolvedValue(mockProjectionConfigured)
    const onProjectionChange = vi.fn()

    const { container } = render(h(KeeperGithubAppConfigPanel, {
      projection: mockProjectionEmpty,
      keeperName: 'sangsu',
      setSecretEnv,
      setSecretFile,
      onProjectionChange,
    }))

    // Fill in App ID
    const appIdInput = screen.getByLabelText('GitHub App ID')
    fireEvent.input(appIdInput, { target: { value: '123456' } })

    // Fill in Installation ID
    const instIdInput = screen.getByLabelText('GitHub App Installation ID')
    fireEvent.input(instIdInput, { target: { value: '7891011' } })

    // Fill in PEM
    const pemInput = screen.getByLabelText('GitHub App Private Key PEM')
    fireEvent.input(pemInput, { target: { value: '-----BEGIN RSA PRIVATE KEY-----\npem-content\n-----END RSA PRIVATE KEY-----' } })

    // Submit form directly to bypass happy-dom submit limitation
    const form = container.querySelector('form')
    expect(form).not.toBeNull()
    fireEvent.submit(form!)

    await waitFor(() => {
      expect(setSecretEnv).toHaveBeenCalledTimes(2)
      expect(setSecretFile).toHaveBeenCalledTimes(1)
      expect(onProjectionChange).toHaveBeenCalledWith(mockProjectionConfigured)
    })

    expect(setSecretEnv).toHaveBeenNthCalledWith(1, 'sangsu', {
      scope: 'keeper',
      name: 'MASC_GITHUB_APP_ID',
      value: '123456',
    })

    expect(setSecretEnv).toHaveBeenNthCalledWith(2, 'sangsu', {
      scope: 'keeper',
      name: 'MASC_GITHUB_APP_INSTALLATION_ID',
      value: '7891011',
    })

    expect(setSecretFile).toHaveBeenCalledWith('sangsu', {
      scope: 'keeper',
      path: '/github-app/private-key.pem',
      value: '-----BEGIN RSA PRIVATE KEY-----\npem-content\n-----END RSA PRIVATE KEY-----',
    })
  })

  it('rejects partial bundle saves before mutating keeper secrets', async () => {
    const setSecretEnv = vi.fn().mockResolvedValue(mockProjectionConfigured)
    const setSecretFile = vi.fn().mockResolvedValue(mockProjectionConfigured)

    const { container } = render(h(KeeperGithubAppConfigPanel, {
      projection: mockProjectionEmpty,
      keeperName: 'sangsu',
      setSecretEnv,
      setSecretFile,
    }))

    fireEvent.input(screen.getByLabelText('GitHub App ID'), { target: { value: '123456' } })

    const form = container.querySelector('form')
    expect(form).not.toBeNull()
    fireEvent.submit(form!)

    await waitFor(() => {
      expect(screen.getByText('GitHub App credentials must be saved as a complete bundle.')).toBeInTheDocument()
    })
    expect(setSecretEnv).not.toHaveBeenCalled()
    expect(setSecretFile).not.toHaveBeenCalled()
  })

  it('rolls back applied bundle fields when a later save step fails', async () => {
    const partialProjection: KeeperSecretProjection = {
      ...mockProjectionEmpty,
      env_count: 1,
      env_names: ['MASC_GITHUB_APP_ID'],
    }
    const setSecretEnv = vi
      .fn()
      .mockResolvedValueOnce(partialProjection)
      .mockRejectedValueOnce(new Error('installation write failed'))
    const setSecretFile = vi.fn().mockResolvedValue(mockProjectionConfigured)
    const deleteSecretEnv = vi.fn().mockResolvedValue(mockProjectionEmpty)
    const deleteSecretFile = vi.fn().mockResolvedValue(mockProjectionEmpty)
    const onProjectionChange = vi.fn()

    const { container } = render(h(KeeperGithubAppConfigPanel, {
      projection: mockProjectionEmpty,
      keeperName: 'sangsu',
      setSecretEnv,
      setSecretFile,
      deleteSecretEnv,
      deleteSecretFile,
      onProjectionChange,
    }))

    fireEvent.input(screen.getByLabelText('GitHub App ID'), { target: { value: '123456' } })
    fireEvent.input(screen.getByLabelText('GitHub App Installation ID'), { target: { value: '7891011' } })
    fireEvent.input(screen.getByLabelText('GitHub App Private Key PEM'), {
      target: { value: '-----BEGIN RSA PRIVATE KEY-----\npem-content\n-----END RSA PRIVATE KEY-----' },
    })

    const form = container.querySelector('form')
    expect(form).not.toBeNull()
    fireEvent.submit(form!)

    await waitFor(() => {
      expect(screen.getByText(/installation write failed/)).toBeInTheDocument()
      expect(screen.getByText(/Partially written GitHub App credentials were purged/)).toBeInTheDocument()
    })

    expect(setSecretEnv).toHaveBeenCalledTimes(2)
    expect(setSecretFile).not.toHaveBeenCalled()
    expect(deleteSecretEnv).toHaveBeenCalledTimes(1)
    expect(deleteSecretEnv).toHaveBeenCalledWith('sangsu', {
      scope: 'keeper',
      name: 'MASC_GITHUB_APP_ID',
    })
    expect(deleteSecretFile).not.toHaveBeenCalled()
    expect(onProjectionChange).toHaveBeenCalledWith(mockProjectionEmpty)
  })

  it('calls deleteSecretEnv and deleteSecretFile when purge is clicked', async () => {
    const deleteSecretEnv = vi.fn().mockResolvedValue(mockProjectionEmpty)
    const deleteSecretFile = vi.fn().mockResolvedValue(mockProjectionEmpty)
    const onProjectionChange = vi.fn()

    // Mock confirm dialog globally using stubGlobal
    const confirmMock = vi.fn().mockReturnValue(true)
    vi.stubGlobal('confirm', confirmMock)

    render(h(KeeperGithubAppConfigPanel, {
      projection: mockProjectionConfigured,
      keeperName: 'sangsu',
      deleteSecretEnv,
      deleteSecretFile,
      onProjectionChange,
    }))

    const purgeBtn = screen.getByText('Purge Credentials')
    fireEvent.click(purgeBtn)

    await waitFor(() => {
      expect(confirmMock).toHaveBeenCalled()
      expect(deleteSecretEnv).toHaveBeenCalledTimes(2)
      expect(deleteSecretFile).toHaveBeenCalledTimes(1)
      expect(onProjectionChange).toHaveBeenCalledWith(mockProjectionEmpty)
    })
  })
})
