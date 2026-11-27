// @vitest-environment jsdom

import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { parseRuntimeResolvedResponse } from '../../api/schemas/runtime-resolved'
import { authSession, bumpSessionEpoch } from '../../core/auth'
import { resourceCache } from '../../core/resource-cache'
import { SettingsWorkspace } from '../settings/index'
import {
  parseRuntimeMediaOverridesFromToml,
  upsertRuntimeMediaOverridesInToml,
} from './lane-toml-editor'
import { LanesTab } from './lanes-tab'
import {
  resolveLaneMediaCapabilities,
  resolveRuntimeMediaCapabilities,
  type RuntimeResolution,
} from './types'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  resourceCache.clearAll()
})

describe('Runtime derived Vision / Image Gen capabilities & [runtime.media] overrides (zero media_failover)', () => {
  it('parses derived capabilities and optional [runtime.media] from /api/v1/runtime/resolved', () => {
    const parsed = parseRuntimeResolvedResponse({
      config_path: '/cfg/runtime.toml',
      default_route: 'coding',
      default_runtime: {
        id: 'openai.gpt-4o',
        provider: 'OpenAI',
        provider_id: 'openai',
        model: 'gpt-4o',
        effective_max_context: 128000,
        max_context_source: 'capability',
        max_output_tokens: 16384,
        is_local: false,
        is_default: true,
        quota_rest: null,
        capabilities: { supports_image_input: true, supports_image_output: true },
      },
      runtimes: [
        {
          id: 'openai.gpt-4o',
          provider: 'OpenAI',
          provider_id: 'openai',
          model: 'gpt-4o',
          effective_max_context: 128000,
          max_context_source: 'capability',
          max_output_tokens: 16384,
          is_local: false,
          is_default: true,
          quota_rest: null,
          capabilities: { supports_image_input: true, supports_image_output: true },
        },
        {
          id: 'anthropic.sonnet',
          provider: 'Anthropic',
          provider_id: 'anthropic',
          model: 'claude-sonnet-4',
          effective_max_context: 200000,
          max_context_source: 'capability',
          max_output_tokens: 8192,
          is_local: false,
          is_default: false,
          quota_rest: null,
          capabilities: { vision_input: true, image_output: false },
        },
      ],
      lanes: [{ id: 'coding', declared: true, runtime_ids: ['anthropic.sonnet', 'openai.gpt-4o'] }],
      assignments: [],
      media: { vision_reader: null, image_generator: 'openai.gpt-4o' },
    })

    expect(parsed.media).toEqual({ vision_reader: null, image_generator: 'openai.gpt-4o' })
    const map = new Map<string, RuntimeResolution>(parsed.runtimes.map((r) => [r.id, r]))
    expect(resolveRuntimeMediaCapabilities(map.get('openai.gpt-4o'))).toEqual({ visionInput: true, imageOutput: true })
    expect(resolveRuntimeMediaCapabilities(map.get('anthropic.sonnet'))).toEqual({ visionInput: true, imageOutput: false })
    expect(resolveLaneMediaCapabilities(['anthropic.sonnet', 'openai.gpt-4o'], map)).toEqual({ visionInput: true, imageOutput: true })
  })

  it('parses, upserts, and removes optional [runtime.media] TOML overrides cleanly without media_failover', () => {
    const baseToml = `[runtime]\ndefault = "openai.gpt-4o"\n\n[runtime.lanes.coding]\ncandidates = ["openai.gpt-4o"]\n`
    expect(parseRuntimeMediaOverridesFromToml(baseToml)).toEqual({ visionReader: null, imageGenerator: null })

    const added = upsertRuntimeMediaOverridesInToml(baseToml, {
      visionReader: 'anthropic.sonnet',
      imageGenerator: 'openai.gpt-4o',
    })
    expect(added.ok).toBe(true)
    if (!added.ok) return
    expect(added.value).toContain('[runtime.media]')
    expect(added.value).toContain('vision_reader = "anthropic.sonnet"')
    expect(added.value).toContain('image_generator = "openai.gpt-4o"')
    expect(added.value).not.toContain('media_failover')
    expect(parseRuntimeMediaOverridesFromToml(added.value)).toEqual({
      visionReader: 'anthropic.sonnet',
      imageGenerator: 'openai.gpt-4o',
    })

    // Clearing both removes [runtime.media] table cleanly
    const cleared = upsertRuntimeMediaOverridesInToml(added.value, {
      visionReader: null,
      imageGenerator: null,
    })
    expect(cleared.ok).toBe(true)
    if (cleared.ok) {
      expect(cleared.value).not.toContain('[runtime.media]')
      expect(cleared.value).toContain('[runtime.lanes.coding]')
    }
  })

  it('renders read-only [Vision] and [Image Gen] capability chips on LanesTab, supports [runtime.media] preview, and exposes zero media_failover', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      role: 'admin',
      tokenPresent: true,
      canTokenAdmin: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    bumpSessionEpoch()

    const rawToml = `[runtime]\ndefault = "coding"\n\n[runtime.lanes.coding]\ncandidates = ["anthropic.sonnet", "openai.gpt-4o"]\n`
    let previewedSource = ''

    vi.stubGlobal('fetch', vi.fn<typeof fetch>(async (input, init) => {
      const url = new URL(String(input), window.location.origin)
      if (url.pathname === '/api/v1/runtime/resolved') {
        return new Response(JSON.stringify({
          config_path: '/cfg/runtime.toml',
          default_route: 'coding',
          default_runtime: {
            id: 'openai.gpt-4o',
            provider: 'OpenAI',
            provider_id: 'openai',
            model: 'gpt-4o',
            effective_max_context: 128000,
            max_context_source: 'capability',
            max_output_tokens: 16384,
            is_local: false,
            is_default: true,
            quota_rest: null,
            capabilities: { supports_image_input: true, supports_image_output: true },
          },
          runtimes: [
            {
              id: 'openai.gpt-4o',
              provider: 'OpenAI',
              provider_id: 'openai',
              model: 'gpt-4o',
              effective_max_context: 128000,
              max_context_source: 'capability',
              max_output_tokens: 16384,
              is_local: false,
              is_default: true,
              quota_rest: null,
              capabilities: { supports_image_input: true, supports_image_output: true },
            },
            {
              id: 'anthropic.sonnet',
              provider: 'Anthropic',
              provider_id: 'anthropic',
              model: 'claude-sonnet-4',
              effective_max_context: 200000,
              max_context_source: 'capability',
              max_output_tokens: 8192,
              is_local: false,
              is_default: false,
              quota_rest: null,
              capabilities: { supports_image_input: true, supports_image_output: false },
            },
          ],
          lanes: [{ id: 'coding', declared: true, runtime_ids: ['anthropic.sonnet', 'openai.gpt-4o'] }],
          assignments: [],
        }), { headers: { 'Content-Type': 'application/json' } })
      }
      if (url.pathname === '/api/v1/dashboard/runtime-probe') {
        return new Response(JSON.stringify({
          generated_at: '2026-11-27T01:00:00Z',
          cache_ttl_sec: 30,
          cache_age_sec: 1,
          cache_hit: false,
          refresh_state: 'fresh',
          probe: {
            status: 'ok',
            probe_ok: true,
            checked_at: '2026-11-27T01:00:00Z',
            summary: { runtimes: 2, probed: 2, reachable: 2, failed: 0, skipped: 0, default_runtime_id: 'openai.gpt-4o' },
            providers: [
              {
                runtime_id: 'openai.gpt-4o',
                provider_id: 'openai',
                provider_display_name: 'OpenAI',
                model_id: 'gpt-4o',
                protocol: 'openai',
                runtime_kind: 'http',
                transport: 'http',
                status: 'reachable',
                reachable: true,
                http_status: 200,
                latency_ms: 120,
                error: null,
                checked_at: '2026-11-27T01:00:00Z',
              },
            ],
            errors: [],
            observations: [],
            limitations: [],
          },
        }), { headers: { 'Content-Type': 'application/json' } })
      }
      if (url.pathname === '/api/v1/runtime/config/raw') {
        return new Response(JSON.stringify({
          path: '/cfg/runtime.toml',
          source_revision: 'rev-media-1',
          source_text: rawToml,
        }), { headers: { 'Content-Type': 'application/json' } })
      }
      if (url.pathname === '/api/v1/runtime/config/raw/preview' && init?.method === 'POST') {
        previewedSource = (JSON.parse(String(init.body)) as { source_text: string }).source_text
        return new Response(JSON.stringify({ ok: true, can_save: true }), {
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({}), { headers: { 'Content-Type': 'application/json' } })
    }))

    const view = render(html`
      <${LanesTab} subroute="lanes" onNavigate=${vi.fn()} onInspect=${vi.fn()} />
    `)

    // Open routing & lanes disclosure
    fireEvent.click(view.getByTestId('lane-config-toggle'))

    await waitFor(() => {
      expect(view.getByTestId('lane-coding-cap-vision')).toBeTruthy()
      expect(view.getByTestId('lane-coding-cap-image-gen')).toBeTruthy()
    })
    expect(view.getByTestId('cand-anthropic.sonnet-cap-vision')).toBeTruthy()
    expect(view.queryByTestId('cand-anthropic.sonnet-cap-image-gen')).toBeNull()
    expect(view.getByTestId('cand-openai.gpt-4o-cap-vision')).toBeTruthy()
    expect(view.getByTestId('cand-openai.gpt-4o-cap-image-gen')).toBeTruthy()
    expect(view.container.textContent?.toLowerCase()).not.toContain('media_failover')

    // Optional [runtime.media] override preview (wait for rawConfig load & state commit)
    const imageGenInput = view.getByLabelText('Image Generator 오버라이드') as HTMLInputElement
    const previewForm = view.getByTestId('runtime-media-overrides-form')
    await waitFor(() => {
      const submitBtn = previewForm.querySelector('button[type="submit"]') as HTMLButtonElement | null
      expect(submitBtn?.disabled).toBe(false)
    })
    fireEvent.input(imageGenInput, { target: { value: 'openai.gpt-4o' } })
    await waitFor(() => {
      expect(imageGenInput.value).toBe('openai.gpt-4o')
    })
    await fireEvent.submit(previewForm)

    await waitFor(() => {
      expect(previewedSource).toContain('[runtime.media]')
      expect(previewedSource).toContain('image_generator = "openai.gpt-4o"')
    })
  })

  it('renders read-only derived Vision / Image Gen capability chips in SettingsWorkspace', async () => {
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      role: 'admin',
      tokenPresent: true,
      canTokenAdmin: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    bumpSessionEpoch()

    vi.stubGlobal('fetch', vi.fn<typeof fetch>(async () =>
      new Response(JSON.stringify({
        schema_version: 1,
        instance_id: 'inst-1',
        generated_at_unix: 1000,
        data: {
          target: 'runtime',
          file_exists: true,
          file_sha256: 'abc123def456',
          categories: [
            {
              id: 'runtime_media',
              title: 'Media Routing',
              field_count: 3,
              fields: [
                {
                  table: 'runtime.media',
                  key: 'vision_reader',
                  full_key: 'runtime.media.vision_reader',
                  label: 'Vision Reader Override',
                  description: 'Optional override when active runtime lacks vision.',
                  type: 'string',
                  current_value: '',
                  default_value: '',
                  provenance: 'default',
                  reload_scope: 'next_turn',
                  writable: true,
                  secret: false,
                },
                {
                  table: 'models.gpt4o.capabilities',
                  key: 'supports_image_input',
                  full_key: 'models.gpt4o.capabilities.supports_image_input',
                  label: 'Vision Input',
                  description: 'Derived from provider catalog.',
                  type: 'bool',
                  current_value: true,
                  default_value: true,
                  provenance: 'default',
                  reload_scope: 'hot_reload',
                  writable: false,
                  secret: false,
                },
                {
                  table: 'models.gpt4o.capabilities',
                  key: 'supports_image_output',
                  full_key: 'models.gpt4o.capabilities.supports_image_output',
                  label: 'Image Generation',
                  description: 'Derived from provider catalog.',
                  type: 'bool',
                  current_value: true,
                  default_value: true,
                  provenance: 'default',
                  reload_scope: 'hot_reload',
                  writable: false,
                  secret: false,
                },
              ],
            },
          ],
        },
      }), { headers: { 'Content-Type': 'application/json' } }),
    ))

    const view = render(html`
      <${SettingsWorkspace} subroute="settings" onNavigate=${vi.fn()} onInspect=${vi.fn()} />
    `)

    fireEvent.click(await view.findByRole('button', { name: /Routing & Failover/ }))
    await waitFor(() => {
      expect(view.getByTestId('settings-cap-models.gpt4o.capabilities.supports_image_input').textContent?.trim()).toBe('Vision')
      expect(view.getByTestId('settings-cap-models.gpt4o.capabilities.supports_image_output').textContent?.trim()).toBe('Image Gen')
    })
    expect(view.container.textContent?.toLowerCase()).not.toContain('media_failover')
  })
})
