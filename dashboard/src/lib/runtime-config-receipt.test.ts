import { describe, expect, it } from 'vitest'
import { committedRuntimeTomlConfigFixture } from './runtime-config-receipt.test-fixture'
import { runtimeConfigCommitReceiptNotice } from './runtime-config-receipt'

const baseConfig = {
  ok: true,
  path: '/tmp/.masc/config/runtime.toml',
  file_name: 'runtime.toml',
  source_text: '[runtime]\n',
}

describe('runtimeConfigCommitReceiptNotice', () => {
  it('shows published Skill state and durable commit order', () => {
    const notice = runtimeConfigCommitReceiptNotice(
      committedRuntimeTomlConfigFixture(baseConfig),
    )

    expect(notice).toContain('커밋 #7')
    expect(notice).toContain('Skill catalog 게시됨 (configured)')
    expect(notice).toContain('파일 내구성 확인됨')
  })

  it('renders the typed active routing status without claiming a new apply', () => {
    const notice = runtimeConfigCommitReceiptNotice(
      committedRuntimeTomlConfigFixture(baseConfig, {
        routing: { status: 'active', requires_restart: false, applied_at: null },
      }),
    )

    expect(notice).toContain('라우팅 활성 상태 확인됨')
    expect(notice).not.toContain('라우팅 적용됨')
  })

  it('shows unchanged and superseded Skill applications', () => {
    const unchanged = runtimeConfigCommitReceiptNotice(
      committedRuntimeTomlConfigFixture(baseConfig, {
        skills: {
          state: 'unchanged',
          input_source_revision: 'runtime-source-revision',
          snapshot_revision: 'skill-snapshot-revision',
          catalog_revision: 'skill-catalog-revision',
          config_state: 'configured',
        },
      }),
    )
    const superseded = runtimeConfigCommitReceiptNotice(
      committedRuntimeTomlConfigFixture(baseConfig, {
        order: '8',
        skills: { state: 'superseded', commit_order: '8', applied_order: '9' },
      }),
    )

    expect(unchanged).toContain('Skill catalog 변경 없음 (configured)')
    expect(superseded).toContain('Skill catalog 최신 커밋 유지 (#9)')
  })

  it('shows unconfirmed durability without claiming durable storage', () => {
    const notice = runtimeConfigCommitReceiptNotice(
      committedRuntimeTomlConfigFixture(baseConfig, { durability: 'unconfirmed' }),
    )

    expect(notice).toContain('파일 교체됨 · 디렉터리 동기화 미확인')
    expect(notice).not.toContain('파일 내구성 확인됨')
  })
})
