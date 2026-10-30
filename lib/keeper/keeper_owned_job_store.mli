(** Durable ownership of an isolated job. Every backend effect requires an
    appended intent; absent or unreadable authority never permits a relaunch.
    Strict owner journal v2 retains source/input/output/cleanup authority; it is
    not removed with private program data. *)
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

type reconciliation_hold =
  | Backend_absent
  | Backend_unconfirmed
  | Backend_mismatch
  | Cancelled_job_orphan
  | Backend_error

type reconciliation =
  | Phase_not_observed
  | Phase_confirmed
  | Phase_held of reconciliation_hold
(** Evidence from this action's reconciliation, separate from the durable phase.
    These projections are not persisted in the owner journal. *)

type input = { path : string; artifact : Tool_output.artifact_ref }
type cleanup = Keeper_owned_job_cleanup_state.t =
  | Resources_retained
  | Container_removal_requested
  | Container_removed
  | Data_removal_requested
  | Resources_removed
type paths = { job_dir : string; workspace : string; cli_config_dir : string }
type outputs =
  | Outputs_complete of Tool_output.artifact_ref * Tool_output.artifact_ref
  | Outputs_unavailable of { evidence : string }
(** [Outputs_unavailable] closes a finished job's result when the exact backend
    inventory proves the original container is absent, so its outputs can never
    be collected. [None] on the record still means "not collected yet". *)
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
  ; outputs : outputs option
  ; detail : string option
  ; completion_channel : Keeper_continuation_channel.t
  ; completion_delivered : bool
  ; cleanup : cleanup
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
(** Existing physical workspace identity shared with backend preparation and
    Composition journals. Parent aliases resolve before paths are derived;
    root-leaf symlinks, missing and unreadable roots refuse. Missing remains
    [Missing]; host I/O failure is [Io_failed]. No lexical fallback or cache. *)
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
  outputs:outputs option ->
  detail:string option -> (record, error) result
(** Cross-process compare-and-append against the entire exact previous record.
    Cleanup failure is unconfirmed, never authorization for the pending effect. *)
val phase_to_string : phase -> string
val source_to_json : source -> Yojson.Safe.t
val source_of_json : Yojson.Safe.t -> (source, error) result
val result_json : ?reconciliation:reconciliation -> record -> Yojson.Safe.t
(** Always reports [result_ready]. Without supplied reconciliation evidence the
    observation is [Phase_not_observed]. A held non-ready job reports status
    [unconfirmed] while retaining its original phase and handle; a confirmed
    terminal result retains its outcome even when a later orphan is observed. *)

val result_ready : record -> bool
(** True for a confirmed exit with complete outputs, a confirmed running or
    exited job closed with [Outputs_unavailable] evidence after exact inventory
    absence, and cancellation confirmed before start or after an absent unconfirmed launch. *)
val advance_cleanup : record -> cleanup -> (record, error) result
(** Exact full-record CAS; only adjacent cleanup states advance, after result
    readiness and canonical delivery ACK. Execution phase/source/outputs remain
    retained. Intent is durable before effects; confirmation follows them. *)
val acknowledge_completion : record -> (record, error) result
(** CAS the canonical owner only after a durable completion enqueue. *)
type pending_delivery = { job_id : Job_id.t; keeper_name : string }
type pending_deliveries =
  { entries : pending_delivery list; failures : (string * error) list }
val discover_pending_deliveries :
  base_path:string -> on_entry:(pending_delivery -> unit) ->
  (pending_deliveries, error) result
(** Read the same private pending partition, publishing each validated marker
    before reading the next. [on_entry] runs in the calling context, outside
    filesystem exception conversion; its exceptions and cancellation propagate.
    A later discovery error cannot retract earlier callbacks. The final report
    retains original entry/failure order. Each callback is only a discovery
    hint: the canonical owner must still be recovered before any effect. *)
val pending_deliveries : base_path:string -> (pending_deliveries, error) result
(** Only the pending discovery partition. Markers do not authorize any effect;
    the exact canonical job journal owns source, channel and delivery state. *)
val retire_delivery_marker : record -> (unit, error) result
(** Retire only an acknowledged owner whose resource cleanup is confirmed.
    Pending discovery survives interrupted cleanup; no historical scan is needed.
    Cleanup uncertainty cannot permit another launch or delivery. *)
val source_absent :
  base_path:string -> keeper_name:string -> source:source -> (bool, error) result
(** Prove whether every owned-job authority directory and pending completion
    marker under [base_path] is readable and none carries [(keeper_name, source)].
    Any missing, unreadable or corrupt job journal returns [Error], never [Ok true]. *)
