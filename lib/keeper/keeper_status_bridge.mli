(** Keeper status surface helpers — JSON projections for dashboard/operator.

    These functions project keeper runtime state (meta, defaults, config)
    into JSON structures consumed by the dashboard and operator control
    endpoints.

    Without this .mli, OCaml may generate an empty module interface when
    types from other modules (keeper_meta, keeper_profile_defaults) escape
    through return types. This caused phantom module issues in CI (#2894).

    @since 2.130.0
    @since 2.149.0 — .mli added to stabilize module interface *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type runtime_blocker_class = Keeper_status_bridge_blocker.runtime_blocker_class =
  | Blocked_by_heartbeat_failures
  | Blocked_by_turn_failures
  | Blocked_by_runtime_exhaustion
  | Blocked_by_provider_runtime_error
  | Blocked_by_official_client_recovery
  | Blocked_by_turn_configuration_error
  | Blocked_by_unresolved_fiber
  | Blocked_by_exception
  | Blocked_by_operator_interrupt

val runtime_blocker_class_to_string : runtime_blocker_class -> string

(** [summary] is lazy: the [turn_failures] summary reads the receipt store,
    and callers that only need [blocker_class] never force it. [signature]
    is the machine wire behind a human-sentence summary, [None] elsewhere. *)
type runtime_blocker_surface = Keeper_status_bridge_blocker.runtime_blocker_surface = {
  blocker_class : runtime_blocker_class;
  summary : string Lazy.t;
  signature : string option;
}

(** [latest_receipt] is read only for [Turn_consecutive_failures], whose
    count carries no cause; the summary then names the newest receipt's
    terminal reason when that receipt is a failed turn. *)
val runtime_blocker_surface_of_failure_reason :
  latest_receipt:(unit -> Keeper_execution_receipt.latest_receipt_reading) ->
  Keeper_registry.failure_reason -> runtime_blocker_surface option

val auto_execution_session_surface_json : unit -> Yojson.Safe.t

val workspace_surface_json : keeper_meta -> Yojson.Safe.t

val live_override_fields :
  keeper_meta -> keeper_profile_defaults -> string list

val runtime_phase :
  Workspace_utils.config -> keeper_meta -> Keeper_state_machine.phase option
(** The keeper's registry phase, [None] when it has no registry entry. *)

val runtime_keepalive_running :
  Workspace_utils.config -> keeper_meta -> bool
(** {!Keeper_status_runtime.keepalive_running_of_phase} of {!runtime_phase}. *)

val runtime_keepalive_started_at :
  Workspace_utils.config -> keeper_meta -> float option

val runtime_blocker_surface_opt :
  Workspace_utils.config -> keeper_meta -> runtime_blocker_surface option
(** The blocker the registry holds for this Keeper, read once. A reader that
    needs the class or the summary takes them from here, not back out of the
    JSON {!runtime_blocker_fields_json_of_surface} writes. *)

val runtime_blocker_fields_json_of_surface :
  keeper_meta -> runtime_blocker_surface option -> (string * Yojson.Safe.t) list
(** The status JSON fields for a blocker already read with
    {!runtime_blocker_surface_opt}. Forces [summary]. Besides the class and
    the summary the fields carry [runtime_blocker_signature]: the machine
    wire behind a summary that replaced it with a human sentence, [null]
    wherever the summary already leads with the machine wire. *)

val runtime_blocker_fields_json :
  Workspace_utils.config -> keeper_meta -> (string * Yojson.Safe.t) list
(** {!runtime_blocker_fields_json_of_surface} of {!runtime_blocker_surface_opt}. *)

type approval_queue_attention =
  | Approval_queue_ready of int
  | Approval_queue_unavailable of Keeper_approval_queue_result.storage_error

val attention_of_surface :
  Workspace_utils.config ->
  keeper_meta ->
  runtime_blocker_surface option ->
  approval_queue_attention ->
  Keeper_attention_reason.t option
(** Why an operator should look at this Keeper, or [None] when nothing asks
    for one. Takes a blocker already read with {!runtime_blocker_surface_opt},
    so a caller that also shows the blocker reads it once.
    {!attention_fields_json} carries it as [needs_attention],
    [attention_reason] and [next_human_action]. *)

val read_approval_queue_attention :
  Workspace_utils.config -> keeper_meta -> approval_queue_attention
(** The Keeper's pending approval count from the workspace queue, or why it
    could not be read. *)

val attention_fields_json_of :
  keeper_meta ->
  approval_queue_attention ->
  Keeper_attention_reason.t option ->
  (string * Yojson.Safe.t) list
(** The status JSON fields of an attention already decided, with the
    approval queue it was decided from. *)

val attention_fields_json :
  Workspace_utils.config -> keeper_meta -> (string * Yojson.Safe.t) list

val attention_fields_with_runtime_trust :
  (string * Yojson.Safe.t) list -> Yojson.Safe.t -> (string * Yojson.Safe.t) list

val runtime_surface_json :
  Workspace_utils.config -> keeper_meta -> Yojson.Safe.t

val source_provenance_json :
  Workspace_utils.config -> keeper_meta -> Yojson.Safe.t

type source_provenance =
  { overrides : Keeper_status_bridge_override.t list
  ; live_meta_path : string
  ; default_manifest_path : string option
  ; default_source_kind : string option
  ; default_config_error : Keeper_types_profile.keeper_toml_config_error option
  ; resolution : Config_dir_resolver.resolution
  }
(** Where a Keeper's config comes from and which fields its live meta
    overrides. {!source_provenance_json} renders this record. *)

val source_provenance :
  Workspace_utils.config -> keeper_meta -> source_provenance

val active_config_root : source_provenance -> string
val active_config_root_source : source_provenance -> string
