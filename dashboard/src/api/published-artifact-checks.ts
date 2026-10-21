import { Schema } from 'effect'
import { get, post } from './core'
import type { PublishedArtifact } from './published-artifacts'

const CheckSchema = Schema.Struct({
  id: Schema.String.pipe(Schema.pattern(/^artifact-[0-9a-f]{32}$/)),
  revision: Schema.Int.pipe(Schema.positive(), Schema.lessThanOrEqualTo(Number.MAX_SAFE_INTEGER)),
  body_sha256: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/)),
  checked: Schema.Boolean,
  change_id: Schema.String.pipe(Schema.pattern(/^check-[0-9a-f]{32}$/)),
  changed_by: Schema.NonEmptyString, changed_at: Schema.NonEmptyString,
})
const ListSchema = Schema.Struct({
  checks: Schema.Array(CheckSchema),
  diagnostics: Schema.Array(Schema.Struct({ file: Schema.String, error: Schema.String })),
})
const ChangeSchema = Schema.Struct({ check: CheckSchema })
export type ArtifactCheck = typeof CheckSchema.Type
export type ArtifactCheckList = typeof ListSchema.Type
export type ArtifactCheckState = { kind: 'known'; check: ArtifactCheck | null }
  | { kind: 'unknown'; message: string }

function validateCheck(check: ArtifactCheck): void {
  if (!check.changed_by.trim() || !Number.isFinite(Date.parse(check.changed_at))) {
    throw new Error('확인 기록의 작성자 또는 시각이 올바르지 않습니다.')
  }
}

export function resolveArtifactCheck(artifact: PublishedArtifact, listing: ArtifactCheckList): ArtifactCheckState {
  if (listing.diagnostics.length) return { kind: 'unknown', message: '일부 확인 기록을 읽지 못했습니다.' }
  const check = listing.checks.find(check => check.id === artifact.id && check.revision === artifact.revision)
  if (check && check.body_sha256 !== artifact.body.sha256) {
    return { kind: 'unknown', message: '확인 기록의 본문과 문서가 다릅니다.' }
  }
  return { kind: 'known', check: check ?? null }
}

export async function fetchArtifactChecks(signal?: AbortSignal): Promise<ArtifactCheckList> {
  const listing = Schema.decodeUnknownSync(ListSchema)(await get<unknown>('/api/v1/published-artifact-checks', { signal }))
  const keys = new Set<string>()
  for (const check of listing.checks) {
    validateCheck(check)
    const key = JSON.stringify([check.id, check.revision])
    if (keys.has(key)) throw new Error('같은 문서 버전의 확인 기록이 중복됐습니다.')
    keys.add(key)
  }
  return listing
}

export async function setArtifactCheck(artifact: PublishedArtifact, previous: ArtifactCheck | null, checked: boolean): Promise<ArtifactCheck> {
  const response = Schema.decodeUnknownSync(ChangeSchema)(await post<unknown>('/api/v1/published-artifact-checks', {
    id: artifact.id, revision: artifact.revision, body_sha256: artifact.body.sha256,
    expected_change_id: previous?.change_id ?? null, checked,
  }))
  const check = response.check
  validateCheck(check)
  if (check.id !== artifact.id || check.revision !== artifact.revision || check.body_sha256 !== artifact.body.sha256
    || check.checked !== checked || check.change_id === previous?.change_id) {
    throw new Error('요청한 문서 버전의 확인 결과와 응답이 다릅니다. 확인 상태를 다시 조회해 주세요.')
  }
  return check
}
