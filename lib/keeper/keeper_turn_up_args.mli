(** Keeper_turn_up_args — parse and bundle tool arguments for keeper_up.

    Extracts all argument parsing from [handle_keeper_up] into a
    single record so that create / update branches receive
    structured data instead of 60+ local bindings. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** Parsed [keeper_up] tool arguments. Optional fields are [None] when the
    JSON arg was absent or [`Null], except [max_context_override_opt], whose
    paired [max_context_override_present] distinguishes explicit clear from
    omission on update. Non-optional fields default to [""], [[]], or the
    profile-default. *)
type parsed_args =
  { name : string
  ; compaction_profile_opt : string option
  ; runtime_id_opt : string option
  ; allowed_paths_opt : string list option
  ; autoboot_enabled_opt : bool option
  ; mention_targets_opt : string list option
  ; active_goal_ids_opt : string list option
  ; max_context_override_opt : int option
  ; max_context_override_present : bool
  ; proactive_enabled_opt : bool option
  ; compaction_ratio_gate_opt : float option
  ; compaction_message_gate_opt : int option
  ; compaction_token_gate_opt : int option
  ; compaction_cooldown_sec_opt : int option
  ; sandbox_profile_opt : string option
  ; network_mode_opt : string option
  ; instructions_arg : string option
  ; profile_defaults : keeper_profile_defaults
  ; instructions_opt : string option
  }

(** Project an [`Assoc] member at [key]; [None] for non-objects or
    missing keys. *)
(** [true] iff [key] exists in the assoc and its value is not
    [`Null]. *)
val json_non_null_member_present : string -> Yojson.Safe.t -> bool

(** Parse an optional string-list field at [key]; uses
    [normalize_name_list]. *)
val parse_present_string_list_opt :
  Yojson.Safe.t -> string -> (string list option, string) result

(** Top-level parser: project the [keeper_up] tool args JSON to a
    [parsed_args] record, or return a [tool_result] error envelope. *)
val parse :
  ?allow_sandbox_fields:bool ->
  _ context ->
  Yojson.Safe.t ->
  (parsed_args, tool_result) result

(** Resolve mention targets with dedupe + blank filter. [None] falls through to
    [fallback_targets] → [[name]]; [Some []] is an explicit clear. *)
val resolve_mention_targets :
  mention_targets_opt:string list option ->
  fallback_targets:string list ->
  name:string ->
  string list

val resolve_sandbox_profile :
  fallback:sandbox_profile option ->
  sandbox_profile

val resolve_network_mode :
  sandbox_profile:sandbox_profile ->
  fallback:network_mode option ->
  network_mode

(** Reject globs ([*?\[\]]) and traversal segments ([./..]) in
    sandbox allowed-path entries. *)
val sandbox_allowed_path_has_forbidden_segments : string -> bool

(** Validate allowed_paths without changing behavior by sandbox backend. *)
val validate_sandbox_settings :
  allowed_paths:string list ->
  (unit, string) result
