import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  resetAuthStateForTests,
  resourceCache,
} from '../../core'
import { navigate, resetRouterForTests } from '../../routes/router'
import { activeContrast, activeTheme, resetShellStateForTests } from '../../shell/shell-state'
import {
  CANONICAL_SETTINGS_CATEGORIES,
  SettingsWorkspace,
  type ConfigSchemaData,
  type WorkspaceInspectPayload,
} from './index'
import { matchCanonicalCategoryId } from './types'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

async function flushUi(ms = 30): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms))
}

const SAMPLE_SCHEMA: ConfigSchemaData = {
  target: 'runtime',
  file_exists: true,
  file_sha256: 'sha256-initial-11111111',
  categories: [
    {
      id: 'general',
      title: 'General & UI',
      field_count: 1,
      fields: [{
        table: 'server',
        key: 'log_level',
        full_key: 'server.log_level',
        type: 'string',
        current_value: 'info',
        default_value: 'info',
        provenance: 'project',
        reload_scope: 'hot_reload',
        secret: false,
        writable: true,
        description: '서버 로그 레벨',
        enum_values: ['debug', 'info', 'warn', 'error'],
      }],
    },
    {
      id: 'providers',
      title: 'Providers & Models',
      field_count: 1,
      fields: [{
        table: 'providers.openai',
        key: 'api_key',
        full_key: 'providers.openai.api_key',
        type: 'string',
        current_value: 'sk-redacted',
        default_value: null,
        provenance: 'env',
        reload_scope: 'restart_required',
        secret: true,
        writable: true,
        description: 'OpenAI API 시크릿 키',
      }],
    },
  ],
}

describe('workspaces/settings', () => {
  let container: HTMLDivElement
  let originalFetch: typeof globalThis.fetch

  beforeEach(() => {
    originalFetch = globalThis.fetch
    resetAuthStateForTests()
    resetRouterForTests('/settings')
    resetShellStateForTests()
    resourceCache.clearAll()
    delete document.documentElement.dataset.theme
    delete document.documentElement.dataset.contrast
    localStorage.clear()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resourceCache.clearAll()
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('renders all 7 TUI categories, Appearance dark/light + static High-Contrast toggles, and executes safe CAS dry_run -> Apply Patch flow', async () => {
    const patchBodies: Record<string, unknown>[] = []

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.startsWith('/api/v1/config/schema')) {
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1_700_000_000,
          data: SAMPLE_SCHEMA,
        })
      }
      if (url === '/api/v1/config/patch' && init?.method === 'POST') {
        const body = JSON.parse(String(init.body)) as Record<string, unknown>
        patchBodies.push(body)
        const isDryRun = body.dry_run === true
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1_700_000_005,
          data: {
            applied: !isDryRun,
            dry_run: isDryRun,
            target: 'runtime',
            changed: true,
            before_sha256: 'sha256-initial-11111111',
            new_sha256: 'sha256-updated-22222222',
            snapshot_id: isDryRun ? null : 'snap-20261124-001',
            reload_scope: 'restart_required',
            unified_diff: '--- runtime.toml\n+++ runtime.toml\n@@ -1 +1 @@\n-log_level = "info"\n+log_level = "debug"\n',
            diff_hunks: [],
            validation_warnings: [],
          },
        })
      }
      if (url === '/api/v1/world/configuration/export') {
        return jsonResponse({
          ok: true,
          scope: 'authored_configuration_documents',
          bundle: { runtime: 'log_level = "debug"' },
          lock_warnings: [],
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    const inspected: WorkspaceInspectPayload[] = []
    render(
      html`<${SettingsWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${(p: WorkspaceInspectPayload) => inspected.push(p)} />`,
      container,
    )
    await flushUi(40)

    // Verify all 7 TUI categories exist in left category rail
    const navButtons = Array.from(container.querySelectorAll('nav button'))
    for (const cat of CANONICAL_SETTINGS_CATEGORIES) {
      expect(navButtons.some((b) => b.textContent?.includes(cat.title))).toBe(true)
    }

    // Verify Appearance Panel Dark/Light + Static High-Contrast toggles sync shell-state signals
    const lightBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('Light · Warm Paper'),
    ) as HTMLButtonElement
    lightBtn.click()
    expect(document.documentElement.dataset.theme).toBe('light')
    expect(activeTheme.value).toBe('light')

    const hcBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.trim() === 'High Contrast',
    ) as HTMLButtonElement
    hcBtn.click()
    expect(document.documentElement.dataset.contrast).toBe('high')
    expect(activeContrast.value).toBe('high')

    // Stage local edit on server.log_level -> Preview Diff (dry_run: true)
    const selectEl = container.querySelector('select[aria-label="server.log_level"]') as HTMLSelectElement
    selectEl.value = 'debug'
    selectEl.dispatchEvent(new Event('change', { bubbles: true }))
    await flushUi(20)

    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('Preview Diff (1)'),
    ) as HTMLButtonElement
    expect(previewBtn.disabled).toBe(false)
    previewBtn.click()
    await flushUi(40)

    expect(patchBodies).toHaveLength(1)
    expect(patchBodies[0]!.dry_run).toBe(true)
    expect(patchBodies[0]!.expected_sha256).toBe('sha256-initial-11111111')

    // Verify unified diff & reload_scope honesty notice rendered
    expect(container.querySelector('[data-testid="settings-unified-diff"]')!.textContent).toContain('+log_level = "debug"')
    expect(container.querySelector('[data-testid="settings-reload-scope-notice"]')!.textContent).toContain('restart_required')

    // Apply Patch (dry_run: false) -> renders snapshot_id receipt
    const applyBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.trim() === 'Apply Patch',
    ) as HTMLButtonElement
    applyBtn.click()
    await flushUi(40)

    expect(patchBodies).toHaveLength(2)
    expect(patchBodies[1]!.dry_run).toBe(false)
    expect(container.querySelector('[data-testid="settings-apply-receipt"]')!.textContent).toContain('snap-20261124-001')

    // Export World Config
    const exportBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('Export World Config'),
    ) as HTMLButtonElement
    exportBtn.click()
    await flushUi(30)
    expect(inspected).toHaveLength(1)
    expect(inspected[0]!.kind).toBe('world_config_export')
  })

  it('rejects incomplete receipts and keeps cleared numeric fields out of the patch', async () => {
    const patchBodies: Record<string, unknown>[] = []
    const numberField = {
      ...SAMPLE_SCHEMA.categories[0]!.fields[0]!,
      key: 'port',
      full_key: 'server.port',
      label: 'Port',
      type: 'int',
      current_value: 8935,
      default_value: 8935,
      enum_values: undefined,
    }
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const envelope = { schema_version: 1, instance_id: 'inst-1', generated_at_unix: 1 }
      if (url.startsWith('/api/v1/config/schema')) {
        return jsonResponse({
          ...envelope,
          data: {
            ...SAMPLE_SCHEMA,
            categories: [
              { id: 'incomplete', title: 'Incomplete' },
              { id: 'general', title: 'General', fields: [numberField, { ...numberField, full_key: 'server.broken', type: null }] },
            ],
          },
        })
      }
      if (url === '/api/v1/config/patch') {
        patchBodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>)
        return jsonResponse({
          ...envelope,
          data: {
            applied: false, dry_run: true, target: 'runtime', changed: true,
            before_sha256: SAMPLE_SCHEMA.file_sha256, snapshot_id: null,
            reload_scope: 'hot_reload', unified_diff: '+port = 0',
          },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(html`<${SettingsWorkspace} subroute="runtime" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    const input = await vi.waitFor(() => {
      const field = container.querySelector<HTMLInputElement>('[aria-label="server.port"]')
      expect(field).not.toBeNull()
      return field!
    })
    expect(input.value).toBe('8935')
    expect(container.querySelector('[aria-label="server.broken"]')).toBeNull()
    const preview = [...container.querySelectorAll('button')].find((b) => b.textContent?.includes('Preview Diff'))!
    input.value = ''
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await vi.waitFor(() => expect(input.getAttribute('aria-invalid')).toBe('true'))
    expect(input.value).toBe('')
    expect(preview.disabled).toBe(true)
    expect(patchBodies).toHaveLength(0)

    input.value = '0'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await vi.waitFor(() => expect(preview.disabled).toBe(false))
    preview.click()
    await vi.waitFor(() => {
      expect(container.querySelector('[role="alert"]')?.textContent).toContain('Invalid configuration patch receipt')
    })

    expect(patchBodies[0]?.changes).toEqual([
      { op: 'set_int', table: 'server', key: 'port', full_key: 'server.port', value: 0 },
    ])
    expect(container.querySelector('[data-testid="settings-dry-run-panel"]')).toBeNull()
  })

  it('handles HTTP 409 conflict_cas with explicit reload recovery', async () => {
    let schemaFetches = 0
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.startsWith('/api/v1/config/schema')) {
        schemaFetches += 1
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1_700_000_000,
          data: { ...SAMPLE_SCHEMA, file_sha256: `sha256-v${schemaFetches}` },
        })
      }
      if (url === '/api/v1/config/patch' && init?.method === 'POST') {
        return jsonResponse({
          error: { code: 'conflict_cas', message: 'runtime.toml modified by another operator' },
        }, 409)
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${SettingsWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(40)

    const selectEl = container.querySelector('select[aria-label="server.log_level"]') as HTMLSelectElement
    selectEl.value = 'warn'
    selectEl.dispatchEvent(new Event('change', { bubbles: true }))
    await flushUi(15)

    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('Preview Diff (1)'),
    ) as HTMLButtonElement
    previewBtn.click()
    await flushUi(40)

    const conflictBox = container.querySelector('[data-testid="settings-cas-conflict"]')
    expect(conflictBox).not.toBeNull()
    expect(conflictBox!.textContent).toContain('409 CAS 충돌')

    const reloadBtn = conflictBox!.querySelector('button') as HTMLButtonElement
    reloadBtn.click()
    await flushUi(40)

    expect(schemaFetches).toBe(2)
    expect(container.querySelector('[data-testid="settings-cas-conflict"]')).toBeNull()
  })

  it('honors hash-route ?section= and ?key= query params from Command Palette and Quotas deep links', async () => {
    globalThis.fetch = vi.fn(async () => jsonResponse({
      schema_version: 1,
      instance_id: 'inst-1',
      generated_at_unix: 1_700_000_000,
      data: SAMPLE_SCHEMA,
    })) as typeof fetch

    navigate('/settings?section=candle')
    render(html`<${SettingsWorkspace} subroute="" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await vi.waitFor(() => {
      const activeCategory = container.querySelector('nav button[aria-current="page"]')
      expect(activeCategory?.textContent).toContain('Board, Memory & Candle')
    })

    navigate('/settings?key=providers.openai')
    await vi.waitFor(() => {
      const searchInput = container.querySelector<HTMLInputElement>('input[aria-label="설정 키 검색"]')
      expect(searchInput?.value).toBe('providers.openai')
      expect(container.querySelector('[data-field-key="providers.openai.api_key"]')).not.toBeNull()
    })
  })

  it('matches canonical settings categories without bare "ui" substring false positives', () => {
    expect(matchCanonicalCategoryId({ id: 'general', title: 'General & UI', field_count: 0, fields: [] })).toBe('general')
    expect(matchCanonicalCategoryId({ id: 'appearance', title: 'UI Preferences', field_count: 0, fields: [] })).toBe('general')
    expect(matchCanonicalCategoryId({ id: 'build_release', title: 'Build & Quick Guide', field_count: 0, fields: [] })).toBe('build_release')
    expect(matchCanonicalCategoryId({ id: 'suite_req', title: 'Required Suite Equipment', field_count: 0, fields: [] })).toBe('suite_req')
    expect(matchCanonicalCategoryId({ id: 'board_memory_candle', title: 'Board, Memory & Candle', field_count: 0, fields: [] })).toBe('board_memory_candle')
  })
})
