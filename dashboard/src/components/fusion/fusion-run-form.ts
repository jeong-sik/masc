// Operator-initiated deliberation form.
//
// Why this exists: masc_fusion advertises five topologies, but until now the
// only surface that could start a run was a keeper calling the tool itself.
// So judge_of_judges and staged_judge_of_judges were reachable only by a
// keeper's own decision, and a preset configured for them could sit unused
// indefinitely without anyone noticing it had never run.
//
// The form derives which topologies a preset can actually run from the config
// (runnableTopologies) instead of listing all five and letting the backend
// refuse: a preset with no first-pass judges fails judge-of-judges every time,
// and that is a property of the configuration, knowable before the click.

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { fetchFusionConfig, runnableTopologies } from '../../api/dashboard'
import type { FusionConfigView, FusionTopologyLabel } from '../../api/dashboard'
import { runKeeperFusion } from '../../api/keeper'
import { keepers } from '../../store'
import { replaceRoute } from '../../router'
import { ringFocusClasses } from '../common/ring'

const TOPOLOGY_HINT: Record<FusionTopologyLabel, string> = {
  simple: '패널 → 심판 1회',
  refine: '패널 → 심판 → 2차 심판이 1차 종합을 재검토',
  conditional: 'simple 과 같되, 1차 심판이 판정을 못 내렸을 때만 2차로 승격',
  judge_of_judges: '1차 심판 여럿이 독립 종합 → meta 심판이 재조정',
  staged_judge_of_judges: '1차 심판을 그룹으로 나눠 단계별 종합 → 최종 meta',
}

// Requires >= 2 first-pass judges (judge-of-judges) or a roster that divides
// into two full groups (staged). Shown so an operator reads why an option is
// absent instead of inferring it from a rejection.
function unavailableReason(
  judges: number,
  stagedGroupSize: number,
  topology: FusionTopologyLabel,
): string | null {
  if (topology === 'judge_of_judges' && judges < 2) {
    return `1차 심판 ${judges}명 — 2명 이상 필요`
  }
  if (topology === 'staged_judge_of_judges') {
    if (judges < stagedGroupSize * 2) {
      return `1차 심판 ${judges}명 — ${stagedGroupSize * 2}명 이상 필요`
    }
    if (judges % stagedGroupSize !== 0) {
      return `1차 심판 ${judges}명 — ${stagedGroupSize}의 배수여야 함`
    }
  }
  return null
}

export function FusionRunForm() {
  const [config, setConfig] = useState<FusionConfigView | null>(null)
  const [configError, setConfigError] = useState<string | null>(null)
  const [keeper, setKeeper] = useState('')
  const [preset, setPreset] = useState('')
  const [topology, setTopology] = useState<FusionTopologyLabel>('simple')
  const [prompt, setPrompt] = useState('')
  const [webTools, setWebTools] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    fetchFusionConfig({ signal: controller.signal })
      .then(loaded => {
        setConfig(loaded)
        setPreset(current => current || loaded.defaultPreset)
      })
      .catch((cause: unknown) => {
        if (controller.signal.aborted) return
        setConfigError(cause instanceof Error ? cause.message : String(cause))
      })
    return () => controller.abort()
  }, [])

  const selectedPreset = useMemo(
    () => config?.presets.find(entry => entry.name === preset) ?? null,
    [config, preset],
  )
  const allowed = useMemo(
    () =>
      selectedPreset && config
        ? runnableTopologies(selectedPreset, config.stagedJudgeGroupSize)
        : (['simple', 'refine', 'conditional'] as const),
    [selectedPreset, config],
  )

  // Switching to a preset that cannot run the selected topology silently
  // leaving an impossible selection would produce a refusal at submit time, so
  // the selection follows the preset back to a runnable one.
  useEffect(() => {
    if (!allowed.includes(topology)) setTopology('simple')
  }, [allowed, topology])

  const keeperOptions = keepers.value.map(entry => entry.name)
  const canSubmit = keeper !== '' && prompt.trim() !== '' && !busy

  async function submit(event: Event) {
    event.preventDefault()
    if (!canSubmit) return
    setBusy(true)
    setError(null)
    try {
      const started = await runKeeperFusion(keeper, {
        prompt: prompt.trim(),
        preset: preset || undefined,
        topology,
        webTools,
      })
      setPrompt('')
      replaceRoute('fusion', { run_id: started.runId })
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : String(cause))
    } finally {
      setBusy(false)
    }
  }

  if (configError) {
    return html`<div class="fus-block" data-testid="fusion-run-form-error">
      fusion 설정을 읽지 못했습니다: ${configError}
    </div>`
  }

  return html`
    <form class="fus-block" data-testid="fusion-run-form" onSubmit=${submit}>
      <h2>심의 실행</h2>

      <label>
        키퍼
        <select
          data-testid="fusion-run-keeper"
          class=${ringFocusClasses()}
          value=${keeper}
          onChange=${(e: Event) => setKeeper((e.target as HTMLSelectElement).value)}
        >
          <option value="">선택…</option>
          ${keeperOptions.map(name => html`<option value=${name}>${name}</option>`)}
        </select>
      </label>

      <label>
        프리셋
        <select
          data-testid="fusion-run-preset"
          class=${ringFocusClasses()}
          value=${preset}
          onChange=${(e: Event) => setPreset((e.target as HTMLSelectElement).value)}
        >
          ${(config?.presets ?? []).map(
            entry =>
              html`<option value=${entry.name}>
                ${entry.name} · 패널 ${entry.panels.reduce((n, g) => n + g.models.length, 0)} ·
                1차 심판 ${entry.judges.length}
              </option>`,
          )}
        </select>
      </label>

      <label>
        위상
        <select
          data-testid="fusion-run-topology"
          class=${ringFocusClasses()}
          value=${topology}
          onChange=${(e: Event) =>
            setTopology((e.target as HTMLSelectElement).value as FusionTopologyLabel)}
        >
          ${(
            [
              'simple',
              'refine',
              'conditional',
              'judge_of_judges',
              'staged_judge_of_judges',
            ] as FusionTopologyLabel[]
          ).map(option => {
            const reason = selectedPreset && config
              ? unavailableReason(
                  selectedPreset.judges.length,
                  config.stagedJudgeGroupSize,
                  option,
                )
              : null
            // Label built outside the template: htm parses the tagged
            // template, and a nested backtick inside an interpolation does not
            // survive that pass.
            const label = reason
              ? `${option.replace(/_/g, ' ')} — ${reason}`
              : option.replace(/_/g, ' ')
            return html`<option value=${option} disabled=${!allowed.includes(option)}>
              ${label}
            </option>`
          })}
        </select>
      </label>
      <p class="fus-run-meta">${TOPOLOGY_HINT[topology]}</p>

      <label>
        질문
        <textarea
          data-testid="fusion-run-prompt"
          class=${ringFocusClasses()}
          rows="4"
          value=${prompt}
          onInput=${(e: Event) => setPrompt((e.target as HTMLTextAreaElement).value)}
        ></textarea>
      </label>

      <label class="v2-mobile-operator-target">
        <input
          type="checkbox"
          data-testid="fusion-run-web-tools"
          checked=${webTools}
          onChange=${(e: Event) => setWebTools((e.target as HTMLInputElement).checked)}
        />
        web_search / web_fetch 주입
      </label>

      ${error
        ? html`<p class="fus-run-meta" data-testid="fusion-run-form-refusal">${error}</p>`
        : null}

      <button
        type="submit"
        data-testid="fusion-run-submit"
        class=${`fus-link inline ${ringFocusClasses()}`}
        disabled=${!canSubmit}
      >
        ${busy ? '실행 중…' : '심의 실행'}
      </button>
    </form>
  `
}
