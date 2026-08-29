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
  ; runtime_id_opt : string option
  ; autoboot_enabled_opt : bool option
  ; mention_targets_opt : string list option
  ; max_context_override_opt : int option
  ; max_context_override_present : bool
  ; autonomous_wake_prompt_opt : string option
  ; autonomous_wake_prompt_present : bool
  ; proactive_enabled_opt : bool option
  ; sandbox_profile_opt : string option
  ; remote_endpoint_opt : string option
  ; remote_endpoint_present : bool
  ; network_mode_opt : string option
  ; skill_names_opt : string list option
  ; skill_names_present : bool
  ; native_tool_posture_opt : Runtime_native_tools.posture option
  ; native_tool_posture_present : bool
  ; instructions_arg : string option
  ; profile_defaults : keeper_profile_defaults
  ; declarative_manifest_snapshot : declarative_manifest_snapshot
  ; instructions_opt : string option
  ; autonomous_instructions_arg : string option
  ; autonomous_instructions_opt : string option
  }

(** Project an [`Assoc] member at [key]; [None] for non-objects or
    missing keys. *)
(** Parse the explicit context override. Missing is [(false, None)]; null or
    zero explicitly clears it; positive integers are preserved exactly. *)
val parse_max_context_override :
  Yojson.Safe.t -> (bool * int option, string) result

(** Parse the explicit per-keeper autonomous wake prompt. Missing is
    [(false, None)]; null explicitly clears it; a string is validated through
    the shared contract
    ([Env_config_keeper.KeeperAutonomous.validate_wake_prompt]): blank is
    rejected rather than folded into "unset", and the 2048-byte bound applies
    because the value is appended to the durable checkpoint on every
    autonomous turn. *)
val parse_autonomous_wake_prompt :
  Yojson.Safe.t -> (bool * string option, string) result

(** Top-level parser: project the [keeper_up] tool args JSON to a
    [parsed_args] record, or return a [tool_result] error envelope. *)
val parse :
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
  ?requested:string ->
  fallback:sandbox_profile option ->
  unit ->
  sandbox_profile
(** An explicit [requested] profile wins over the TOML [fallback].

    When neither source states a profile, the fallback resolves to [Local],
    which keeper-up validation (create/update) rejects unless the dev/test
    hatch [MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1] is set; config-load gating
    follows in the same fail-closed plan.  Under [Local] a fresh keeper's
    writes stay inside [.masc/playground/<keeper_name>/].

    [requested] is the caller's raw string; an unparseable one is treated as absent,
    since the gate rejects those first. *)

val resolve_network_mode :
  sandbox_profile:sandbox_profile ->
  fallback:network_mode option ->
  network_mode

(** Reject the [Local] sandbox profile while the local playground is gated off
    (fail-closed).  The hatch is [Env_config_sandbox.Gate]. *)
val validate_sandbox_profile_allowed :
  profile:sandbox_profile ->
  (unit, string) result

(** The sandbox-profile gate ([validate_sandbox_profile_allowed]). *)
val validate_sandbox_settings_with_profile :
  sandbox_profile:sandbox_profile ->
  (unit, string) result
