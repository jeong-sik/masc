import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { KEEPER_RUNTIME_BLOCKER_CLASSES } from '../types'
import type { Keeper, KeeperRuntimeBlockerClass } from '../types'
import {
  keeperActivityDisplay,
  keeperDisplayModel,
  keeperDisplayRuntime,
  keeperDisplayStatus,
  keeperPauseDisplay,
  keeperRuntimeBlockerHint,
  keeperRuntimeBlockerLabel,
  keeperRuntimeHint,
  keeperWorkPreview,
} from './keeper-runtime-display'

/** Minimal Keeper stub with only the fields relevant to status classification. */
function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'test-keeper',
    status: 'offline',
    ...overrides,
  } as Keeper
}

describe('keeperDisplayStatus', () => {
  it('returns paused when keeper.paused is true', () => {
    expect(keeperDisplayStatus(makeKeeper({ paused: true }))).toBe('paused')
  })

  it('returns paused when phase or pipeline carries pause truth', () => {
    expect(keeperDisplayStatus(makeKeeper({ status: 'offline', phase: 'Paused' }))).toBe('paused')
    expect(keeperDisplayStatus(makeKeeper({ status: 'offline', pipeline_stage: 'paused' }))).toBe('paused')
  })

  it('returns unknown for null keeper', () => {
    expect(keeperDisplayStatus(null)).toBe('unknown')
  })

  it('returns unknown for undefined keeper', () => {
    expect(keeperDisplayStatus(undefined)).toBe('unknown')
  })

  it('passes through non-offline statuses', () => {
    expect(keeperDisplayStatus(makeKeeper({ status: 'active' }))).toBe('active')
    expect(keeperDisplayStatus(makeKeeper({ status: 'idle' }))).toBe('idle')
  })

  describe('offline refinement into unbooted/stopped', () => {
    it('classifies offline keeper with no activity as unbooted', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 0,
        turn_count: 0,
        agent: { exists: false },
      })
      expect(keeperDisplayStatus(keeper)).toBe('unbooted')
    })

    it('classifies inactive keeper with no activity as unbooted', () => {
      const keeper = makeKeeper({
        status: 'inactive',
        generation: 0,
        turn_count: 0,
        agent: { exists: false },
      })
      expect(keeperDisplayStatus(keeper)).toBe('unbooted')
    })

    it('classifies offline keeper with generation > 0 as stopped', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 3,
        turn_count: 0,
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })

    it('classifies offline keeper with turn_count > 0 as stopped', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 0,
        turn_count: 5,
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })

    it('classifies offline keeper with agent.exists=true but no turns as offline', () => {
      // agent exists but generation=0, turn_count=0 — doesn't match unbooted
      // (agent exists) and doesn't match stopped (no turns/generation)
      const keeper = makeKeeper({
        status: 'offline',
        generation: 0,
        turn_count: 0,
        agent: { exists: true },
      })
      expect(keeperDisplayStatus(keeper)).toBe('offline')
    })

    it('classifies offline keeper with all activity signals as stopped', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 2,
        turn_count: 10,
        agent: { exists: true },
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })

    it('uses lifecycle_phase when heartbeat is alive but status is offline', () => {
      const keeper = makeKeeper({
        status: 'offline',
        phase: 'Running',
        lifecycle_phase: 'Stopped',
        last_heartbeat: new Date().toISOString(),
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })

    it('does not turn exact Offline lifecycle into idle just because heartbeat is recent', () => {
      const keeper = makeKeeper({
        status: 'offline',
        lifecycle_phase: 'Offline',
        last_heartbeat: new Date().toISOString(),
      })
      expect(keeperDisplayStatus(keeper)).toBe('unbooted')
    })

    it('lets terminal lifecycle override stale active status', () => {
      const keeper = makeKeeper({
        status: 'active',
        phase: 'Running',
        lifecycle_phase: 'Dead',
      })
      expect(keeperDisplayStatus(keeper)).toBe('dead')
    })
  })
})

describe('keeperDisplayModel', () => {
  it('redacts active runtime labels', () => {
    expect(
      keeperDisplayModel({
        active_model_label: 'claude-code:auto',
        active_model: 'claude',
        model: 'claude',
      }),
    ).toBeNull()
  })

  it('does not fall back to metrics-series model labels', () => {
    expect(
      keeperDisplayModel({
        active_model: 'claude-code:auto',
        metrics_series: [
          { model_used: 'openai:gpt-5.4' },
          { model_used: 'anthropic:claude-sonnet' },
        ],
      }),
    ).toBeNull()
  })

  it('redacts even non-placeholder legacy labels', () => {
    expect(
      keeperDisplayModel({
        last_model_used: 'unknown',
        active_model: 'claude-code:auto',
        model: 'claude',
      }),
    ).toBeNull()
  })

  it('redacts provider auto labels and primary model labels', () => {
    expect(
      keeperDisplayModel({
        last_model_used_label: 'default',
        last_model_used: 'auto',
        active_model_label: 'codex-cli:auto',
        primary_model: 'openai:gpt-5.4',
      }),
    ).toBeNull()
  })

  it('redacts metrics-only model labels', () => {
    expect(
      keeperDisplayModel({
        metrics_series: [
          { model_used: 'openai:gpt-5.4' },
          { model_used: 'anthropic:claude-sonnet' },
        ],
      }),
    ).toBeNull()
  })
})

describe('keeperDisplayRuntime', () => {
  it('prefers runtime_canonical then selected_runtime_canonical', () => {
    expect(
      keeperDisplayRuntime({
        runtime_canonical: 'oas.primary',
        selected_runtime_canonical: 'oas.secondary',
        runtime_id: 'legacy.runtime',
      }),
    ).toEqual({ label: 'Runtime', value: 'oas.primary' })
    expect(
      keeperDisplayRuntime({
        selected_runtime_canonical: 'oas.secondary',
        runtime_id: 'legacy.runtime',
      }),
    ).toEqual({ label: 'Runtime', value: 'oas.secondary' })
  })

  it('falls back to runtime_id', () => {
    expect(keeperDisplayRuntime({ runtime_id: 'keeper_unified' })).toEqual({
      label: 'Runtime',
      value: 'keeper_unified',
    })
  })

  it('falls back to runtime_ref group and item', () => {
    expect(
      keeperDisplayRuntime({ runtime_ref: { group: 'tier', item: 'resilient_breaker' } }),
    ).toEqual({ label: 'Runtime', value: 'tier.resilient_breaker' })
    expect(keeperDisplayRuntime({ runtime_ref: { group: 'tier', item: null } })).toEqual({
      label: 'Runtime',
      value: 'tier',
    })
  })

  it('returns null for missing or blank runtime evidence', () => {
    expect(keeperDisplayRuntime(null)).toBeNull()
    expect(
      keeperDisplayRuntime({
        runtime_canonical: ' ',
        selected_runtime_canonical: '',
        runtime_id: ' ',
        runtime_ref: { group: ' ', item: 'ignored' },
      }),
    ).toBeNull()
  })
})

describe('keeperPauseDisplay', () => {
  it('returns null for active keepers', () => {
    expect(keeperPauseDisplay(makeKeeper({ status: 'active', phase: 'Running' }))).toBeNull()
  })

  it('surfaces blocker, next action, diagnostic, and raw axes for paused keepers', () => {
    const display = keeperPauseDisplay(makeKeeper({
      status: 'paused',
      phase: 'Paused',
      pipeline_stage: 'paused',
      paused: true,
      runtime_blocker_class: 'fiber_unresolved',
      attention_reason: 'paused',
      next_human_action: 'inspect_blocker_before_resume',
      diagnostic: {
        health_state: 'offline',
        next_action_path: 'recover',
        last_reply_status: 'unknown',
        continuity_state: 'not_running',
      },
    }))

    expect(display).toMatchObject({
      reason: 'Fiber 미해결',
      nextAction: 'inspect blocker before resume',
      diagnostic: 'offline/not running',
    })
    expect(display?.detail).toContain('원인 Fiber 미해결')
    expect(display?.detail).toContain('다음 inspect blocker before resume')
    expect(display?.detail).toContain('진단 offline/not running')
    expect(display?.title).toContain('paused=true')
    expect(display?.title).toContain('status=paused')
  })
})

describe('keeperRuntimeBlockerLabel', () => {
  it('labels backend-emitted terminal keeper failure classes', () => {
    expect(keeperRuntimeBlockerLabel('provider_runtime_error')).toBe(
      '런타임 호출 오류',
    )
    expect(keeperRuntimeBlockerLabel('runtime_exhausted')).toBe('런타임 후보 소진')
  })

  it('labels the 9 RFC-0062 SDK blocker variants', () => {
    expect(keeperRuntimeBlockerLabel('sdk_max_turns_exceeded')).toBe('SDK 최대 턴 초과')
    expect(keeperRuntimeBlockerLabel('sdk_token_budget_exceeded')).toBe('SDK 토큰 예산 초과')
    expect(keeperRuntimeBlockerLabel('sdk_cost_budget_exceeded')).toBe('SDK 비용 예산 초과')
    expect(keeperRuntimeBlockerLabel('sdk_unrecognized_stop_reason')).toBe('SDK 미식별 정지 사유')
    expect(keeperRuntimeBlockerLabel('sdk_idle_detected')).toBe('SDK Idle 감지')
    expect(keeperRuntimeBlockerLabel('sdk_guardrail_violation')).toBe('SDK 가드레일 위반')
    expect(keeperRuntimeBlockerLabel('sdk_tripwire_violation')).toBe('SDK Tripwire 위반')
    expect(keeperRuntimeBlockerLabel('sdk_exit_condition_met')).toBe('SDK 종료 조건 충족')
  })

  it('SSOT regression guard — every literal in KEEPER_RUNTIME_BLOCKER_CLASSES has a non-null label', () => {
    for (const cls of KEEPER_RUNTIME_BLOCKER_CLASSES) {
      expect(keeperRuntimeBlockerLabel(cls), `missing label for ${cls}`).not.toBeNull()
    }
  })
})

describe('keeperRuntimeBlockerHint', () => {
  it('explains runtime terminal failures when no summary is available', () => {
    expect(
      keeperRuntimeBlockerHint(makeKeeper({
        runtime_blocker_class: 'provider_runtime_error',
        runtime_blocker_summary: 'provider_runtime_error',
      })),
    ).toBe('런타임 호출 경계가 keeper 진행 전에 실패했습니다.')
  })

  it('explains recoverable tool-route failures when no summary is available', () => {
    expect(
      keeperRuntimeBlockerHint(makeKeeper({
        runtime_blocker_class: 'runtime_exhausted',
        runtime_blocker_summary: 'runtime_exhausted',
      })),
    ).toBe('런타임 후보가 모두 소진되어 runtime 상태 확인이 필요합니다.')
  })

  it('explains admission queue waits as keeper FIFO waits, not OAS waits', () => {
    expect(
      keeperRuntimeBlockerHint(makeKeeper({
        runtime_blocker_class: 'admission_queue_wait_timeout',
        runtime_blocker_summary: 'admission_queue_wait_timeout',
      })),
    ).toBe('Keeper admission FIFO 대기 시간이 초과되었습니다.')
  })

  it('explains no-progress loop as a safety latch cleared by resume', () => {
    expect(
      keeperRuntimeBlockerHint(makeKeeper({
        runtime_blocker_class: 'no_progress_loop',
        runtime_blocker_summary: 'no_progress_loop',
      })),
    ).toBe(
      '반복된 무증거 턴으로 자동 정지된 progress-safety latch입니다. provider 실패가 아니며 Resume이 latch를 해제합니다.',
    )
  })

  it('normalizes legacy no-progress pause detail before rendering runtime hints', () => {
    const hint = keeperRuntimeHint(makeKeeper({
      status: 'paused',
      paused: true,
      last_blocker: 'no_progress loop detected: streak=10 threshold=10; manual pause applied',
    }))

    expect(hint).toBe(
      '일시정지 · 반복된 무증거 턴으로 자동 정지된 progress-safety latch입니다. provider 실패가 아니며 Resume이 latch를 해제합니다.',
    )
    expect(hint).not.toContain('manual pause applied')
  })

  const registryBlockerHintCases: Array<[KeeperRuntimeBlockerClass, string]> = [
    [
      'stale_termination_storm',
      'Stale watchdog 종료가 반복되어 restart 전에 원인 확인이 필요합니다.',
    ],
    [
      'heartbeat_failures',
      '하트비트 실패가 누적되어 keeper 생존 상태 확인이 필요합니다.',
    ],
    [
      'turn_failures',
      '턴 실패가 반복되어 최근 실행 오류 확인이 필요합니다.',
    ],
    [
      'exception',
      'Keeper 런타임 예외가 기록되어 로그와 최근 turn 상태 확인이 필요합니다.',
    ],
    [
      'awaiting_operator',
      '진행을 위해 운영자의 승인, 결정, 또는 게이트 해제가 필요합니다.',
    ],
    [
      'awaiting_sandbox_egress',
      '샌드박스 네트워크 또는 push egress 정책 때문에 keeper가 진행하지 못하고 있습니다.',
    ],
    [
      'supervisor_paused',
      'Supervisor가 keeper를 일시정지한 상태라 재개 조건을 확인해야 합니다.',
    ],
    [
      'synthetic_stall',
      '실제 STATE 없이 합성된 진행 기록만 남아 최근 턴 산출물을 재확인해야 합니다.',
    ],
    [
      'self_imposed_idle',
      'Keeper가 관찰 또는 대기만 계획하고 있어 다음 실행 지시가 필요할 수 있습니다.',
    ],
  ]

  it.each(registryBlockerHintCases)(
    'explains registry-derived blocker %s when no summary is available',
    (blockerClass, expected) => {
      expect(
        keeperRuntimeBlockerHint(makeKeeper({
          runtime_blocker_class: blockerClass,
          runtime_blocker_summary: blockerClass,
        })),
      ).toBe(expected)
    },
  )
})

describe('keeperActivityDisplay', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-04-24T18:00:00Z'))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('uses heartbeat as the latest live signal when autonomous action is older', () => {
    expect(
      keeperActivityDisplay({
        last_autonomous_action_at: '2026-04-24T12:00:00Z',
        last_heartbeat: '2026-04-24T17:54:00Z',
      }),
    ).toEqual({
      source: 'heartbeat',
      label: '하트비트',
      timestamp: '2026-04-24T17:54:00Z',
      ageSeconds: 360,
    })
  })

  it('uses live activity source labels for tool and approval activity', () => {
    expect(
      keeperActivityDisplay({
        last_activity_at: '2026-04-24T17:59:30Z',
        last_activity_source: 'approval_pending',
        last_heartbeat: '2026-04-24T17:54:00Z',
      }),
    ).toEqual({
      source: 'approval_pending',
      label: '승인 대기',
      timestamp: '2026-04-24T17:59:30Z',
      ageSeconds: 30,
    })

    const toolActivity = keeperActivityDisplay({
      last_activity_at: '2026-04-24T17:58:00Z',
      last_activity_source: 'tool_call',
      last_turn_ago_s: 180,
    })
    expect(toolActivity.source).toBe('tool_call')
    expect(toolActivity.label).toBe('도구 활동')
  })

  it('does not let agent last_seen override keeper runtime signals', () => {
    expect(
      keeperActivityDisplay(
        { last_heartbeat: '2026-04-24T17:54:00Z' },
        '2026-04-24T17:59:00Z',
      ).source,
    ).toBe('heartbeat')
  })

  it('uses autonomous action when it is newer than heartbeat', () => {
    expect(
      keeperActivityDisplay({
        last_autonomous_action_at: '2026-04-24T17:59:00Z',
        last_heartbeat: '2026-04-24T17:54:00Z',
      }).source,
    ).toBe('autonomous_action')
  })

  it('falls back to numeric activity age when no timestamp exists', () => {
    expect(
      keeperActivityDisplay({
        last_activity_ago_s: 75,
        last_turn_ago_s: 180,
      }),
    ).toEqual({
      source: 'last_activity',
      label: '최근 활동',
      timestamp: null,
      ageSeconds: 75,
    })
  })

  // SSOT regression guard: keeper detail에서 헤드라인(last_heartbeat raw),
  // 사이드바(activityDisplay), 헤더(created_at raw)가 서로 다른 필드를 읽어
  // "26초 전 / 18시간 전 / 27일 전"이 동시에 렌더링되던 문제.
  // 동일 keeper 입력에 대해 helper가 단일 source/timestamp/ageSeconds를
  // 반환해야 모든 surface가 동일 값을 표시할 수 있다.
  it('picks a single freshest source when heartbeat, turn, and created_at all coexist', () => {
    const result = keeperActivityDisplay({
      // 26초 전 — freshest, 우승해야 함
      last_heartbeat: '2026-04-24T17:59:34Z',
      // 18시간 전
      last_turn_ago_s: 18 * 3600,
      // 27일 전 — 활동 후보가 있을 때는 절대 선택되면 안 됨
      created_at: '2026-03-28T18:00:00Z',
    })
    expect(result.source).toBe('heartbeat')
    expect(result.timestamp).toBe('2026-04-24T17:59:34Z')
    expect(result.ageSeconds).toBe(26)
  })

  it('falls back to created_at only when every activity candidate is absent', () => {
    const result = keeperActivityDisplay({
      created_at: '2026-03-28T18:00:00Z',
    })
    expect(result.source).toBe('created')
    expect(result.label).toBe('생성')
  })

  it('can suppress created_at when a surface only wants operational activity', () => {
    const result = keeperActivityDisplay(
      {
        created_at: '2026-03-28T18:00:00Z',
      },
      undefined,
      { includeCreated: false },
    )
    expect(result.source).toBe('none')
    expect(result.ageSeconds).toBeNull()
  })
})

describe('keeperWorkPreview', () => {
  it('prefers a message output over the proactive preview and goal', () => {
    expect(
      keeperWorkPreview(
        makeKeeper({
          recent_output_preview: '메시지 출력',
          last_proactive_preview: 'proactive',
          goal: '목표',
        }),
      ),
    ).toBe('메시지 출력')
  })

  it('surfaces last_proactive_preview when message previews are empty', () => {
    // The proactive-only keeper: no broadcast (recent_output/input empty), no
    // goal/current_task — work lives solely in last_proactive_preview.
    expect(
      keeperWorkPreview(
        makeKeeper({
          recent_output_preview: '',
          recent_input_preview: null,
          last_proactive_preview: 'Continuation checkpoint saved.',
        }),
      ),
    ).toBe('Continuation checkpoint saved.')
  })

  it('falls through to goal then current_task', () => {
    expect(keeperWorkPreview(makeKeeper({ goal: 'long' }))).toBe('long')
    expect(keeperWorkPreview(makeKeeper({ agent: { current_task: 'task-7' } }))).toBe('task-7')
  })

  it('returns null when no signal exists', () => {
    expect(keeperWorkPreview(makeKeeper({}))).toBeNull()
    expect(keeperWorkPreview(null)).toBeNull()
    expect(keeperWorkPreview(undefined)).toBeNull()
  })
})
