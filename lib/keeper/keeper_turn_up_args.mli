(** Keeper_turn_up_args — parse and bundle tool arguments for keeper_up.

    Extracts all argument parsing from [handle_keeper_up] into a
    single record so that create / update branches receive
    structured data instead of 60+ local bindings. *)

open Keeper_types

(** Parsed [keeper_up] tool arguments. Every optional field is
    [None] when the JSON arg was absent or [`Null]; non-optional
    fields default to [""], [[]], or the profile-default. *)
type parsed_args =
  { name : string
  ; compaction_profile_opt : string option
  ; goal_opt : string option
  ; short_goal_opt : string option
  ; mid_goal_opt : string option
  ; long_goal_opt : string option
  ; policy_voice_enabled_opt : bool option
  ; allowed_paths_opt : string list option
  ; autoboot_enabled_opt : bool option
  ; sandbox_profile_opt : sandbox_profile option
  ; network_mode_opt : network_mode option
  ; shared_memory_scope_opt : shared_memory_scope option
  ; voice_enabled_opt : bool option
  ; voice_channel_opt : string option
  ; voice_agent_id_opt : string option
  ; mention_targets_in : string list
  ; active_goal_ids_opt : string list option
  ; max_context_override_opt : int option
  ; proactive_enabled_opt : bool option
  ; proactive_idle_sec_opt : int option
  ; proactive_cooldown_sec_opt : int option
  ; compaction_ratio_gate_opt : float option
  ; compaction_message_gate_opt : int option
  ; compaction_token_gate_opt : int option
  ; continuity_compaction_cooldown_sec_opt : int option
  ; tool_access_opt : tool_access option
  ; tool_preset_opt : tool_preset option
  ; tool_also_allow_opt : string list option
  ; tool_denylist_opt : string list option
  ; auto_handoff_opt : bool option
  ; handoff_threshold_opt : float option
  ; handoff_cooldown_sec_opt : int option
  ; instructions_arg : string option
  ; will_opt : string option
  ; needs_opt : string option
  ; desires_opt : string option
  ; profile_defaults : keeper_profile_defaults
  ; instructions_opt : string option
  }

(** Trim, drop blanks, and dedupe while preserving order. *)
val normalize_tool_name_list : string list -> string list

(** Project an [`Assoc] member at [key]; [None] for non-objects or
    missing keys. *)
val json_assoc_member_opt :
  string -> Yojson.Safe.t -> Yojson.Safe.t option

(** [true] iff [key] exists in the assoc and its value is not
    [`Null]. *)
val json_non_null_member_present : string -> Yojson.Safe.t -> bool

(** Parse an optional tool-name list field at [key]. *)
val parse_present_tool_name_list_opt :
  Yojson.Safe.t -> string -> (string list option, string) result

(** Parse an optional string-list field at [key]; uses
    [normalize_name_list]. *)
val parse_present_string_list_opt :
  Yojson.Safe.t -> string -> (string list option, string) result

(** Parse an optional enum-string field at [key], with [of_string]
    decoding and [allowed_values] surfaced in the error message. *)
val parse_enum_string_opt :
  Yojson.Safe.t ->
  string ->
  (string -> 'a option) ->
  allowed_values:string ->
  ('a option, string) result

(** Resolve a tool-name list with [preferred] taking priority over
    [fallback], then normalize. *)
val resolve_tool_name_list :
  preferred:string list option -> fallback:string list option -> string list

(** Reject legacy [tool_access.kind = "restricted" | "unrestricted"]
    payloads — the dashboard endpoint only accepts [preset] or
    [custom]. *)
val reject_legacy_tool_access_kind :
  Yojson.Safe.t -> (unit, string) result

(** Parse the [tool_access] / [tool_preset] / [tool_also_allow] /
    [tool_custom_allowlist] field cluster, enforcing mutual
    exclusivity per the dashboard contract. *)
val parse_tool_access_input :
  Yojson.Safe.t ->
  ( tool_access option * tool_preset option * string list option
  , string )
  result

(** Top-level parser: project the [keeper_up] tool args JSON to a
    [parsed_args] record, or return a [tool_result] error envelope. *)
val parse :
  _ context -> Yojson.Safe.t -> (parsed_args, tool_result) result

(** Resolve mention targets with dedupe + blank filter, falling
    through [mention_targets_in] → [fallback_targets] → [[name]]. *)
val resolve_mention_targets :
  mention_targets_in:string list ->
  fallback_targets:string list ->
  name:string ->
  string list

val resolve_sandbox_profile :
  preferred:sandbox_profile option ->
  fallback:sandbox_profile option ->
  sandbox_profile

val resolve_network_mode :
  sandbox_profile:sandbox_profile ->
  preferred:network_mode option ->
  fallback:network_mode option ->
  network_mode

val resolve_shared_memory_scope :
  preferred:shared_memory_scope option ->
  fallback:shared_memory_scope option ->
  shared_memory_scope

(** Private workspace root path (relative to project root). *)
val private_workspace_root_rel :
  sandbox_profile:sandbox_profile -> string -> string

(** Private workspace root path (absolute, normalized). *)
val private_workspace_root_abs :
  config:Coord.config ->
  sandbox_profile:sandbox_profile ->
  string ->
  string

(** Reject globs ([*?\[\]]) and traversal segments ([./..]) in
    sandbox allowed-path entries. *)
val sandbox_allowed_path_has_forbidden_segments : string -> bool

(** [true] iff [path] resolves to a location within the keeper's
    private workspace root (after normalization + traversal check). *)
val sandbox_allowed_path_within_private_root :
  config:Coord.config ->
  keeper_name:string ->
  sandbox_profile:sandbox_profile ->
  string ->
  bool

(** Validate sandbox + network + allowed_paths against
    [MASC_KEEPER_SANDBOX_HARD_MODE] policy and the
    [Local | Docker] profile constraints. Returns [Error msg] with
    a remediation hint when settings are inconsistent. *)
val validate_sandbox_settings :
  config:Coord.config ->
  keeper_name:string ->
  github_identity:'a option ->
  sandbox_profile:sandbox_profile ->
  network_mode:network_mode ->
  allowed_paths:string list ->
  (unit, string) result
