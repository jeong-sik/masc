(** Durable ownership of an isolated job. Every backend effect requires an
    appended intent; absent or unreadable authority never permits a relaunch. *)
module Job_id = Keeper_owned_job_identity.Job_id

type source = Keeper_owned_job_identity.source =
  { task_id : string option
  ; turn_ref : Ids.Turn_ref.t option
  ; tool_use_id : string option
  ; trace_id : string option
  ; keeper_turn_id : int option
  }

type phase =
  | Prepared
  | Create_requested
  | Created of string
  | Start_requested of string
  | Running of string
  | Exited of { container_id : string; exit_code : int }
  | Cancelled_before_start of string option
  | Cancelled_unconfirmed_launch

type input = { path : string; artifact : Tool_output.artifact_ref }
type paths = { job_dir : string; workspace : string; cli_config_dir : string }
type record = private
  { job_id : Job_id.t
  ; base_path : string
  ; keeper_name : string
  ; source : source
  ; preparation : Keeper_owned_job_backend.preparation
  ; inputs : input list
  ; sequence : int
  ; phase : phase
  ; cancel_requested : bool
  ; outputs : (Tool_output.artifact_ref * Tool_output.artifact_ref) option
  ; detail : string option
  ; completion_channel : Keeper_continuation_channel.t
  ; completion_delivered : bool
  }

type error =
  | Invalid_authority of string
  | Corrupt of string
  | Missing
  | Conflict
  | Io_failed of string
  | Commit_unconfirmed of string

val error_to_string : error -> string
val canonical_base_path : string -> (string, error) result
val paths : base_path:string -> Job_id.t -> paths
val prepare_workspace : base_path:string -> Job_id.t -> input list -> (paths, error) result
(** Checksum-verified immutable artifacts copied into a new job-private workspace.
    Input names are single file components; host paths and nested mounts are absent. *)
val create :
  base_path:string -> keeper_name:string -> job_id:Job_id.t -> source:source ->
  completion_channel:Keeper_continuation_channel.t ->
  preparation:Keeper_owned_job_backend.preparation -> inputs:input list ->
  (record, error) result
val load : base_path:string -> keeper_name:string -> Job_id.t -> (record, error) result
val recover : base_path:string -> keeper_name:string -> Job_id.t -> (record, error) result
(** Existing-authority maintenance read. Under the journal's exact file lock,
    remove only an incomplete append suffix before decoding the full committed
    prefix. Complete malformed rows remain a refusal. A missing owner is never
    created. Read-only tools continue to use strict [load]. *)
val transition :
  record -> phase:phase -> cancel_requested:bool ->
  outputs:(Tool_output.artifact_ref * Tool_output.artifact_ref) option ->
  detail:string option -> (record, error) result
(** Cross-process compare-and-append against the entire exact previous record.
    Cleanup failure is unconfirmed, never authorization for the pending effect. *)
val phase_to_string : phase -> string
val source_to_json : source -> Yojson.Safe.t
val source_of_json : Yojson.Safe.t -> (source, error) result
val result_json : record -> Yojson.Safe.t

val result_ready : record -> bool
(** True only for confirmed exit with both full outputs, or before-start cancellation. *)
val acknowledge_completion : record -> (record, error) result
(** CAS the canonical owner only after a durable completion enqueue. *)
type pending_delivery = { job_id : Job_id.t; keeper_name : string }
type pending_deliveries =
  { entries : pending_delivery list; failures : (string * error) list }
val pending_deliveries : base_path:string -> (pending_deliveries, error) result
(** Only the pending discovery partition. Markers do not authorize any effect;
    the exact canonical job journal owns source, channel and delivery state. *)
val retire_delivery_marker : record -> (unit, error) result
(** Cleanup only for an acknowledged canonical owner. Cleanup uncertainty
    cannot permit another launch or delivery. *)
