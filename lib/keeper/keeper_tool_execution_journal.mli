(** Durable prepared-run ownership and exact node-result continuation.
    A worker is issued only at canonical async Queued acceptance. Rebinding
    requires the previous owner's exact canonical terminal proof; every node
    operation checks the current durable binding under the run transaction. *)

type nested_origin
type named_origin = Standalone | Nested of nested_origin

val named_origin_to_yojson : named_origin -> Yojson.Safe.t
(** Immutable producer identity. Nested origins can only be constructed from
    the actual parent attempt and its frozen child operand. Decoding an owned
    source is evidence, not permission to enter a broker. *)

type producer =
  | Prepared
  | Named of
      { tool_name : string
      ; skill_reference : Skill_reference.t
      ; activation : Keeper_skill_activation_recorder.bound_context option
      ; origin : named_origin
      }

type source =
  { keeper_name : string
  ; composition_run_id : Keeper_tool_plan.Composition_run_id.t
  ; draft_reference : Tool_output.artifact_ref
  ; run_reference : Tool_output.artifact_ref
  ; parent_tool_use_id : string
  ; source_turn : int
    (** Original SDK invocation ordinal. The named producer's sealed physical
        Keeper TurnRef is a separate coordinate and remains in [activation]. *)
  ; source_task_id : string option
  ; producer : producer
  }

type source_observation = {
  trace_id : Keeper_id.Trace_id.t option;
  session_id : string option;
  keeper_turn_id : int option;
  answer_source_ids : string list;
}
(** Observation captured by the original producer, independently of execution
    authority. Missing coordinates remain unknown and grant no replay right. *)

type t
type worker
type attempt
type child_submission
type continuation
(** Exact suspended owner captured from its canonical terminal record and
    matching node and child snapshots. A Lost successor requires replay proof;
    an original accepted-child acknowledgement can be ready before the first
    result wait. This snapshot grants no execution authority by itself. *)

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
  ; keeper_turn_id : int option
  }
(** Exact invocation identity a launch leaf used when its owned-job binding was
    reserved. A replayed launch must re-call with this identity so the
    invocation binding returns the same job instead of launching a
    replacement. [keeper_turn_id] preserves the original source snapshot's
    optional K coordinate; it is not reconstructed from the resuming turn. *)

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
  | Recheck_child_submission of recheck

type error =
  | Invalid_source of string
  | Missing_journal
  | Unreadable_journal of string
  | Corrupt_journal of string
      (** Journal updates are in-place durable appends with an ftruncate
          rollback, not atomic temp-file renames: a crash mid-append can
          leave a torn tail that decodes as corrupt. A corrupt journal is
          therefore not in itself proof of a permanent failure: when
          continuation intake meets one it holds original authority and
          reports failure without settling the run, so the file can be
          repaired out-of-band and explicitly resumed. *)
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

val prepare : ?observation:source_observation -> base_path:string -> source -> (t, error) result
(** Create the immutable source or confirm its exact existing identity. The
    journal lives in the already-retained [keeper_msg_requests] owned tree.
    Only new creation can capture [observation], in the same durable write.
    Existing journals retain their first observation or its absence; replay
    cannot populate or replace it with current input. *)

val load
  : base_path:string
  -> keeper_name:string
  -> composition_run_id:Keeper_tool_plan.Composition_run_id.t
  -> (t, error) result
(** Strict read-only load. Missing/corrupt authority never creates a run. *)

type resolution_decision = Reject | Cancel
type resolution
(** A logical terminal decision, separate from the immutable physical worker
    outcome. Original source, node results, child links and artifacts remain. *)

type resolution_observation
type resolution_report =
  { resolution : resolution; marker_retired : bool; retirement_error : error option }

val resolution_to_json : resolution -> Yojson.Safe.t
val resolution_observation_to_json : resolution_observation -> Yojson.Safe.t
val resolution_report_to_json : resolution_report -> Yojson.Safe.t

type request_observation
val observe_request
  : base_path:string -> composition_run_id:Keeper_tool_plan.Composition_run_id.t
  -> Keeper_msg_async.entry -> (request_observation, error) result
(** Read the logical run independently of the requested physical attempt.
    Strict original source and admitted current/prior membership are required.
    Dependency/artifact readiness grants no authority here. The physical record
    is checked again before return; a changed record is an unavailable reading. *)
val request_observation_to_json : request_observation -> Yojson.Safe.t
val request_observation_resolution : request_observation -> resolution option
val same_request_observation : request_observation -> request_observation -> bool
(** Compare original request, workspace and exact journal version; observation
    time is not authority. This does not authorize execution or delivery. *)

val observe_resolution
  : base_path:string -> keeper_name:string
  -> composition_run_id:Keeper_tool_plan.Composition_run_id.t -> request_id:string
  -> (resolution_observation, error) result
(** Strict journal/source and canonical waiting/lost owner observation. Includes
    an opaque version of the exact journal, physical terminal and pending marker.
    Dependency/artifact readiness is not required and grants no execution right. *)

val resolve_continuation
  : base_path:string -> keeper_name:string
  -> composition_run_id:Keeper_tool_plan.Composition_run_id.t -> request_id:string
  -> expected_version:string -> decision:resolution_decision
  -> requested_by:string -> reason:string -> now:float
  -> (resolution_report, error) result
(** Compare the observed version and original owner under the run transaction,
    append the terminal decision durably, then retire only its exact marker.
    All future bindings and node mutations refuse the resolved journal. Same
    command retries retain the first timestamp and may retry marker retirement;
    changed owner/version/decision/actor/reason is refused. Cleanup failure is
    returned alongside the committed decision, never as a rollback claim. *)

val observe_named_result
  : base_path:string -> keeper_name:string -> Keeper_composition_dependency.composition
  -> ((t * Keeper_msg_async.entry * resolution option), error) result
(** A resolved child is ready for a typed failure read. Strict original named
    membership, journal identity and canonical physical owner remain required;
    unavailable dependency/artifact authority cannot turn resolution into exports. *)

val source : t -> source
val source_observation : t -> source_observation option
(** Original producer metadata, if captured. Does not reread current Keeper,
    Task, answer, or turn context and does not authorize execution. *)
val worker_source : worker -> source
val worker_source_observation : worker -> source_observation option
(** The worker's same frozen source and observation. Neither getter authorizes
    node dispatch. *)

val same_source : source -> source -> bool
(** Compare serialized immutable coordinates, including sealed recorder facts. *)

val source_to_yojson : source -> Yojson.Safe.t
val source_of_yojson : Yojson.Safe.t -> (source, error) result
(** The strict immutable source codec, shared by producer-owned submission
    intents. Decoding grants neither admission nor execution authority. *)

val validate_source_plan : t -> plan:Keeper_tool_plan.t -> (unit, error) result
(** Read the original owned draft and compare its exact bound plan. No worker
    is required or reserved; unavailable artifacts remain an error. *)

val named_admission : t ->
  (Keeper_composition_dependency.composition option, error) result
(** [None] proves only that this exact journal has no admitted request yet.
    It does not prove absence of an attempted broker submission. *)

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
    has no original result dependency wait, accepted-child recovery, or recorded
    launch recovery. A current [Lost] owner may recover that wait through the journal's exact predecessor bindings and canonical
    terminal records, including repeated Lost successors. Unfinished nodes
    must prove replay: read-only nodes follow their read-only replay rules,
    and owned launch leaves retain their recorded exact invocation identity
    through [Recheck_launch]. Cancellation and other unknown effects do not
    grant continuation. Unavailable or inconsistent evidence is [Error]. A later
    owner change makes the captured value stale. A successor that stops before
    dispatch may retain its predecessor's exact wait only when every journal
    node is unchanged at the binding and the canonical waiting dependencies match.
    Original occurrence identities and owners remain intact. A [Lost] owner
    with committed original child acceptance can recover that acknowledgement
    with its original occurrence IDs and an empty dependency list; a Nested
    child may similarly resume replay-proven work only through its parent's
    committed original acceptance. A first Lost owned launch with its complete
    recorded invocation can similarly resume Existing-only observation, with
    no invented prior result wait.
    Other unfinished effectful attempts or unproven outcomes still return
    [Replay_not_proven]. Such a run
    cannot become fresh work through the [None] fallback, and discovery keeps
    its pending marker without scheduling a replacement. *)

val continuation_base_path : continuation -> string
(** Canonical workspace where the sealed owner and node snapshot were read.
    This path is filesystem authority, never a provider-facing identity. *)
val continuation_source : continuation -> source
val continuation_request_id : continuation -> string
val continuation_dependencies : continuation -> Keeper_composition_dependency.t list

type result_notification =
  { base_path : string
  ; keeper_name : string
  ; dependency : Keeper_composition_dependency.t
  }
(** Original canonical workspace, Keeper and typed result identity. This is
    only a discovery hint, never evidence of readiness or effect permission. *)

type completion_disposition =
  | Canonical_completion
  | Recovery_pending
  | Unadmitted_attempt

type completion_observation
(** Immutable source/state captured by the original completion-disposition
    read, not admission authority or a cached result. Keep only for that
    delivery attempt; later consumers still read their original authority. *)

val observe_completion :
  base_path:string -> Keeper_msg_async.entry -> (completion_observation, error) result
val completion_observation_disposition : completion_observation -> completion_disposition
val completion_result_notification :
  completion_observation -> (result_notification option, error) result
(** After durable result delivery, derive the original first admitted Named
    result binding from this observation and its canonical original request.
    Successors never substitute their physical request ID. Prepared runs,
    recovery-pending/unadmitted attempts or requests without a journal source
    return [Ok None]. Errors do not change already committed delivery; callers
    retain/log them and let complete maintenance revalidate independently.
    This read is a hint projection, not proof that a dependent may run. *)

val completion_disposition :
  base_path:string -> Keeper_msg_async.entry -> (completion_disposition, error) result
(** Requests carrying draft/run references must prove their immutable source and
    actual current/prior journal membership before any logical completion.
    [Unadmitted_attempt] is an exact-source request whose acceptance never bound
    this run, including a losing continuation CAS. It has no logical terminal to
    announce. Missing, corrupt or inconsistent authority remains [Error].
    [Recovery_pending] also suppresses a recoverable Lost physical attempt.
    Named requests without either journal artifact field retain their canonical
    terminal semantics; a partial journal envelope never falls back to that boundary. *)

val completion_pending : base_path:string -> Keeper_msg_async.entry -> (bool, error) result
(** Common outward guard: true for [Recovery_pending] or [Unadmitted_attempt].
    It applies to every status, including Done and Persistence_failed. *)

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

type discovery_scope = All_pending | Result_notifications of result_notification list
(** Maintenance reads all result dependencies. A notification pass still checks
    every marker and its original journal/terminal authority, but reads result
    readiness only for continuations depending on a matching original result.
    A recoverable Lost continuation with no result dependencies is conservatively
    included. Unselected result dependencies are not probed; maintenance remains
    the complete recovery/error-discovery path. Notification keys are indexed
    only within this pass, deduplicating exact immutable coordinates/dependencies;
    index order never replaces marker order. No durable reverse index or cache. *)

type pending_continuations =
  { inspected : int
      (** Ready + waiting + unselected + retired + failures. Successful
          lock-infrastructure inspections are excluded; each failed directory
          entry inspection is counted. *)
  ; ready : continuation list
  ; waiting : int
  ; unselected : int
  ; retired : int
  ; failures : (string * error) list
  }

val discover_pending_continuations :
  scope:discovery_scope -> on_ready:(continuation -> unit) -> read_composition_result:read_composition_result ->
  base_path:string -> (pending_continuations, error) result
(** Publish each originally validated ready candidate before inspecting later
    pending names. [on_ready] runs in the calling context after the original
    journal/terminal/dependency reads, outside filesystem exception conversion
    and marker transactions. Its exceptions and cancellation propagate; later
    discovery failures cannot retract earlier callbacks. The final report
    records observations in original order, not callback admission or execution
    outcomes. Every intake must still validate the captured original authority.
    Directory acquisition and exact terminal-bound retirement remain unchanged.
    [unselected] counts canonical waiting continuations outside the requested
    result scope, not proven waiting results or missing/failed work. Matching
    requires the original canonical workspace, Keeper and entire typed dependency.
    Selected continuations still re-read all their dependencies and validate the
    original owner; a notification never grants permission to use a result. *)

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

val validate_refusal_completion : worker -> plan:Keeper_tool_plan.t -> (unit, error) result
(** Before a refusal successor finishes, reread exact original artifacts,
    producer/child authorities and worker ownership. No new replay authority. *)

val child_origin : attempt -> plan:Keeper_tool_plan.t ->
  activation:Keeper_skill_activation_ledger.activation ->
  (named_origin * Keeper_tool_plan.t, error) result
(** Verify the exact native submission operand and its original canonical
    Nested activation, retaining the parent occurrence independently of the
    logical child Skill invocation ID. Return the child plan bound from this
    opaque attempt's validated original input. No activation or broker effect. *)

val record_child_submission : attempt -> plan:Keeper_tool_plan.t ->
  child_source:source -> (child_submission, error) result
(** Persist the immutable original attempt-to-child source join before broker
    entry. A changed or copied source cannot replace the original intent. *)

val accept_child_submission : child_submission -> request_id:string -> (unit, error) result
(** Last producer acceptance effect: validate real canonical Queued membership
    and child journal ownership before retaining its binding in the parent.
    Does not settle the parent node or claim the child's final result. *)

val child_result_binding : attempt -> plan:Keeper_tool_plan.t ->
  (Keeper_composition_dependency.composition, error) result
(** Read only the exact accepted child associated with this native result
    barrier. Empty model input cannot supply a different child binding. *)

val accepted_child_submission : child_submission ->
  (Keeper_composition_dependency.composition, error) result
(** Recheck the original parent acceptance and its canonical child source.
    Does not repair missing acceptance or admit a request. *)

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

val launch_recheck
  : worker
  -> node_id:Keeper_tool_plan.Node_id.t
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> execution_id:Ids.Execution_id.t
  -> tool_use_id:string
  -> (recheck_launch option, error) result
(** Under the canonical run lock, require the current worker and exact launch
    occurrence IDs, then apply the existing replay authority to its recorded
    actual input. [Some] means the same original launch still needs observation;
    [None] includes a producer-proven pre-effect refusal or completed result.
    Missing/unreadable/stale authority is [Error], never fresh admission.
    An Existing-only attempt keeps this authority through a later pre-effect
    refusal; initial pre-effect failures retain their ordinary retry contract. *)

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
