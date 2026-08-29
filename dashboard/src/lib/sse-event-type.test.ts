import { describe, expect, it } from 'vitest'
import {
  agentCoreEventSuffix,
  isAgentCoreEventType,
  isMascNamespacedEventType,
  sseEventFamily,
  withoutMascNamespace,
} from './sse-event-type'

// 일곱 모듈이 각자 startsWith 로 물었을 때는 이 답들이 어디에도 적혀 있지
// 않았다. 한 곳으로 모았으니 여기서 한 번 고정한다.

describe('isAgentCoreEventType', () => {
  it('agent_core 네임스페이스를 알아본다', () => {
    expect(isAgentCoreEventType('agent_core:turn_completed')).toBe(true)
    expect(isAgentCoreEventType('agent_core:masc:harness:handoff')).toBe(true)
  })

  it('네임스페이스가 아닌 이름은 아니다', () => {
    expect(isAgentCoreEventType('keeper_heartbeat')).toBe(false)
    expect(isAgentCoreEventType('')).toBe(false)
    // 가운데 있는 건 네임스페이스가 아니다.
    expect(isAgentCoreEventType('masc/agent_core:x')).toBe(false)
  })
})

describe('agentCoreEventSuffix', () => {
  it('payload reader 를 찾을 이름만 남긴다', () => {
    expect(agentCoreEventSuffix('agent_core:turn_completed')).toBe('turn_completed')
    expect(agentCoreEventSuffix('agent_core:masc:harness:handoff')).toBe('masc:harness:handoff')
  })

  it('네임스페이스가 없으면 그대로 둔다', () => {
    expect(agentCoreEventSuffix('keeper_heartbeat')).toBe('keeper_heartbeat')
  })
})

describe('withoutMascNamespace', () => {
  it('masc/ 쌍둥이를 bare 이름으로 되돌린다', () => {
    expect(withoutMascNamespace('masc/keeper_handoff')).toBe('keeper_handoff')
    expect(isMascNamespacedEventType('masc/keeper_handoff')).toBe(true)
  })

  it('bare 이름은 그대로 둔다', () => {
    expect(withoutMascNamespace('keeper_handoff')).toBe('keeper_handoff')
    expect(isMascNamespacedEventType('keeper_handoff')).toBe(false)
  })
})

describe('sseEventFamily', () => {
  it.each([
    ['task_created', 'task'],
    ['keeper_heartbeat', 'keeper'],
    ['decision_recorded', 'decision'],
    ['board_post', 'board'],
    ['runtime_param_changed', 'other'],
  ])('%s 는 %s 계열', (type, family) => {
    expect(sseEventFamily(type)).toBe(family)
  })

  // 세 화면이 각자 bare 이름과 masc/ 쌍둥이를 따로 물었다. 같은 계열이다.
  it.each([
    ['masc/task_created', 'task'],
    ['masc/keeper_handoff', 'keeper'],
    ['masc/decision_recorded', 'decision'],
    ['masc/board_post', 'board'],
  ])('%s 도 %s 계열', (type, family) => {
    expect(sseEventFamily(type)).toBe(family)
  })

  it('앞뒤 공백은 계열을 바꾸지 않는다', () => {
    expect(sseEventFamily('  task_created  ')).toBe('task')
  })
})
