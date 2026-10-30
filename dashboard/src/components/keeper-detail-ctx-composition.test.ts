import { render } from 'preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { Keeper, KeeperMetricPoint } from '../types'
import { CtxCompositionPanel } from './keeper-detail-ctx-composition'

afterEach(() => {
  document.body.innerHTML = ''
})

function metricPoint(overrides: Partial<KeeperMetricPoint>): KeeperMetricPoint {
  return {
    ts: 1,
    context_ratio: 0,
    context_tokens: 0,
    context_max: 0,
    latency_ms: null,
    channel: 'turn',
    cost_usd: 0,
    prompt_fingerprint: null,
    prompt_metrics: null,
    ctx_composition: null,
    input_tokens: null,
    output_tokens: null,
    total_tokens: null,
    wall_tokens_per_second: null,
    inference_telemetry: null,
    ...overrides,
  }
}

describe('CTX composition panel and the not-measured turn', () => {
  it('reports the gap instead of drawing an older turn in its place', () => {
    const container = document.createElement('div')
    const keeper = {
      name: 'gap-keeper',
      status: 'active',
      metrics_series: [
        metricPoint({
          ts: 1,
          ctx_composition: {
            actual_input_tokens: 900,
            attribution: {
              status: 'attributed',
              runtime_profile: 'glm-coding.glm-5',
              attributed_bytes: 1160,
              segments: { message_tool_result: { bytes: 1160, fingerprint: null } },
            },
          },
        }),
        metricPoint({
          ts: 2,
          ctx_composition: {
            actual_input_tokens: 41230,
            attribution: {
              status: 'not_measured',
              reason: 'dispatch_not_reached',
              detail: null,
            },
          },
        }),
      ],
    } as Keeper

    render(html`<${CtxCompositionPanel} keeper=${keeper} />`, container)

    expect(container.textContent).toContain('측정되지 않았어요')
    expect(container.textContent).toContain('dispatch_not_reached')
    // The earlier turn was measured on a different runtime. Showing its
    // composition under this turn's label is the mis-attribution masc#32995
    // recorded.
    expect(container.textContent).not.toContain('1,160 bytes')
  })

  it('shows the provenance detail when one was recorded', () => {
    const container = document.createElement('div')
    const keeper = {
      name: 'provenance-keeper',
      status: 'active',
      metrics_series: [
        metricPoint({
          ctx_composition: {
            actual_input_tokens: null,
            attribution: {
              status: 'not_measured',
              reason: 'projection_dropped_input_prefix',
              detail: 'handed=9 returned=4',
            },
          },
        }),
      ],
    } as Keeper

    render(html`<${CtxCompositionPanel} keeper=${keeper} />`, container)

    expect(container.textContent).toContain('projection_dropped_input_prefix')
    expect(container.textContent).toContain('handed=9 returned=4')
  })

  it('draws the latest turn when it was attributed', () => {
    const container = document.createElement('div')
    const keeper = {
      name: 'measured-keeper',
      status: 'active',
      metrics_series: [
        metricPoint({
          ctx_composition: {
            actual_input_tokens: 1000,
            attribution: {
              status: 'attributed',
              runtime_profile: 'antigravity_subscription.gemini-3-8-flash-high',
              attributed_bytes: 640,
              segments: { tool_schemas: { bytes: 640, fingerprint: 'abc' } },
            },
          },
        }),
      ],
    } as Keeper

    render(html`<${CtxCompositionPanel} keeper=${keeper} />`, container)

    expect(container.textContent).toContain('attributed content bytes')
    expect(container.textContent).toContain('640 bytes')
  })

  // The OCaml record omits the byte count on the unmeasured branch precisely
  // so a reader cannot confuse "measured, nothing to attribute" with "never
  // measured". Returning null here drew the same blank for both and put the
  // distinction back.
  it('says a turn was measured even when it attributed no bytes', () => {
    const container = document.createElement('div')
    const keeper = {
      name: 'zero-keeper',
      status: 'active',
      metrics_series: [
        metricPoint({
          ctx_composition: {
            actual_input_tokens: 512,
            attribution: {
              status: 'attributed',
              runtime_profile: 'codex_app_server.gpt-5-codex',
              attributed_bytes: 0,
              segments: {},
            },
          },
        }),
      ],
    } as Keeper

    render(html`<${CtxCompositionPanel} keeper=${keeper} />`, container)

    expect(container.textContent).toContain('귀속된 입력 바이트가 없어요')
    expect(container.textContent).toContain('codex_app_server.gpt-5-codex')
    expect(container.textContent).not.toContain('측정되지 않았어요')
  })

  // The panel's own justification is reading a segment against the turn
  // before it. Packing the bars over only the attributed turns made two
  // adjacent bars mean two turns that were not adjacent.
  it('keeps a bar per observed turn so the gaps stay visible', () => {
    const container = document.createElement('div')
    const attributed = (ts: number, bytes: number) =>
      metricPoint({
        ts,
        ctx_composition: {
          actual_input_tokens: 100,
          attribution: {
            status: 'attributed',
            runtime_profile: 'glm-coding.glm-5',
            attributed_bytes: bytes,
            segments: { tool_schemas: { bytes, fingerprint: null } },
          },
        },
      })
    const keeper = {
      name: 'gapped-keeper',
      status: 'active',
      metrics_series: [
        attributed(1, 400),
        metricPoint({
          ts: 2,
          ctx_composition: {
            actual_input_tokens: 100,
            attribution: {
              status: 'not_measured',
              reason: 'client_session_holds_input',
              detail: null,
            },
          },
        }),
        attributed(3, 800),
      ],
    } as Keeper

    render(html`<${CtxCompositionPanel} keeper=${keeper} />`, container)

    // Three observed turns, two of them drawn: the unmeasured turn holds its
    // slot rather than closing it.
    expect(container.textContent).toContain('3 turns')
    expect(container.textContent).toContain('1 미측정')
    expect(container.querySelectorAll('svg rect')).toHaveLength(2)
  })
})
