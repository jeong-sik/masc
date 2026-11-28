/**
 * Prompt presets as the server sends them (`Prompt_preset`, #32777).
 *
 * A preset is a named snapshot of the prompt overrides, the keeper
 * instructions and the runtime.toml routing (keeper assignments and the
 * exact-output lanes), kept under `<base>/.masc/presets/<name>/`.
 *
 * - `GET /api/v1/presets` counts what each preset holds, and names the
 *   directories it could not read.
 * - `GET /api/v1/presets/show?name=` names everything that preset would
 *   change, whether the saved settings still match the live files, and
 *   whether the default prompt bodies moved since it was saved.
 * - `POST /api/v1/presets/create` snapshots the live state under a new name;
 *   `POST /api/v1/presets` does the same and replaces a preset of that name.
 * - `POST /api/v1/presets/restore` saves the live state as `_autosave`, then
 *   applies the preset surface by surface and reports each surface.
 * - `POST /api/v1/presets/delete` removes the preset directory.
 *
 * An unknown status word fails the decode, so a new outcome is a change the
 * screen has to learn rather than one it shows as a known word.
 */

import { Schema } from '../../lib/wire-schema'

/** `Prompt_preset.autosave_name`: the preset a restore overwrites with the state it replaced. */
export const AUTOSAVE_PRESET = '_autosave'

/** `Prompt_preset.is_valid_name`: `[A-Za-z0-9._-]+`, and neither `.` nor `..`. */
export function isValidPresetName(name: string): boolean {
  return /^[A-Za-z0-9._-]+$/.test(name) && name !== '.' && name !== '..'
}

const ManifestSchema = Schema.Struct({
  name: Schema.String,
  description: Schema.String,
  created_at: Schema.String,
  override_count: Schema.Int,
  override_keys: Schema.Array(Schema.String),
  keepers: Schema.Array(Schema.String),
  assignment_count: Schema.Int,
  lane_count: Schema.Int,
})

const PresetListingSchema = Schema.Struct({
  ok: Schema.Literal(true),
  presets: Schema.Array(ManifestSchema),
  unreadable: Schema.Array(Schema.Struct({ name: Schema.String, reason: Schema.String })),
})

const LaneSettingSchema = Schema.Struct({ lane: Schema.String, setting: Schema.String })
const SkippedLaneSchema = Schema.Struct({ lane: Schema.String, reason: Schema.String })

const DefaultPromptsSchema = Schema.Union(
  Schema.Struct({ status: Schema.Literal('unknown', 'matches') }),
  Schema.Struct({
    status: Schema.Literal('differs'),
    changes: Schema.Array(Schema.Struct({
      key: Schema.String,
      saved_sha256: Schema.NullOr(Schema.String),
      current_sha256: Schema.NullOr(Schema.String),
    })),
  }),
)

const SnapshotSchema = Schema.Struct({
  name: Schema.String,
  description: Schema.String,
  created_at: Schema.String,
  preserved_lane_settings: Schema.Array(LaneSettingSchema),
  skipped_lanes: Schema.Array(SkippedLaneSchema),
  prompt_overrides: Schema.Array(Schema.Struct({
    key: Schema.String,
    value: Schema.String,
    bytes: Schema.Int,
    template_variables: Schema.Array(Schema.String),
  })),
  instructions: Schema.Array(Schema.Struct({
    keeper_file: Schema.String,
    bytes: Schema.Int,
    text: Schema.String,
  })),
  assignments: Schema.Array(Schema.Struct({ keeper: Schema.String, runtime: Schema.String })),
  lanes: Schema.Array(Schema.Struct({
    id: Schema.String,
    available: Schema.Boolean,
    enabled: Schema.Boolean,
    slots: Schema.Array(Schema.String),
    cli_slots: Schema.Array(Schema.String),
    // Absent: the preset did not record it and a restore keeps the current
    // declaration. Null: the preset removes it.
    max_output_tokens: Schema.optional(Schema.NullOr(Schema.Int)),
    thinking: Schema.optional(Schema.NullOr(Schema.Boolean)),
  })),
})

const SavedSettingsSchema = Schema.Union(
  Schema.Struct({ status: Schema.Literal('matches', 'differs') }),
  Schema.Struct({ status: Schema.Literal('unavailable'), reason: Schema.String }),
)

const PresetShowSchema = Schema.Struct({
  ok: Schema.Literal(true),
  preset: SnapshotSchema,
  directory: Schema.String,
  saved_settings: SavedSettingsSchema,
  default_prompts: DefaultPromptsSchema,
})

const PresetSavedSchema = Schema.Struct({ ok: Schema.Literal(true), preset: ManifestSchema })
const PresetDeletedSchema = Schema.Struct({ ok: Schema.Literal(true), deleted: Schema.String })

const PartResultSchema = Schema.Struct({
  applied: Schema.Array(Schema.String),
  skipped: Schema.Array(Schema.Struct({ key: Schema.String, reason: Schema.String })),
})

const CommitWarningSchema = Schema.Struct({ code: Schema.String, detail: Schema.String })

const CommitSchema = Schema.Union(
  Schema.Struct({
    durability: Schema.Literal('durable'),
    warnings: Schema.Array(CommitWarningSchema),
  }),
  Schema.Struct({
    durability: Schema.Literal('unconfirmed'),
    durability_detail: Schema.String,
    warnings: Schema.Array(CommitWarningSchema),
  }),
)

const ExactOutputRegistrySchema = Schema.Union(
  Schema.Struct({ status: Schema.Literal('applied') }),
  Schema.Struct({ status: Schema.Literal('unpublished') }),
  Schema.Struct({ status: Schema.Literal('kept'), reason: Schema.String }),
)

const RuntimeOutcomeSchema = Schema.Union(
  Schema.Struct({ status: Schema.Literal('unchanged') }),
  Schema.Struct({
    status: Schema.Literal('committed'),
    commit: CommitSchema,
    exact_output_registry: ExactOutputRegistrySchema,
  }),
  Schema.Struct({ status: Schema.Literal('failed'), error: Schema.String }),
)

const RestoreReportSchema = Schema.Struct({
  restored: Schema.String,
  autosave: Schema.String,
  prompt_overrides: PartResultSchema,
  instructions: PartResultSchema,
  runtime: RuntimeOutcomeSchema,
  default_prompts: DefaultPromptsSchema,
  preserved_lane_settings: Schema.Array(LaneSettingSchema),
  skipped_lanes: Schema.Array(SkippedLaneSchema),
  skipped_assignments: Schema.Array(Schema.Struct({ keeper: Schema.String, reason: Schema.String })),
})

const PresetRestoredSchema = Schema.Struct({ ok: Schema.Literal(true), report: RestoreReportSchema })

export type PresetManifest = Schema.Schema.Type<typeof ManifestSchema>
export type PresetListing = Schema.Schema.Type<typeof PresetListingSchema>
export type PresetSnapshot = Schema.Schema.Type<typeof SnapshotSchema>
export type PresetShow = Schema.Schema.Type<typeof PresetShowSchema>
export type DefaultPrompts = Schema.Schema.Type<typeof DefaultPromptsSchema>
export type PartResult = Schema.Schema.Type<typeof PartResultSchema>
export type RuntimeOutcome = Schema.Schema.Type<typeof RuntimeOutcomeSchema>
export type RestoreReport = Schema.Schema.Type<typeof RestoreReportSchema>
export type PresetSaved = Schema.Schema.Type<typeof PresetSavedSchema>
export type PresetDeleted = Schema.Schema.Type<typeof PresetDeletedSchema>
export type PresetRestored = Schema.Schema.Type<typeof PresetRestoredSchema>

export const decodePresetListing = Schema.decodeUnknownSync(PresetListingSchema)
export const decodePresetShow = Schema.decodeUnknownSync(PresetShowSchema)
export const decodePresetSaved = Schema.decodeUnknownSync(PresetSavedSchema)
export const decodePresetDeleted = Schema.decodeUnknownSync(PresetDeletedSchema)
export const decodePresetRestored = Schema.decodeUnknownSync(PresetRestoredSchema)
