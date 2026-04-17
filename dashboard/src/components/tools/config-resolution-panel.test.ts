import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { DashboardRuntimeDiagnostic } from '../../api/dashboard'
import { ConfigResolutionPanel, filterDiagnostics } from './config-resolution-panel'

function diag(
  kind: string,
  message: string,
  signal?: string,
  ts = '2026-04-17T00:00:00Z',
): DashboardRuntimeDiagnostic {
  return signal === undefined ? { ts, kind, message } : { ts, kind, message, signal }
}

async function flush(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

describe('ConfigResolutionPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            generated_at: '2026-04-10T00:00:00Z',
            cache_hit: true,
            cache_age_sec: 3.2,
            probe: {
              source: 'ollama native runtime',
              effective_model: 'qwen3.5:35b-a3b-coding-nvfp4',
              server_url: 'http://127.0.0.1:11434',
              model_loaded_before_probe: true,
              model_loaded_after_probe: true,
              loaded_models_after: [{ name: 'qwen3.5:35b-a3b-coding-nvfp4' }],
              runs: [
                {
                  load_duration_ms: 33.6,
                  prompt_tokens_per_second: 26.1,
                  generation_tokens_per_second: 65.5,
                },
              ],
              kv_cache_assessment: {
                signal: 'likely_reused',
                note: 'Prompt evaluation time dropped materially on a repeated prompt.',
                prompt_eval_duration_reduction_ratio: 0.42,
              },
              observations: ['Repeated prompt_eval_duration_ms dropped enough to suggest repeated-prefix reuse.'],
              errors: [],
              probe_ok: true,
            },
          }),
          {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          },
        ),
      ),
    )
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.unstubAllGlobals()
  })

  it('renders resolved paths, root-relative config paths, and runtime diagnostics', async () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'warn',
          warnings: ['Resolved config child is missing: keepers'],
          config_root: { path: '/tmp/runtime/config', exists: true, source: 'env' },
          cascade: { path: '/tmp/runtime/config/cascade.json', exists: true, source: 'env' },
          prompts: { path: '/tmp/runtime/config/prompts', exists: true, source: 'env' },
          keepers: { path: '/tmp/runtime/config/keepers', exists: false, source: 'env' },
          personas: { path: '/tmp/custom-personas', exists: false, source: 'invalid_env' },
        }}
        runtimeResolution=${{
          status: 'warn',
          warnings: ['Runtime build commit (deadbee) differs from workspace HEAD (cafef00d).'],
          base_path: { path: '/tmp/runtime-input', exists: true, source: 'input' },
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

    await flush()

    expect(container.textContent).toContain('설정 경로')
    expect(container.textContent).toContain('/tmp/runtime/config')
    expect(container.textContent).toContain('env override')
    expect(container.textContent).toContain('Resolved config child is missing: keepers')
    expect(container.textContent).toContain('cascade.json')
    expect(container.textContent).toContain('root-relative')
    expect(container.textContent).toContain('under config root')
    expect(container.textContent).not.toContain('/tmp/runtime/config/cascade.json')
    expect(container.textContent).toContain('/tmp/custom-personas')
    expect(container.textContent).toContain('invalid env')
    expect(container.textContent).toContain('/tmp/workspace/.masc')
    expect(container.textContent).toContain('/tmp/shared/prompts')
    expect(container.textContent).toContain('source mismatch')
    expect(container.textContent).toContain('SIGTERM')
    expect(container.textContent).toContain('Runtime build commit (deadbee) differs from workspace HEAD (cafef00d).')
    expect(container.textContent).toContain('ollama warm / kv probe')
    expect(container.textContent).toContain('kv likely reused')
    expect(container.textContent).toContain('qwen3.5:35b-a3b-coding-nvfp4')
  })
  it('keeps the full path on hover title and hides duplicate source badges', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/root-config', exists: true, source: 'env' },
          cascade: { path: '/tmp/root-config/cascade.json', exists: true, source: 'env' },
          prompts: { path: '/tmp/root-config/prompts', exists: true, source: 'env' },
          keepers: { path: '/tmp/root-config/keepers', exists: true, source: 'cwd' },
          personas: { path: '/tmp/root-config/personas', exists: true, source: 'env' },
        }}
      />`,
      container,
    )

    const cards = Array.from(container.querySelectorAll('[title]'))
    expect(cards.map(card => card.getAttribute('title'))).toContain('/tmp/root-config/cascade.json')
    expect(cards.map(card => card.getAttribute('title'))).toContain('/tmp/root-config')
    expect(container.textContent?.match(/env override/g)?.length ?? 0).toBe(1)
    expect(container.textContent).toContain('cwd fallback')
  })

  it('does not collapse sibling paths that only share the root prefix', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/root', exists: true, source: 'env' },
          cascade: { path: '/tmp/root/cascade.json', exists: true, source: 'env' },
          prompts: { path: '/tmp/root/prompts', exists: true, source: 'env' },
          keepers: { path: '/tmp/root/keepers', exists: true, source: 'env' },
          personas: { path: '/tmp/root-extra/personas', exists: true, source: 'env' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('/tmp/root-extra/personas')
    expect(container.textContent).toContain('outside config root')
  })

  it('renders the same-as-root case without repeating the full path', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/root', exists: true, source: 'env' },
          cascade: { path: '/tmp/root', exists: true, source: 'env' },
          prompts: { path: '/tmp/root/prompts', exists: true, source: 'env' },
          keepers: { path: '/tmp/root/keepers', exists: true, source: 'env' },
          personas: { path: '/tmp/root/personas', exists: true, source: 'env' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('same as config root')
    expect(container.textContent).toContain('.')
  })

  it('treats slash root as a valid root-relative prefix', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/', exists: true, source: 'cwd' },
          cascade: { path: '/etc/cascade.json', exists: true, source: 'cwd' },
          prompts: { path: '/var/prompts', exists: true, source: 'cwd' },
          keepers: { path: '/opt/keepers', exists: true, source: 'cwd' },
          personas: { path: '/srv/personas', exists: true, source: 'cwd' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('etc/cascade.json')
    expect(container.textContent).toContain('root-relative')
  })

  it('renders home config source label', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/home/test/.masc/config', exists: true, source: 'home_masc' },
          cascade: { path: '/home/test/.masc/config/cascade.json', exists: true, source: 'home_masc' },
          prompts: { path: '/home/test/.masc/config/prompts', exists: true, source: 'home_masc' },
          keepers: { path: '/home/test/.masc/config/keepers', exists: true, source: 'home_masc' },
          personas: { path: '/home/test/.masc/config/personas', exists: true, source: 'home_masc' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('home config')
    expect(container.textContent).toContain('/home/test/.masc/config')
  })

  it('renders local .masc source label', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/project/.masc/config', exists: true, source: 'local_masc' },
          cascade: { path: '/tmp/project/.masc/config/cascade.json', exists: true, source: 'local_masc' },
          prompts: { path: '/tmp/project/.masc/config/prompts', exists: true, source: 'local_masc' },
          keepers: { path: '/tmp/project/.masc/config/keepers', exists: true, source: 'local_masc' },
          personas: { path: '/tmp/project/.masc/config/personas', exists: true, source: 'local_masc' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('local .masc')
    expect(container.textContent).toContain('/tmp/project/.masc/config')
  })
})

describe('filterDiagnostics', () => {
  const sample: readonly DashboardRuntimeDiagnostic[] = [
    diag('external_signal', 'Received SIGTERM, shutting down server.', 'SIGTERM'),
    diag('external_signal', 'Received SIGINT from operator.', 'SIGINT'),
    diag('config_drift', 'Runtime build commit (deadbee) differs from workspace HEAD (cafef00d).'),
    diag('keeper_heartbeat', 'keeper stale for 42s', 'heartbeat_stale'),
  ]

  it('returns the input reference when the query is empty', () => {
    expect(filterDiagnostics(sample, '')).toBe(sample)
  })

  it('returns the input reference when the query is whitespace-only', () => {
    expect(filterDiagnostics(sample, '   ')).toBe(sample)
  })

  it('trims the query before matching', () => {
    const result = filterDiagnostics(sample, '  SIGTERM  ')
    expect(result).toHaveLength(1)
    expect(result[0]?.signal).toBe('SIGTERM')
  })

  it('matches kind case-insensitively', () => {
    const result = filterDiagnostics(sample, 'EXTERNAL_signal')
    expect(result).toHaveLength(2)
  })

  it('matches signal case-insensitively', () => {
    const result = filterDiagnostics(sample, 'sigint')
    expect(result).toHaveLength(1)
    expect(result[0]?.signal).toBe('SIGINT')
  })

  it('matches substring in the message body', () => {
    const result = filterDiagnostics(sample, 'deadbee')
    expect(result).toHaveLength(1)
    expect(result[0]?.kind).toBe('config_drift')
  })

  it('returns an empty array when nothing matches', () => {
    expect(filterDiagnostics(sample, 'no-such-term-xyz')).toEqual([])
  })

  it('skips undefined signal fields without crashing', () => {
    const result = filterDiagnostics(sample, 'heartbeat')
    // kind match ("keeper_heartbeat") + signal match ("heartbeat_stale") on the same row
    expect(result).toHaveLength(1)
    expect(result[0]?.kind).toBe('keeper_heartbeat')
  })

  it('returns an empty array when the input is empty', () => {
    expect(filterDiagnostics([], 'anything')).toEqual([])
  })

  it('does not mutate the input array', () => {
    const before = sample.map(item => ({ ...item }))
    filterDiagnostics(sample, 'sigterm')
    expect(sample).toEqual(before)
    expect(sample).toHaveLength(4)
  })
})
