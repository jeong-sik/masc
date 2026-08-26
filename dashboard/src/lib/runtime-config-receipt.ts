import type { CommittedRuntimeSkillApplication, CommittedRuntimeTomlConfig } from '../api/dashboard-runtime'

function routingApplicationNotice(
  routing: CommittedRuntimeTomlConfig['application']['routing'],
): string {
  switch (routing.status) {
    case 'applied':
      return '라우팅 적용됨'
    case 'active':
      return '라우팅 활성 상태 확인됨'
  }
}

function skillApplicationNotice(application: CommittedRuntimeSkillApplication): string {
  switch (application.state) {
    case 'published':
      return `Skill catalog 게시됨 (${application.config_state})`
    case 'unchanged':
      return `Skill catalog 변경 없음 (${application.config_state})`
    case 'workspace_retired':
      return 'Skill workspace가 적용 중 종료됨'
    case 'superseded':
      return `Skill catalog 최신 커밋 유지 (#${application.applied_order})`
    case 'invalid_workspace':
      return 'Skill workspace가 유효하지 않음'
  }
}

export function runtimeConfigCommitReceiptNotice(receipt: CommittedRuntimeTomlConfig): string {
  const keeperOverlay = receipt.application.keeper_overlay
  const runtimeNotice = keeperOverlay.requires_restart
    ? `${routingApplicationNotice(receipt.application.routing)} · Keeper 설정 ${keeperOverlay.pending_keys.length}개 재시작 대기`
    : routingApplicationNotice(receipt.application.routing)
  const durabilityNotice = receipt.commit.durability === 'durable'
    ? '파일 내구성 확인됨'
    : '파일 교체됨 · 디렉터리 동기화 미확인'

  return [
    `커밋 #${receipt.commit.order}`,
    runtimeNotice,
    skillApplicationNotice(receipt.application.skills),
    durabilityNotice,
  ].join(' · ')
}
