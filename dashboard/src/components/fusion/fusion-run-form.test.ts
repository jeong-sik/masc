// Operator deliberation form.
//
// The behaviour worth pinning is the gating: a preset with fewer than two
// first-pass judges cannot run judge_of_judges, and the backend refuses it
// every time. The form has to say that before the click rather than let the
// operator discover it from a refusal — that refusal is exactly how the
// judge-of-judges topologies stayed unrunnable without anyone noticing.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import type { FusionConfigView } from '../../api/dashboard'

const fusionConfigMock = vi.fn()
const runFusionMock = vi.fn()
const replaceRouteMock = vi.fn()

vi.mock('../../api/dashboard', () => ({
  fetchFusionConfig: () => fusionConfigMock(),
  runnableTopologies: (
    preset: { judges: readonly unknown[] },
    stagedGroupSize: number,
  ): readonly string[] => {
    const base = ['simple', 'refine', 'conditional']
    const judges = preset.judges.length
    if (judges >= 2) base.push('judge_of_judges')
    if (stagedGroupSize >= 2 && judges >= stagedGroupSize * 2 && judges % stagedGroupSize === 0) {
      base.push('staged_judge_of_judges')
    }
    return base
  },
}))
vi.mock('../../api/keeper', () => ({
  runKeeperFusion: (keeper: string, input: unknown) => runFusionMock(keeper, input),
}))
vi.mock('../../router', () => ({
  replaceRoute: (screen: string, params: unknown) => replaceRouteMock(screen, params),
}))
vi.mock('../../store', () => ({
  keepers: { value: [{ name: 'analyst' }, { name: 'rondo' }] },
}))

const { FusionRunForm } = await import('./fusion-run-form')

function config(judgeCount: number): FusionConfigView {
  return {
    enabled: true,
    defaultPreset: 'quorum',
    stagedJudgeGroupSize: 3,
    presets: [
      {
        name: 'quorum',
        panels: [
          {
            models: ['p.one', 'p.two'],
            label: '',
            systemPrompt: 'panelist',
            webTools: false,
            maxOutputTokens: null,
            timeoutS: 240,
          },
        ],
        judge: 'p.meta',
        judgeSystemPrompt: 'meta',
        judgeMaxOutputTokens: null,
        judgeTimeoutS: 180,
        judges: Array.from({ length: judgeCount }, (_, i) => ({
          model: `p.j${i}`,
          label: `lens${i}`,
          systemPrompt: 'lens',
          webTools: false,
          maxOutputTokens: null,
          timeoutS: null,
        })),
        minAnswered: 1,
      },
    ],
  }
}

let container: HTMLDivElement

async function mount() {
  render(html`<${FusionRunForm} />`, container)
  // Two ticks: one for the config promise to settle, one for the state update
  // it triggers to re-render.
  await new Promise(resolve => setTimeout(resolve, 0))
  await new Promise(resolve => setTimeout(resolve, 0))
}

function q<T extends Element>(selector: string): T | null {
  return container.querySelector<T>(selector)
}

beforeEach(() => {
  fusionConfigMock.mockReset()
  runFusionMock.mockReset()
  replaceRouteMock.mockReset()
  container = document.createElement('div')
  document.body.appendChild(container)
})

afterEach(() => {
  render(null, container)
  container.remove()
})

describe('FusionRunForm', () => {
  it('disables judge-of-judges and names the reason when the preset has no first-pass judges', async () => {
    fusionConfigMock.mockResolvedValue(config(0))
    await mount()

    const options = Array.from(
      container.querySelectorAll<HTMLOptionElement>('[data-testid="fusion-run-topology"] option'),
    )
    const joj = options.find(option => option.value === 'judge_of_judges')
    expect(joj?.disabled).toBe(true)
    expect(joj?.textContent).toContain('2명 이상 필요')
    expect(options.find(option => option.value === 'simple')?.disabled).toBe(false)
  })

  it('enables judge-of-judges once two first-pass judges exist', async () => {
    fusionConfigMock.mockResolvedValue(config(2))
    await mount()

    const joj = Array.from(
      container.querySelectorAll<HTMLOptionElement>('[data-testid="fusion-run-topology"] option'),
    ).find(option => option.value === 'judge_of_judges')
    expect(joj?.disabled).toBe(false)
  })

  it('keeps the staged form disabled on a ragged roster the backend would refuse', async () => {
    // 8 judges with group size 3 leaves a partial final group.
    fusionConfigMock.mockResolvedValue(config(8))
    await mount()

    const staged = Array.from(
      container.querySelectorAll<HTMLOptionElement>('[data-testid="fusion-run-topology"] option'),
    ).find(option => option.value === 'staged_judge_of_judges')
    expect(staged?.disabled).toBe(true)
    expect(staged?.textContent).toContain('3의 배수')
  })

  it('surfaces the tool refusal verbatim instead of a generic failure', async () => {
    fusionConfigMock.mockResolvedValue(config(2))
    runFusionMock.mockRejectedValue(
      new Error('judge_of_judges requires >= 2 judges configured in the preset'),
    )
    await mount()

    const keeper = q<HTMLSelectElement>('[data-testid="fusion-run-keeper"]')
    const prompt = q<HTMLTextAreaElement>('[data-testid="fusion-run-prompt"]')
    if (!keeper || !prompt) throw new Error('form did not render its inputs')
    keeper.value = 'analyst'
    keeper.dispatchEvent(new Event('change', { bubbles: true }))
    prompt.value = 'question'
    prompt.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise(resolve => setTimeout(resolve, 0))

    q<HTMLFormElement>('[data-testid="fusion-run-form"]')?.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    )
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(q('[data-testid="fusion-run-form-refusal"]')?.textContent).toContain(
      'requires >= 2 judges',
    )
    expect(replaceRouteMock).not.toHaveBeenCalled()
  })

  it('routes to the started run so the operator lands on its evidence', async () => {
    fusionConfigMock.mockResolvedValue(config(2))
    runFusionMock.mockResolvedValue({
      ok: true,
      status: 'fusion_started',
      runId: 'kmsg-abc',
      ownerKeeper: 'analyst',
      fusionRoute: '/#fusion?run_id=kmsg-abc',
    })
    await mount()

    const keeper = q<HTMLSelectElement>('[data-testid="fusion-run-keeper"]')
    const prompt = q<HTMLTextAreaElement>('[data-testid="fusion-run-prompt"]')
    if (!keeper || !prompt) throw new Error('form did not render its inputs')
    keeper.value = 'analyst'
    keeper.dispatchEvent(new Event('change', { bubbles: true }))
    prompt.value = '  question  '
    prompt.dispatchEvent(new Event('input', { bubbles: true }))
    await new Promise(resolve => setTimeout(resolve, 0))

    q<HTMLFormElement>('[data-testid="fusion-run-form"]')?.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    )
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(runFusionMock).toHaveBeenCalledWith('analyst', {
      prompt: 'question',
      preset: 'quorum',
      topology: 'simple',
      webTools: false,
    })
    expect(replaceRouteMock).toHaveBeenCalledWith('fusion', { run_id: 'kmsg-abc' })
  })

  it('reports a config load failure instead of rendering an empty form', async () => {
    fusionConfigMock.mockRejectedValue(new Error('boom'))
    await mount()

    expect(q('[data-testid="fusion-run-form-error"]')?.textContent).toContain('boom')
    expect(q('[data-testid="fusion-run-form"]')).toBeNull()
  })
})
