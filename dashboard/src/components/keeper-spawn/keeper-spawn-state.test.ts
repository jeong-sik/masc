import { afterEach, describe, expect, it, vi } from 'vitest'

const { callMcpTool, showToast, shellAuthSummary } = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
  showToast: vi.fn(),
  shellAuthSummary: { value: { effective_role: 'worker', default_role: 'worker', auth_error_code: null, auth_error_detail: null } },
}))

vi.mock('../../api/mcp', () => ({
  callMcpTool,
}))

vi.mock('../common/toast', () => ({
  showToast,
}))

vi.mock('../../store', () => ({
  shellAuthSummary,
}))

import {
  normalizePersonaSummaries,
  normalizePersonaSummary,
  spawnKeeperFromPersona,
  spawnResult,
} from './keeper-spawn-state'

afterEach(() => {
  spawnResult.value = null
  vi.clearAllMocks()
})

describe('normalizePersonaSummary', () => {
  it('accepts backend persona summary fields and keeps the handle for spawning', () => {
    expect(
      normalizePersonaSummary({
        persona_name: 'sonsukku',
        display_name: '손석구',
        role: '무심한 로코형 동네 형',
        trait: '건조한 농담과 낮은 텐션',
      }),
    ).toEqual({
      name: 'sonsukku',
      displayName: '손석구',
      role: '무심한 로코형 동네 형',
      mode: undefined,
      description: '건조한 농담과 낮은 텐션',
    })
  })

  it('falls back to existing dashboard-shaped fields when they already match', () => {
    expect(
      normalizePersonaSummary({
        name: 'sangsu',
        displayName: '상수',
        role: '찌질한 영화감독',
        description: '직설적이고 현실 감각 있는 동네 형',
      }),
    ).toEqual({
      name: 'sangsu',
      displayName: '상수',
      role: '찌질한 영화감독',
      mode: undefined,
      description: '직설적이고 현실 감각 있는 동네 형',
    })
  })
})

describe('normalizePersonaSummaries', () => {
  it('reads both wrapped and bare arrays and filters invalid entries', () => {
    expect(
      normalizePersonaSummaries({
        personas: [
          { persona_name: 'sonsukku', display_name: '손석구' },
          { name: '' },
          'skip-me',
        ],
      }),
    ).toEqual([
      {
        name: 'sonsukku',
        displayName: '손석구',
        role: undefined,
        mode: undefined,
        description: undefined,
      },
    ])
  })
})

describe('spawnKeeperFromPersona', () => {
  it('turns raw forbidden keeper-spawn errors into actionable auth guidance', async () => {
    callMcpTool.mockRejectedValueOnce(
      new Error('🚫 Forbidden: agent-3a9df104 cannot masc_keeper_create_from_persona'),
    )

    await spawnKeeperFromPersona('sonsukku')

    expect(spawnResult.value).toEqual({
      success: false,
      message:
        'agent-3a9df104 세션은 현재 키퍼 생성 권한이 없습니다. 이 프로젝트의 auth가 읽기 전용(default_role=reader)으로 열려 있거나 reader 토큰을 사용 중일 때 생기는 오류입니다. worker/admin Bearer token을 설정하거나 프로젝트 기본 권한을 올린 뒤 다시 시도하세요.',
    })
    expect(showToast).toHaveBeenCalledWith(
      '키퍼 생성 실패: agent-3a9df104 세션은 현재 키퍼 생성 권한이 없습니다. 이 프로젝트의 auth가 읽기 전용(default_role=reader)으로 열려 있거나 reader 토큰을 사용 중일 때 생기는 오류입니다. worker/admin Bearer token을 설정하거나 프로젝트 기본 권한을 올린 뒤 다시 시도하세요.',
      'error',
    )
  })
})
