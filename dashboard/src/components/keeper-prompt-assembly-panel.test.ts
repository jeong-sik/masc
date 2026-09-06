import { cleanup, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { DashboardPromptItem } from '../api'
import { buildKeeperPromptAssemblyReport, KeeperPromptAssemblyPanel } from './keeper-prompt-assembly-panel'

afterEach(() => {
  cleanup()
})

function prompt(overrides: Partial<DashboardPromptItem>): DashboardPromptItem {
  return {
    key: 'keeper',
    category: 'keeper',
    description: 'Keeper prompt',
    current: '',
    effective: '',
    file_value: null,
    override_value: null,
    file_path: null,
    source: 'file',
    char_count: 0,
    required_file: true,
    template_variables: [],
    ...overrides,
  }
}

describe('buildKeeperPromptAssemblyReport', () => {
  it('maps keeper prompt sources into assembly rows', () => {
    const report = buildKeeperPromptAssemblyReport([
      prompt({
        key: 'keeper',
        effective: 'world override',
        override_value: 'world override',
        source: 'override',
        file_path: '/tmp/.masc/config/prompts/keeper.md',
      }),
    ])

    // The shared keeper asset appears once as registry source and once as the
    // system message.
    expect(report.rows.filter(row => row.promptKey === 'keeper').length).toBe(2)
    // The one stage key is supplied and overridden.
    expect(report.stats.overrideRows).toBeGreaterThanOrEqual(1)
    expect(report.stages.map(stage => stage.title)).toEqual(
      expect.arrayContaining(['Prompt sources', 'System rules', 'World message']),
    )
    expect(report.stages.find(stage => stage.id === 'registry-bootstrap')?.messageSlot).toBe('not sent')
    expect(report.stages.filter(stage => stage.role === 'model_input').map(stage => stage.id)).toEqual([
      'base-system',
      'unified-world',
      'turn-soft-context',
      'agent-core-hook',
    ])
    // The world message carries no prompt asset: keeper.turn_intent was its
    // only one and #26823 removed it. Its computed observation placeholders
    // were dropped with RFC prompts-outside-ocaml §2.3 item 3.
    expect(report.stages.find(stage => stage.id === 'unified-world')?.promptCount).toBe(0)
    expect(report.activePromptRoots).toEqual(['/tmp/.masc/config/prompts'])
    expect(report.rows.find(row => row.promptKey === 'keeper')?.source).toBe('override')
  })

  it('detects stale argument shapes in effective prompt text', () => {
    const report = buildKeeperPromptAssemblyReport([
      prompt({
        key: 'keeper',
        effective: 'Call keeper_task_done { notes: "evidence" }. Use keeper_pr_create and repos/masc/lib/foo.ml for PR work.',
      }),
    ])

    expect(report.warnings.map(warning => warning.id)).toEqual(
      expect.arrayContaining([
        'task-done-notes',
        'keeper-pr-create',
        'hardcoded-masc-path',
      ]),
    )
    expect(report.stats.criticalCount).toBe(1)
  })

  it('labels host-storage prompt residue without legacy-era wording', () => {
    const report = buildKeeperPromptAssemblyReport([
      prompt({
        key: 'keeper',
        effective: 'Do not pass .masc/playground/name/repos/foo as a tool path.',
      }),
    ])

    const warning = report.warnings.find(item => item.id === 'playground-path')
    expect(warning?.title).toBe('Host storage path still visible')
    expect(warning?.title.toLowerCase()).not.toContain('legacy')
  })

  it('renders source boundaries and resolved prompt text in the default codex view', () => {
    const { container } = render(html`
      <${KeeperPromptAssemblyPanel}
        prompts=${[
          prompt({
            key: 'keeper',
            effective: 'world override tool policy',
            override_value: 'world override tool policy',
            source: 'override',
            file_path: '/tmp/.masc/config/prompts/keeper.md',
          }),
        ]}
      />
    `)

    const defaultRoute = container.querySelector('[data-prompt-route-default]')
    expect(defaultRoute).not.toBeNull()
    expect(defaultRoute?.getAttribute('data-prompt-codex')).not.toBeNull()
    expect(container.querySelector('[data-prompt-recipe-toolbar]')).toBeNull()
    expect(container.textContent).toContain('Prompt Codex')
    expect(container.textContent).toContain('Keeper sees')
    expect(container.textContent).toContain('Total size')
    expect(container.textContent).toContain('Preset size')
    expect(container.textContent).toContain('Recap minimap')
    expect(container.textContent).toContain('Prompt roots')
    expect(container.querySelector('[data-prompt-minimap]')).not.toBeNull()
    expect(container.querySelector('[data-prompt-source-roots]')?.textContent).toContain('/tmp/.masc/config/prompts')
    expect(container.querySelectorAll('[data-prompt-document-row]').length).toBeGreaterThan(0)
    expect(defaultRoute?.textContent).toContain('system')
    expect(defaultRoute?.textContent).toContain('user')
    expect(defaultRoute?.textContent).toContain('final')
    expect(defaultRoute?.textContent).toContain('Final context')
    expect(defaultRoute?.textContent).toContain('scheduler signals')
    expect(defaultRoute?.textContent).toContain('keeper')
    expect(defaultRoute?.textContent).toContain('/tmp/.masc/config/prompts/keeper.md')
    expect(defaultRoute?.textContent).toContain('world override')
    expect(defaultRoute?.textContent).toContain('tool policy')
    expect(defaultRoute?.textContent).toContain('fingerprint')
    expect(defaultRoute?.textContent).toContain('tok')
    expect(defaultRoute?.textContent).toMatch(/saved override/i)
    expect(container.textContent).toContain('sent parts')
    expect(defaultRoute?.textContent).not.toContain('model-visible')
    expect(defaultRoute?.textContent).not.toMatch(/provider/i)
    expect(defaultRoute?.textContent).not.toMatch(/handoff/i)
    expect(defaultRoute?.textContent).not.toMatch(/runtime override/i)
    expect(defaultRoute?.textContent).not.toMatch(/resolved block/i)
    expect(defaultRoute?.textContent).not.toMatch(/context_injected/i)
    expect(defaultRoute?.textContent).not.toMatch(/source rows/i)
    expect(defaultRoute?.textContent).not.toMatch(/sources? selected/i)
    expect(defaultRoute?.textContent).not.toMatch(/messages? to model/i)
    expect(defaultRoute?.textContent).not.toMatch(/choose source text/i)
    expect(defaultRoute?.textContent).not.toMatch(/save audit trail/i)
    expect(defaultRoute?.textContent).not.toMatch(/prompt cleanup/i)
    expect(defaultRoute?.textContent).not.toMatch(/before send/i)
    expect(defaultRoute?.textContent).not.toMatch(/after send/i)
    expect(defaultRoute?.textContent).not.toMatch(/\bready\b/i)
    expect(defaultRoute?.textContent).toMatch(/not sent/i)

    const evidence = container.querySelector('[data-developer-evidence]')
    expect(evidence).not.toBeNull()
    expect(evidence?.hasAttribute('open')).toBe(false)
    expect(evidence?.querySelector('summary')?.textContent).toContain('Build details')
    expect(evidence?.querySelector('summary')?.textContent).toContain('optional')
    expect(evidence?.querySelector('summary')?.textContent).not.toContain('Technical trace')
    expect(evidence?.querySelector('summary')?.textContent).not.toContain('hidden by default')
    expect(evidence?.querySelector('summary')?.textContent).not.toMatch(/source rows/i)
    expect(evidence?.querySelector('[data-source-audit-map]')?.textContent).toContain('build path')
    expect(evidence?.querySelector('[data-source-audit-map]')?.textContent).toContain('Prompt text chosen')
    expect(evidence?.querySelector('[data-source-audit-map]')?.textContent).toContain('Sent to model')
    expect(evidence?.querySelector('[data-source-audit-map]')?.textContent).toContain('Stored record')
    expect(evidence?.querySelector('[data-source-audit-map]')?.textContent).toContain('System rules')
    expect(evidence?.querySelector('[data-source-audit-map]')?.textContent).toContain('World message')
    expect(evidence?.querySelector('[data-source-audit-map]')?.textContent).toContain('Final context')
    expect(evidence?.querySelector('[data-source-audit-map]')?.textContent).not.toMatch(/\d+ prompts?/i)
    const rawFileList = evidence?.querySelector('[data-prompt-file-list]')
    expect(rawFileList).not.toBeNull()
    expect(rawFileList?.hasAttribute('open')).toBe(false)
    expect(rawFileList?.querySelector('summary')?.textContent).toContain('Raw prompt files')
    expect(evidence?.textContent).toContain('keeper')
    expect(evidence?.textContent).toContain('fingerprint')

    const intro = container.querySelector('[data-prompt-recipe-intro]')
    expect(intro?.textContent).toContain('document sections')
    expect(intro?.textContent).toContain('source boundaries')
    expect(intro?.textContent).toContain('size recap')
    expect(intro?.textContent).not.toMatch(/technical trace/i)
    expect(intro?.textContent).not.toMatch(/hash/i)
    expect(intro?.textContent).not.toMatch(/token/i)
    expect(intro?.textContent).not.toMatch(/model-visible/i)
  })

  it('keeps cleanup suggestions inside source audit without maintenance wording', () => {
    const { container } = render(html`
      <${KeeperPromptAssemblyPanel}
        prompts=${[
          prompt({
            key: 'keeper',
            effective: 'Do not pass .masc/playground/name/repos/foo as a tool path.',
          }),
        ]}
      />
    `)

    const summary = container.querySelector('[data-prompt-quality-checks] summary')
    expect(summary).not.toBeNull()
    expect(container.querySelector('[data-developer-evidence] [data-prompt-quality-checks]')).not.toBeNull()
    expect(summary?.textContent).toContain('Prompt cleanup')
    expect(summary?.textContent).toContain('suggestion')
    expect(summary?.textContent).not.toMatch(/quality checks/i)
    expect(summary?.textContent).not.toMatch(/finding/i)
    expect(summary?.textContent).not.toMatch(/maintenance/i)
    expect(summary?.textContent).not.toMatch(/\bnotes?\b/i)

    const affectedPrompts = container.querySelector('[data-prompt-quality-checks] details summary')
    expect(affectedPrompts?.textContent).toContain('Affected prompts')
  })
})

// The "Total size" metric is what an operator sizes a keeper's context budget
// against. Two stages carry messageSlot 'not sent' — 'registry-bootstrap'
// re-lists keeper as source preparation, and 'manifest-edge' is the
// post-assembly audit record. Summing every row counted keeper twice:
// the live fleet panel read 15.3 KiB / 3,920 tok against a real model input of
// 1,985 tok.
describe('buildKeeperPromptAssemblyReport sent totals', () => {
  it('excludes not-sent stages from the model-input totals', () => {
    const body = 'x'.repeat(4096)
    const report = buildKeeperPromptAssemblyReport([
      prompt({
        key: 'keeper',
        effective: body,
        file_path: '/tmp/.masc/config/prompts/keeper.md',
        char_count: body.length,
      }),
    ])

    const notSent = report.stages.filter(stage => stage.messageSlot === 'not sent')
    expect(notSent.length).toBeGreaterThan(0)

    const allBytes = report.rows.reduce((sum, row) => sum + row.bytes, 0)
    const notSentBytes = notSent.reduce((sum, stage) => sum + stage.bytes, 0)

    // The not-sent stages carry real bytes here, so the two totals must differ.
    expect(notSentBytes).toBeGreaterThan(0)
    expect(report.stats.sentPromptBytes).toBe(allBytes - notSentBytes)
    expect(report.stats.sentPromptBytes).toBeLessThan(allBytes)
  })

  it('counts a prompt reused by a not-sent stage only once', () => {
    const body = 'y'.repeat(2048)
    const report = buildKeeperPromptAssemblyReport([
      prompt({
        key: 'keeper',
        effective: body,
        file_path: '/tmp/.masc/config/prompts/keeper.md',
        char_count: body.length,
      }),
    ])

    const systemStage = report.stages.find(stage => stage.id === 'base-system')
    const sourceStage = report.stages.find(stage => stage.id === 'registry-bootstrap')
    expect(sourceStage?.messageSlot).toBe('not sent')
    // Both stages render keeper, so the naive all-rows sum is ~2x.
    expect(sourceStage?.bytes).toBe(systemStage?.bytes)
    expect(report.stats.sentEstimatedTokens).toBeLessThan(
      report.rows.reduce((sum, row) => sum + row.estimatedTokens, 0),
    )
  })
})
