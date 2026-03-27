import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { ConfigResolutionPanel } from './config-resolution-panel'

describe('ConfigResolutionPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders resolved paths and warnings', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'warn',
          warnings: ['Using legacy config fallback from ME_ROOT-style path: /tmp/legacy/config'],
          config_root: { path: '/tmp/legacy/config', exists: true, source: 'legacy_me_root' },
          cascade: { path: '/tmp/legacy/config/cascade.json', exists: true, source: 'legacy_me_root' },
          prompts: { path: '/tmp/legacy/config/prompts', exists: true, source: 'legacy_me_root' },
          keepers: { path: '/tmp/legacy/config/keepers', exists: false, source: 'legacy_me_root' },
          personas: { path: '/tmp/custom-personas', exists: false, source: 'invalid_env' },
        }}
        runtimeResolution=${{
          status: 'warn',
          warnings: ['Runtime build commit (deadbee) differs from workspace HEAD (cafef00d).'],
          base_path_input: { path: '/tmp/runtime-input', exists: true, source: 'input' },
          workspace_path: { path: '/tmp/workspace', exists: true, source: 'workspace' },
          resolved_base_path: { path: '/tmp/workspace', exists: true, source: 'resolved_base' },
          data_root: { path: '/tmp/workspace/.masc', exists: true, source: 'runtime_data' },
          prompt_markdown_dir: { path: '/tmp/shared/prompts', exists: true, source: 'prompt_registry' },
          workspace_git_commit: 'cafef00d',
          resolved_base_git_commit: 'cafef00d',
          source_mismatch: true,
          diagnostics: [
            {
              ts: '2026-03-27T00:00:00Z',
              kind: 'external_signal',
              signal: 'SIGTERM',
              message: 'Received SIGTERM, shutting down server.',
            },
          ],
          build: {
            release_version: 'dev',
            commit: 'deadbee',
            started_at: '2026-03-27T00:00:00Z',
            uptime_seconds: 42,
          },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('설정 경로')
    expect(container.textContent).toContain('/tmp/legacy/config')
    expect(container.textContent).toContain('Using legacy config fallback from ME_ROOT-style path')
    expect(container.textContent).toContain('/tmp/custom-personas')
    expect(container.textContent).toContain('INVALID ENV')
    expect(container.textContent).toContain('/tmp/workspace/.masc')
    expect(container.textContent).toContain('/tmp/shared/prompts')
    expect(container.textContent).toContain('source mismatch')
    expect(container.textContent).toContain('SIGTERM')
    expect(container.textContent).toContain('Runtime build commit (deadbee) differs from workspace HEAD (cafef00d).')
  })
})
