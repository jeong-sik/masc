(** Categorized 7-tab Settings codecs combining [/api/v1/tui/preferences],
    [/api/v1/config/schema?target=...], and [/api/v1/config/patch].

    Enforces secret redaction on schema decode (raw secret strings are rejected)
    and typed CAS patching ([expected_sha256], [dry_run], unified diff preview,
    [diff_hunks], [snapshot_id], [reload_scope]). *)

open Masc_tui_core

type config_target =
  | Target_runtime
  | Target_keeper of string
  | Target_keeper_create

val tui_preferences_path : string
val config_schema_path : config_target -> string
val config_patch_path : string

(** {1 TUI Preferences ([/api/v1/tui/preferences])} *)

type tui_preferences = {
  theme : string option;
  language : Say.lang option;
  board_sort : string option;
  reduce_motion : bool option;
  hints_visible : bool option;
  coalesce_queued_input : bool option;
  send_on_stop : bool option;
  audio_input_device : string option;
}

type tui_preference_change =
  | Pref_theme of string option
  | Pref_language of Say.lang
  | Pref_board_sort of string
  | Pref_chat_visited of string

val decode_tui_preferences : Yojson.Safe.t -> (tui_preferences, string) result
val encode_tui_preference_change : tui_preference_change -> Yojson.Safe.t

(** {1 Categorized 7-Tab Config Schema ([/api/v1/config/schema])} *)

type config_category =
  | Cat_general_ui
  | Cat_providers_models
  | Cat_routing_failover
  | Cat_keepers_companies
  | Cat_sandbox_ssh
  | Cat_voice_integrations
  | Cat_board_memory_candle

val category_of_settings_tab : Nav.settings_tab -> config_category
val settings_tab_of_category : config_category -> Nav.settings_tab
val config_category_of_string : string -> config_category option
val config_category_to_string : config_category -> string

type provenance =
  | Prov_default
  | Prov_global
  | Prov_project
  | Prov_keeper
  | Prov_env_override

type reload_scope =
  | Hot_reload
  | Next_turn
  | Restart_required

type secret_source =
  | Secret_env of string
  | Secret_inline_redacted
  | Secret_unset

type field_kind =
  | Field_bool
  | Field_int of { min : int option; max : int option }
  | Field_float of { min : float option; max : float option }
  | Field_string
  | Field_enum of string list
  | Field_string_list
  | Field_structured
  | Field_secret

type field_value =
  | Val_bool of bool
  | Val_int of int
  | Val_float of float
  | Val_string of string
  | Val_string_list of string list
  | Val_structured of Yojson.Safe.t
  | Val_secret of { configured : bool; source : secret_source }
  | Val_null

type schema_field = {
  table : string;
  key : string;
  full_key : string;
  label : string;
  env : string option;
  description : string option;
  kind : field_kind;
  value : field_value;
  default_value : field_value option;
  provenance : provenance;
  reload_scope : reload_scope;
  secret : bool;
  writable : bool;
}

type schema_section = {
  id : string;
  category : config_category;
  title : string;
  fields : schema_field list;
}

type config_schema = {
  target : config_target;
  keeper : string option;
  file_exists : bool;
  file_sha256 : string;
  sections : schema_section list;
}

type entity_group =
  | Group_provider of string
  | Group_model of string
  | Group_section of string
  | Group_custom of string

val entity_group_of_string : string -> entity_group
val entity_group_to_string : entity_group -> string
val equal_entity_group : entity_group -> entity_group -> bool

type field_entity_meta = {
  entity_group : entity_group option;
  entity_title : string option;
  sub_group : string option;
}

val reload_scope_of_string : string -> reload_scope option
val reload_scope_to_string : reload_scope -> string
val decode_config_schema : Yojson.Safe.t -> (config_schema, string) result
(** Strictly enforces secret redaction: any field marked [secret = true] or
    [type = "secret"] MUST carry a structured [{ kind = "secret_state"; ... }]
    object rather than a raw string value, or decoding fails with [Error]. *)

val decode_config_schema_with_meta :
  Yojson.Safe.t ->
  (config_schema * (string * field_entity_meta) list, string) result
(** Decode {!config_schema} together with server-supplied additive
    [entity_group] / [entity_title] / [sub_group] metadata keyed by [full_key]. *)

val split_dotted_segments : string -> string list
(** Quote-aware TOML dotted-key splitter: splits on unquoted ['.'] while
    preserving dots inside ["..."] or ['...'] (e.g. [models."gpt-5.6"] ->
    [["models"; "gpt-5.6"]]) and stripping outer segment quotes. *)

val field_leaf_label : lang:Say.lang -> schema_field -> string
(** Localized (KO/EN) human-readable leaf label for a Settings property row.
    Maps exact [(subtable_suffix, key)] and [key] entries from the Settings
    dictionary before falling back to a title-cased leaf key (never returns
    a raw dotted [full_key]). *)

val field_sub_group : schema_field -> string option
(** Optional sub-group identifier inside an Entity Card (e.g. ["credentials"],
    ["headers"], ["healthcheck"], ["usage-read"], ["capabilities"],
    ["model_bindings"]). *)

val sub_group_label : lang:Say.lang -> string -> string
(** Localized display title for an Entity Card sub-group divider. *)

(** {1 Atomic Config Patch ([/api/v1/config/patch])} *)

type patch_op =
  | Set_scalar of { table : string; key : string; value : string }
  | Set_int of { table : string; key : string; value : int }
  | Set_float of { table : string; key : string; value : float }
  | Set_bool of { table : string; key : string; value : bool }
  | Set_string_array of { table : string; key : string; values : string list }
  | Remove_key of { table : string; key : string }

type patch_request = {
  target : config_target;
  keeper_name : string option;
  expected_sha256 : string option;
  dry_run : bool;
  ops : patch_op list;
}

type diff_hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  header : string;
  lines : string list;
}

type patch_response = {
  applied : bool;
  dry_run : bool;
  target : string;
  changed : bool;
  before_sha256 : string;
  new_sha256 : string;
  snapshot_id : string option;
  snapshot_path : string option;
  reload_scope : reload_scope;
  unified_diff : string;
  diff_hunks : diff_hunk list;
  validation_warnings : string list;
}

val encode_patch_request : patch_request -> Yojson.Safe.t
val decode_patch_response : Yojson.Safe.t -> (patch_response, string) result
