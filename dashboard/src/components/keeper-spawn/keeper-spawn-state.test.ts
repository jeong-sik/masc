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
  createPersona,
  deletePersona,
  loadPersonas,
  personasResource,
  spawnKeeperFromPersona,
  spawnResult,
  updatePersona,
} from './keeper-spawn-state'

afterEach(() => {
  spawnResult.value = null
  personasResource.reset()
  vi.clearAllMocks()
})

describe('loadPersonas', () => {
  it('requests and stores only the detailed backend contract', async () => {
    callMcpTool.mockResolvedValue(JSON.stringify({
      count: 1,
      personas: [{
        persona_name: 'reviewer',
        display_name: 'Reviewer',
        role: null,
        trait: 'strict',
        profile_path: '/personas/reviewer/profile.json',
        has_keeper_defaults: true,
      }],
    }))

    await loadPersonas()

    expect(callMcpTool).toHaveBeenCalledWith('masc_persona_list', { detailed: true })
    expect(personasResource.state.value).toMatchObject({
      status: 'loaded',
      data: [{ persona_name: 'reviewer', has_keeper_defaults: true }],
    })
  })

  it('surfaces malformed entries through the resource error state', async () => {
    callMcpTool.mockResolvedValue(JSON.stringify({ count: 1, personas: ['legacy-name'] }))

    await loadPersonas()

    expect(personasResource.state.value).toMatchObject({
      status: 'error',
    })
  })
})

describe('createPersona', () => {
  it('forwards identity and keeper-template fields to masc_persona_create', async () => {
    callMcpTool.mockResolvedValue('{"personas":[]}')
    const ok = await createPersona({
      persona_name: 'code-reviewer',
      display_name: '코드 리뷰어',
      role: 'reviewer',
      trait: '꼼꼼한 검증가',
      instructions: '너는 리뷰어다',
      mention_targets: ['reviewer', '리뷰어'],
      proactive_enabled: true,
    })
    expect(ok).toBe(true)
    expect(callMcpTool).toHaveBeenCalledWith('masc_persona_create', {
      persona_name: 'code-reviewer',
      display_name: '코드 리뷰어',
      role: 'reviewer',
      trait: '꼼꼼한 검증가',
      instructions: '너는 리뷰어다',
      mention_targets: ['reviewer', '리뷰어'],
      proactive_enabled: true,
    })
  })

  it('omits unset fields and empty mention_targets from the payload', async () => {
    callMcpTool.mockResolvedValue('{"personas":[]}')
    await createPersona({
      persona_name: 'minimal',
      display_name: '미니멀',
      mention_targets: [],
    })
    expect(callMcpTool).toHaveBeenCalledWith('masc_persona_create', {
      persona_name: 'minimal',
      display_name: '미니멀',
    })
  })
})

describe('updatePersona', () => {
  it('sends only the provided fields so unspecified ones keep their value', async () => {
    callMcpTool.mockResolvedValue('{"personas":[]}')
    await updatePersona('oracle', { instructions: 'new instructions' })
    expect(callMcpTool).toHaveBeenCalledWith('masc_persona_update', {
      persona_name: 'oracle',
      instructions: 'new instructions',
    })
  })
})

describe('deletePersona', () => {
  it('calls masc_persona_delete with the persona name', async () => {
    callMcpTool.mockResolvedValue('{"personas":[]}')
    const ok = await deletePersona('oracle')
    expect(ok).toBe(true)
    expect(callMcpTool).toHaveBeenCalledWith('masc_persona_delete', {
      persona_name: 'oracle',
    })
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
