(** Durable prepared-run ownership and exact node-result continuation.
    A worker is issued only at canonical async Queued acceptance. Rebinding
    requires the previous owner's exact canonical terminal proof; every node
    operation checks the current durable binding under the run transaction. *)

type producer =
  | Prepared
  | Named of
      { tool_name : string
      ; skill_reference : Skill_reference.t
      ; activation : Keeper_skill_activation_recorder.bound_context option
      }

type source =
  { keeper_name : string
  ; composition_run_id : Keeper_tool_plan.Composition_run_id.t
  ; draft_reference : Tool_output.artifact_ref
  ; run_reference : Tool_output.artifact_ref
  ; parent_tool_use_id : string
  ; source_turn : int
  ; source_task_id : string option
  ; producer : producer
  }

type t
type worker
type attempt
type continuation
(** Exact suspended owner captured from its canonical terminal record and
    matching journal nodes. A Lost successor additionally requires its exact
    prior result dependency wait and replay-proven read-only nodes. It grants no
    execution authority by itself. *)

type completed =
  { execution_id : Ids.Execution_id.t
  ; tool_use_id : string
  ; result : Tool_result.result
  ; result_bytes : int
  ; truncated_to : int option
  }

type recheck = { execution_id : Ids.Execution_id.t; tool_use_id : string }

type launch_invocation =
  { trace_id : string
  ; turn_ref : Ids.Turn_ref.t
  }
(** Exact invocation identity a launch leaf used when its owned-job binding was
    reserved. A replayed launch must re-call with this identity so the
    invocation binding returns the same job instead of launching a
    replacement. *)

type recheck_launch =
  { execution_id : Ids.Execution_id.t
  ; tool_use_id : string
  ; invocation : launch_invocation
  }

type replay =
  | Dispatch
  | Reuse_completed of completed
  | Recheck_result of recheck
  | Recheck_launch of recheck_launch

type error =
  | Invalid_source of string
  | Missing_journal
  | Unreadable_journal of string
  | Corrupt_journal of string
  | Source_conflict
  | Queued_request_rejected of string
  | Prior_owner_not_terminal of { request_id : string; reason : string }
  | Ownership_changed
  | Node_identity_conflict of Keeper_tool_plan.Node_id.t
  | Replay_not_proven of Keeper_tool_plan.Node_id.t
  | Attempt_conflict of Keeper_tool_plan.Node_id.t
  | Plan_identity_conflict
  | Draft_unavailable of string
  | Invalid_result of string
  | Invalid_continuation_marker of string
  | Persistence_failed of string

val error_to_string : error -> string
val error_to_json : error -> Yojson.Safe.t
val failure_class : error -> Tool_result.tool_failure_class

val prepare : base_path:string -> source -> (t, error) result
(** Create the immutable source or confirm its exact existing identity. The
    journal lives in the already-retained [keeper_msg_requests] owned tree. *)

val load
  : base_path:string
  -> keeper_name:string
  -> composition_run_id:Keeper_tool_plan.Composition_run_id.t
  -> (t, error) result
(** Strict read-only load. Missing/corrupt authority never creates a run. *)

val source : t -> source
val same_source : source -> source -> bool
(** Compare serialized immutable coordinates, including sealed recorder facts. *)

val named_binding : t -> (Keeper_composition_dependency.composition, error) result
(** Read the first admitted canonical named request. Successor workers retain
    this original public result binding. No request or membership is created. *)

val named_result_owner :
  t -> Keeper_composition_dependency.composition -> (Keeper_msg_async.entry, error) result
(** Validate the exact original named membership and every canonical predecessor,
    then read only the journal's current owner. Recheck ownership after the read.
    Waiting and active owners remain pending; no dispatch or collection occurs. *)

val validate_request : t -> Keeper_msg_async.entry -> (unit, error) result
(** Read-only proof of actual durable current/prior request ownership and every
    immutable source coordinate, including Task, invocation and both artifacts.
    A copied context cannot create membership. No worker or continuation binds. *)

val waiting_continuation : t -> (continuation option, error) result
(** Read only canonical current-owner terminal proof and exact journal state.
    [None] means no bound request, an active worker, or a settled worker that
    has no original result dependency wait. A current [Lost] owner may recover that
    wait through the journal's exact predecessor bindings and canonical
    terminal records, including repeated Lost successors. Unfinished nodes
    must prove replay: read-only nodes by the read-only replay rules, and an
    owned launch leaf by its recorded exact invocation identity, which grants
    a [Recheck_launch] replay. Cancellation and unknown effects without that
    identity do not grant continuation. Unavailable or inconsistent evidence
    is [Error]. A later owner change makes the captured value stale. A successor
    that stops before dispatch may retain its predecessor's exact wait only
    when every journal node is unchanged at the binding and the canonical
    waiting dependencies match. Original occurrence identities and owners remain
    intact. *)

val continuation_base_path : continuation -> string
(** Canonical workspace where the sealed owner and node snapshot were read.
    This path is filesystem authority, never a provider-facing identity. *)
val continuation_source : continuation -> source
val continuation_request_id : continuation -> string
val continuation_dependencies : continuation -> Keeper_composition_dependency.t list

type child_admission_history = Untouched_child | Admitted_child | Admission_unconfirmed
val continuation_child_admission : continuation ->
  node_ids:Keeper_tool_plan.Node_id.t list -> child_admission_history
(** Inspect the sealed original node evidence. Completion and producer-owned
    wait prove prior admission; an unfinished attempt cannot prove absence.
    A tool's pre-effect failure does not prove that child admission was absent. *)

val child_admission : t -> node_ids:Keeper_tool_plan.Node_id.t list ->
  (child_admission_history, error) result
(** Strict current journal history for every public resume, including completed
    runs with no result continuation. Does not bind a new worker. *)

val worker_child_admission : worker -> node_ids:Keeper_tool_plan.Node_id.t list ->
  (child_admission_history, error) result
(** Inspect current nodes under the run transaction, checking the accepted
    worker's exact durable ownership before any retained result is reused. *)

type readiness = Waiting_for_results | Results_ready
type read_composition_result =
  base_path:string -> keeper_name:string -> Keeper_composition_dependency.composition ->
  (Keeper_composition_dependency.readiness, string) result
val continuation_readiness :
  read_composition_result:read_composition_result -> continuation -> (readiness, error) result
(** Strict owner reads only. No collection, backend call, launch or Task
    inference. The read does not reserve execution or replace admission. *)

type pending_continuations =
  { inspected : int
  ; ready : continuation list
  ; waiting : int
  ; retired : int
  ; failures : (string * error) list
  }

val pending_continuations :
  read_composition_result:read_composition_result -> base_path:string -> (pending_continuations, error) result
(** Discover only per-request pending markers published before journal
    ownership and worker effects. Canonical journal/request/dependency records decide
    readiness. Completed or superseded markers retire only after exact terminal
    proof bound to the exact marker snapshot under its retained stable lock;
    unavailable, unbound or corrupt authority stays visible. Directory listing
    still includes retained lock siblings, which are excluded from [inspected];
    a lock whose marker data file was already retired is skipped by an
    existence-only check — it is never acquired or validated, so the pass
    stays proportional to live markers. No worker
    dispatch, historical terminal scan, backend operation or automatic resume. *)

module For_testing : sig
  (** The hook runs after canonical terminal proof and before the guarded
      marker retirement transaction, enabling physical replacement scenarios. *)
  val pending_continuations :
    before_retire:(string -> unit) -> read_composition_result:read_composition_result -> base_path:string ->
    (pending_continuations, error) result
end

val bind_continuation : continuation -> request_id:string -> (worker, error) result
(** Async [on_accepted] admission pinned to the captured exact owner and
    generation. A competing or completed successor makes the candidate stale;
    it cannot silently capture the successor and dispatch another worker. *)

val bind_request : t -> request_id:string -> (worker, error) result
(** Called from Async [on_accepted], before the worker starts. The canonical
    Queued record must have caller and keeper equal to [source.keeper_name],
    with exact [composition_run_id], [draft_reference], [run_artifact],
    [parent_tool_use_id], [source_turn], and optional [source_task_id] context.
    Repeated binding to the same accepted request is idempotent. *)

val validate_plan : worker -> plan:Keeper_tool_plan.t -> (unit, error) result
(** Integrity-read the original manifest and compare the exact frozen plan
    (including edges and exports), then check current durable ownership. *)

val lookup
  : worker
  -> node_id:Keeper_tool_plan.Node_id.t
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> (replay, error) result
(** Completed results are reusable. A producer-owned result wait permits
    only rechecking that exact read-only leaf, preserving its occurrence IDs.
    A proven pre-effect failure of the same canonical read-only result leaf
    also rechecks with its original IDs, even when the failure carries no wait
    marker. An owned read-only result Attempting record from a terminal
    prior worker preserves those IDs when rechecking after cancellation or
    interruption.
    An owned launch leaf ({!Keeper_tool_descriptor.Owned_job_launch_leaf})
    whose durable occurrence recorded its exact invocation identity replays
    with [Recheck_launch] after an interrupted attempt or an unknown effect
    outcome: the new owner re-calls the launch with the original occurrence
    and invocation identity, so the owned-job invocation binding returns the
    same job ([Existing]) and never launches a replacement. A launch leaf
    without recorded invocation identity keeps refusing replay.
    Other producer-proven pre-effect failures and previous statically read-only
    Attempting records may dispatch again. Other deferred and unproven effect
    outcomes reject replay. *)

val begin_attempt
  : worker
  -> node_id:Keeper_tool_plan.Node_id.t
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> execution_id:Ids.Execution_id.t
  -> tool_use_id:string
  -> readonly:bool
  -> ?launch_invocation:launch_invocation
  -> unit
  -> (attempt, error) result
(** [launch_invocation] is recorded on the durable occurrence for owned-job
    launch leaves and is required to equal the exact identity a replayed
    launch will re-call with. Only meaningful for non-read-only launch
    leaves; other nodes record [None]. *)

val settle_attempt
  : ?failure_effect_disposition:Tool_result.failure_effect_disposition
  -> ?deferred_kind:Keeper_tool_execution.deferred_kind
  -> attempt
  -> result:Tool_result.result
  -> result_bytes:int
  -> truncated_to:int option
  -> (unit, error) result
(** Settle only the exact current occurrence owned by this worker. Persist the
    complete typed result, including duration, metadata, retained artifacts and
    strict checkpoint-coded media. A committed append remains successful when
    descriptor cleanup alone fails. Cancellation propagates. *)
