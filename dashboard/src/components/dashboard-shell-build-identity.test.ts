// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'

import { serverStatus } from '../store'
import { BuildIdentityBadge } from './dashboard-shell'

describe('BuildIdentityBadge executable identity', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    serverStatus.value = null
  })

  it('does not present a runtime checkout fallback as the binary commit', () => {
    serverStatus.value = {
      version: '0.22.0',
      build: {
        release_version: '0.22.0',
        commit: '13dd32a37a',
        commit_source: 'runtime_repo_head',
        binary_commit: null,
        binary_commit_source: null,
        repo_head_commit: '13dd32a37a',
        repo_head_commit_source: 'runtime_repo_head',
        started_at: '2026-08-14T02:07:29Z',
        uptime_seconds: 19,
      },
    }

    render(h(BuildIdentityBadge, {}), container)

    const button = container.querySelector('button')
    expect(button?.textContent).toContain('v0.22.0 · binary unknown')
    expect(button?.getAttribute('aria-label')).toBe('Server build v0.22.0 · binary unknown')
    expect(button?.getAttribute('title')).toContain('binary commit unknown')
    expect(button?.getAttribute('title')).toContain('Checkout 13dd32a37a')
  })

  it('shows the exact binary commit when deployment provenance is present', () => {
    serverStatus.value = {
      version: '0.22.0',
      build: {
        release_version: '0.22.0',
        commit: '0123456789abcdef',
        commit_source: 'embedded',
        binary_commit: '0123456789abcdef',
        binary_commit_source: 'embedded',
        repo_head_commit: 'fedcba9876543210',
        repo_head_commit_source: 'runtime_repo_head',
        started_at: '2026-08-14T02:07:29Z',
        uptime_seconds: 19,
      },
    }

    render(h(BuildIdentityBadge, {}), container)

    const button = container.querySelector('button')
    expect(button?.textContent).toContain('v0.22.0 · 0123456789')
    expect(button?.getAttribute('title')).toContain('v0.22.0 · 0123456789')
    expect(button?.getAttribute('title')).toContain('Checkout fedcba9876')
  })

  it('does not infer a dev binary when the build payload is unavailable', () => {
    serverStatus.value = { version: '0.22.0' }

    render(h(BuildIdentityBadge, {}), container)

    const button = container.querySelector('button')
    expect(button?.textContent).toContain('v0.22.0 · binary unknown')
    expect(button?.getAttribute('aria-label')).toBe('Server build v0.22.0 · binary unknown')
    expect(button?.getAttribute('title')).toContain('binary commit unknown')
  })
})
