import { describe, expect, it } from 'vitest'
import { decodeOverrideApplied, decodePromptCatalog } from './prompts-wire'

// The shape `Prompt_registry.prompts_json` sends for one prompt.
const worldview = {
  key: 'keeper.worldview',
  override_default_moved: false,
  category: 'keeper',
  operator_surface: 'primary',
  authoring_issues: [],
  description: '이 세계의 가치관 — 무엇을 잘한 일로 치는가. 운영자가 덮어쓴다',
  current: '<world>\n</world>',
  effective: '<world>\n</world>',
  file_value: '<world>\n</world>',
  override_value: null,
  file_path: '/workspace/.masc/config/prompts/keeper.md',
  file_exists: true,
  source: 'file',
  has_override: false,
  char_count: 16,
  required_file: false,
  template_variables: [],
}

const authoringIssue = {
  code: 'invalid_operator_surface',
  field: 'operator_surface',
  value: 'primray',
  source_file: '/workspace/.masc/config/prompts/keeper.md',
}

describe('prompt catalog at the wire boundary', () => {
  it('reads the catalog the server sends, held-back overrides included', () => {
    const catalog = decodePromptCatalog({
      prompts: [worldview, { ...worldview, key: 'keeper', authoring_issues: [authoringIssue] }],
      held_back: [{ key: 'judge.board', bytes: 812, reason: 'template variable {{post}} is no longer declared' }],
      runtime_assets: [],
    })
    expect(catalog.prompts.map(p => p.key)).toEqual(['keeper.worldview', 'keeper'])
    expect(catalog.prompts[1]?.authoring_issues).toEqual([authoringIssue])
    expect(catalog.held_back[0]?.reason).toContain('{{post}}')
  })

  it('refuses a source, surface or authoring report it does not know rather than showing it as one it does', () => {
    for (const prompt of [
      { ...worldview, source: 'embedded' },
      { ...worldview, operator_surface: 'secondary' },
      { ...worldview, authoring_issues: [{ ...authoringIssue, code: 'unknown' }] },
      { ...worldview, authoring_issues: null },
      { ...worldview, char_count: '16' },
    ]) {
      expect(() => decodePromptCatalog({ prompts: [prompt], held_back: [] })).toThrow()
    }
    expect(() => decodePromptCatalog({ prompts: [worldview] })).toThrow()
  })

  it('reads the text in force after an override, with the curator refresh it queued', () => {
    const applied = decodeOverrideApplied({
      ok: true,
      message: 'Override saved for workspace_memory_curator',
      key: 'workspace_memory_curator',
      source: 'override',
      effective: '새 큐레이터 지침',
      curator_refresh: { status: 'unavailable', detail: 'curator lane is resting' },
    })
    expect(applied.curator_refresh).toEqual({ status: 'unavailable', detail: 'curator lane is resting' })
    expect(decodeOverrideApplied({ ...applied, curator_refresh: null }).curator_refresh).toBeNull()
    expect(() => decodeOverrideApplied({ ...applied, ok: false })).toThrow()
    expect(() => decodeOverrideApplied({ ...applied, curator_refresh: { status: 'later' } })).toThrow()
  })
})
