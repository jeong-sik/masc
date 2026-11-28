// The Korean name of each wiki lint kind. The keys are the wire names
// `Wiki_lint.kind` writes in lib/wiki_lint.ml, in the order of its
// `all_kinds`.

const WIKI_LINT_KIND_LABELS = {
  broken_link: '깨진 링크',
  unsupported_link: '지원하지 않는 링크',
  broken_media_embed: '없는 그림 임베드',
  broken_wiki_embed: '없는 문서 임베드',
  broken_artifact_embed: '없는 아티팩트 임베드',
  invalid_embed: '잘못 쓴 임베드',
  unsupported_embed: '지원하지 않는 임베드',
  orphan: '고아 문서',
  orphan_unconfirmed: '고아 후보',
  missing_sources: '출처 없음',
  hearsay_only: '들은 말(said:)만 출처로 있음',
  unreadable_page: '읽을 수 없는 문서',
  revision_log_gap: '로그 리비전이 문서보다 앞섬',
  revision_log_hole: '로그에 빠진 리비전',
} as const satisfies Record<string, string>

type WikiLintKind = keyof typeof WIKI_LINT_KIND_LABELS

function isWikiLintKind(kind: string): kind is WikiLintKind {
  return Object.hasOwn(WIKI_LINT_KIND_LABELS, kind)
}

/** The Korean name of a lint kind. A kind this table does not know is shown
 *  as the server wrote it, so a new kind reads as itself rather than as
 *  another kind's name. */
export function wikiLintKindLabel(kind: string): string {
  return isWikiLintKind(kind) ? WIKI_LINT_KIND_LABELS[kind] : kind
}
