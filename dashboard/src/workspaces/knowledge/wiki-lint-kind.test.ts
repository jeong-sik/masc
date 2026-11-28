import { describe, expect, it } from 'vitest'
import { wikiLintCountLabel, wikiLintKindLabel } from './wiki-lint-kind'

describe('wiki lint names', () => {
  it('names a kind the server writes in Korean, and an unknown kind by its wire name', () => {
    expect(wikiLintKindLabel('broken_media_embed')).toBe('없는 그림 임베드')
    expect(wikiLintKindLabel('missing_sources')).toBe('출처 없음')
    expect(wikiLintKindLabel('kind_from_a_newer_server')).toBe('kind_from_a_newer_server')
  })

  it('names every counts key, including the duplicate title pairs that are no finding kind', () => {
    expect(wikiLintCountLabel('duplicate_title_candidates')).toBe('중복 제목 후보')
    expect(wikiLintCountLabel('orphan')).toBe('고아 문서')
    expect(wikiLintCountLabel('toString')).toBe('toString')
  })
})
