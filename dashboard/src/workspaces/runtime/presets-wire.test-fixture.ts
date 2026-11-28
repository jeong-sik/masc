// Preset answers in the shape `Server_routes_http_routes_presets` and
// `Prompt_preset.*_to_json` write them, extra fields included.

export const manifest = (name: string, extra: Record<string, unknown> = {}) => ({
  schema_version: 1,
  name,
  description: `${name} description`,
  created_at: '2026-10-07T02:15:46Z',
  override_count: 1,
  override_keys: ['keeper.worldview'],
  keepers: ['code-reviewer', 'muse'],
  assignment_count: 2,
  lane_count: 1,
  ...extra,
})

export const listing = (names: readonly string[], unreadable: readonly unknown[] = []) => ({
  ok: true,
  presets: names.map(name => manifest(name)),
  unreadable,
})

export const snapshot = (name: string) => ({
  schema_version: 1,
  name,
  description: `${name} description`,
  created_at: '2026-10-07T02:15:46Z',
  default_revisions: null,
  preserved_lane_settings: [{ lane: 'verifier_exact', setting: 'thinking' }],
  skipped_lanes: [{ lane: 'retired_exact', reason: 'lane is unavailable in this runtime; no declaration is changed' }],
  prompt_overrides: [{
    key: 'keeper.worldview',
    value: '<world>\n잘한 일은 증거로 남긴 일이다.\n</world>',
    bytes: 52,
    authored_against: 'abc',
    template_variables: [],
  }],
  instructions: [
    { keeper_file: 'code-reviewer', bytes: 12, text: 'review code.' },
    { keeper_file: 'muse', bytes: 11, text: 'write well.' },
  ],
  assignments: [
    { keeper: 'code-reviewer', runtime: 'claude_code.sonnet' },
    { keeper: 'muse', runtime: 'glm-coding.glm-5.3' },
  ],
  lanes: [
    { id: 'verifier_exact', available: true, enabled: true, slots: ['glm-coding.glm-5.3-flash'], cli_slots: [], max_output_tokens: 4096 },
    { id: 'retired_exact', available: false, enabled: false, slots: [], cli_slots: [], max_output_tokens: null, thinking: null },
  ],
})

export const show = (name: string, extra: Record<string, unknown> = {}) => ({
  ok: true,
  preset: snapshot(name),
  directory: `/workspace/.masc/presets/${name}`,
  saved_settings: { status: 'differs' },
  prompt_files: [],
  default_prompts: { status: 'unknown', changes: [] },
  ...extra,
})

export const restored = (name: string, runtime: unknown = { effect: 'runtime_commit', status: 'unchanged' }) => ({
  ok: true,
  report: {
    restored: name,
    autosave: '_autosave',
    prompt_overrides: { effect: 'immediate', applied: ['keeper.worldview'], skipped: [] },
    instructions: {
      effect: 'keeper_restart',
      applied: ['code-reviewer'],
      skipped: [{ key: 'muse', reason: 'keeper TOML not found' }],
    },
    runtime,
    default_prompts: { status: 'matches', changes: [] },
    preserved_lane_settings: [],
    skipped_lanes: [],
    skipped_assignments: [{ keeper: 'muse', reason: 'runtime glm-coding.glm-5.3 is not in the capability catalog' }],
  },
})

export const committedRuntime = {
  effect: 'runtime_commit',
  status: 'committed',
  commit: {
    source_revision: 'a'.repeat(64),
    order: 'replaced',
    durability: 'unconfirmed',
    durability_detail: 'parent directory sync failed',
    warnings: [{ code: 'lock_release_unconfirmed', detail: 'flock release returned EIO' }],
    ignored_legacy_keys: [],
  },
  exact_output_registry: { status: 'unpublished', requires_restart: true },
}
