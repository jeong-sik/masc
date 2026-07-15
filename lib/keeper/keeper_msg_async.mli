(** Keeper_msg_async — Fire-and-forget keeper message execution.

    Background fibers run [keeper_msg] turns. MCP tool returns
    immediately with a [request_id]; clients poll via
    [masc_keeper_msg_result] for completion. Process memory owns only active
    [Queued]/[Running]/[Cancelling] workers. Terminal state is removed from memory after its
    durable record moves into the terminal partition and remains queryable by
    exact request id; no hidden age-based cleanup can erase an unobserved
    result, and startup recovery does not scan historical terminal records. *)

(** {1 Types} *)

type request_status =
  | Queued
  | Running
  | Cancelling of
      { reason : string
      ; cancelled_by : string
      }
  | Lost of { reason : string }
  | Cancelled of
      { reason : string
      ; cancelled_by : string
      }
  | Persistence_failed of
      { attempted_status : string
      ; reason : string
      }
  | Done of
      { ok : bool
      ; body : string
      ; data : Yojson.Safe.t option
      }

type entry =
  { request_id : string
  ; request : Keeper_invocation_types.request
  ; base_path : string
  ; submitted_by : string
  ; status : request_status
  ; submitted_at : float
  ; completed_at : float option
  }

(** A request exists, but the supplied access identity does not own it (or
    cannot be constructed). [Caller_mismatch] intentionally does not expose
    the persisted owner value. A different base path is a different store and
    therefore yields [Absent], not an ownership oracle. *)
type access_rejection =
  | Invalid_base_path of { reason : string }
  | Invalid_caller
  | Invalid_request_id
  | Caller_mismatch

(** Outcome of looking up a request record.

    - [Found entry] — the request is known (in memory or recovered from disk).
    - [Absent] — no canonical record is observable. Pollers can stop polling,
      but absence does not prove that an earlier side effect never occurred and
      therefore does not authorize blind resubmission.
    - [Unreadable reason] — a record file exists but cannot be decoded
      (corrupt JSON, missing required fields, or unknown status). The request
      WAS accepted, but its result cannot be recovered. *)
type load_result =
  | Found of entry
  | Absent
  | Unreadable of string
  | Rejected of access_rejection

(** Opaque evidence that the exact request's canonical terminal-partition
    record is durably authoritative.  A proof is never constructed from
    {!poll}: process memory may contain a visible but unconfirmed terminal
    publication. *)
type durable_terminal_proof

type canonical_terminal_error =
  | Canonical_terminal_absent
  | Canonical_terminal_unreadable of string
  | Canonical_terminal_access_rejected of access_rejection
  | Canonical_terminal_runtime_active of request_status
      (** The exact request still has process-local nonterminal ownership. *)
  | Canonical_terminal_publication_ambiguous of request_status
      (** A terminal value is visible in process memory, but its canonical
          partition publication was not durably confirmed. *)
  | Canonical_terminal_nonterminal of request_status
  | Canonical_terminal_noncanonical_location of request_status

val canonical_terminal_error_to_string : canonical_terminal_error -> string

val durable_terminal_entry : durable_terminal_proof -> entry
(** Read-only identity/status carried by a proof.  The proof constructor stays
    private to this module. *)

type recovery_provenance =
  | Queued_before_restart
  | Running_before_restart
  | Cancelling_before_restart of
      { reason : string
      ; cancelled_by : string
      }

type recovery_candidate =
  { entry : entry
  ; provenance : recovery_provenance
  }

(** Recovery observations for canonical v6 storage only. [candidates] retain
    exact non-terminal restart provenance without mutating accepted work into
    a terminal failure. [finalized] counts
    terminal states moved from the active partition after a crash; [cleaned]
    counts duplicate active sources removed after terminal durability was
    established. Staging counters cover only the current dedicated atomic
    staging directory. *)
type recovery_report =
  { candidates : recovery_candidate list
  ; finalized : int
  ; cleaned : int
  ; staging_files_inspected : int
  ; staging_files_deleted : int
  ; staging_files_preserved : int
  ; unreadable : int
  ; failed : int
  ; store_errors : recovery_store_error list
  ; record_errors : recovery_record_error list
  }

and recovery_store =
  | Active_store
  | Atomic_staging_store

and recovery_store_error =
  { store : recovery_store
  ; path : string
  ; reason : string
  }

and recovery_record_error =
  { store : recovery_store
  ; path : string
  ; request_id : string
  ; keeper_name : string option
  ; kind : recovery_record_error_kind
  }

and recovery_record_error_kind =
  | Recovery_record_unreadable of string
  | Recovery_record_missing
  | Recovery_record_not_file
  | Recovery_record_rejected of access_rejection
  | Recovery_terminal_integrity of string
  | Recovery_candidate_invariant of string
  | Recovery_persistence_failed of string
  | Recovery_source_cleanup_failed
  | Recovery_entry_exception of string

type submit_error =
  | Submit_rejected of access_rejection
  | Initial_persistence_failed of { reason : string }
  | Acceptance_persistence_failed of
      { request_id : string
      ; reason : string
      }
  | Background_switch_unavailable of { reason : string }
  | Background_fork_failed of
      { request_id : string
      ; reason : string
      }

type submission_acceptance =
  | Durably_accepted
  | Reconciliation_required of { reason : string }

type submit_outcome =
  { request_id : string
  ; acceptance : submission_acceptance
  }

type persistence_durability =
  | Durably_committed
  | Published_unconfirmed of { reason : string }

type cancel_result =
  | Cancellation_requested of persistence_durability
  | Cancel_not_found
  | Cancel_unreadable of string
  | Cancel_rejected of access_rejection
  | Cancel_worker_ownership_unknown of request_status
  | Cancel_already_terminal of request_status
  | Cancel_persistence_failed of { reason : string }
  | Cancel_worker_signal_failed of
      { durability : persistence_durability
      ; reason : string
      }
  | Cancel_state_invariant_failed of { reason : string }

(** Reason [f] was cut off before it could reach its own completion. [f] is
    the sole owner of any terminal signal it emits on its own side channels
    (e.g. an SSE event stream) while it runs — those channels see nothing if
    [f] never returns. [worker_abort_reason] is what [on_worker_aborted]
    receives so such callers can push their own terminal signal instead of
    waiting forever on a channel [f] never got to finish. *)
type worker_cancel_source =
  | Operator_request
  | Runtime_cancellation

val worker_cancel_source_to_string : worker_cancel_source -> string
(** Stable wire label for cancellation provenance. *)

type worker_abort_reason =
  | Worker_cancelled of
      { cancelled_by : worker_cancel_source
      ; reason : string
      }

type settlement_durability =
  | Durable
  | Volatile_persistence_failure

type settlement_origin =
  | Transition_commit
  | Canonical_reconciliation

type worker_settlement =
  | Status_settlement of
      { status : request_status
      ; durability : settlement_durability
      ; origin : settlement_origin
      }
  | Settlement_projection_error of { poll_result : load_result }

(** {1 Submit and poll} *)

val server_background_switch : unit -> (Eio.Switch.t, submit_error) result
(** Resolve the server-lifetime root switch without consulting the current
    turn-local switch. Failure is typed and suitable for the same error envelope
    as [submit]. *)

(** [submit ?on_accepted ?on_worker_aborted ~background_sw ~f
    ~request ~base_path ~caller] forks a background daemon fiber on the
    explicitly supplied server-lifetime [background_sw].  The per-request
    worker switch passed to [f] is distinct: cancellation fails that switch,
    never the server root. Returns the fresh [request_id] synchronously after
    the owner-bearing v6 request record is durably accepted. If an atomic
    rename publishes the record but its directory fsync and the compensating
    rollback both fail, [Reconciliation_required] preserves the request id so
    the caller can poll instead of creating an unreachable orphan. The async
    transport has no outer wall-clock deadline: provider progress, tool-local
    deadlines, typed runtime completion, and explicit operator cancellation own
    their respective boundaries. Cancellation of the
    per-request worker switch interrupts the worker and records a terminal
    [Cancelled] state before stopping, so
    pollers do not observe an indefinite [Running] request. [Lost] is
    reserved for persisted non-terminal requests recovered without a live
    worker.

    [on_accepted] runs after the request record is durable and before a worker
    can start. It owns any producer-specific durable acceptance side effect;
    failure returns [Acceptance_persistence_failed] and no worker is forked.

    [on_worker_aborted], when supplied, is invoked exactly once whenever [f]
    is cut off by cancellation before it completes on its own —
    never when [f] returns or raises normally. It runs from a fiber
    that is not itself under cancellation at the moment of the call (wrapped
    internally in {!Eio.Cancel.protect}), so it may safely perform blocking
    Eio operations such as committing a caller-owned transcript. Callback
    errors and exceptions are converted to [Persistence_failed]; the requested
    cancellation status cannot become terminal polling truth until this
    delivery callback succeeds. Callback failures never escape to the server
    root switch.

    [on_worker_settled] is invoked with the exact accepted [request_id], only
    for terminal truth that exact in-process
    poll also returns: a durably committed status, a typed volatile persistence
    overlay, or an already-existing canonical durable terminal discovered
    during an integrity conflict. Ambiguous durable evidence has no fabricated
    callback projection. It is the single projection boundary for SSE or other
    live terminal notifications. Projection exceptions are observed and
    isolated from request truth. *)
val submit
  :  ?on_accepted:(string -> (unit, string) result)
  -> ?on_worker_aborted:(worker_abort_reason -> (unit, string) result)
  -> ?on_worker_settled:(request_id:string -> worker_settlement -> unit)
  -> background_sw:Eio.Switch.t
  -> base_path:string
  -> caller:string
  -> f:(Eio.Switch.t -> Keeper_types_profile.tool_result)
  -> request:Keeper_invocation_types.request
  -> unit
  -> (submit_outcome, submit_error) result

(** [poll ~base_path ~caller request_id] returns [Found entry] for a known request,
    [Absent] when no record exists, and [Unreadable reason] when a persisted
    record exists but cannot be decoded. [Rejected reason] means the request
    exists outside the exact canonical base-path/caller lane. A disk-only
    non-terminal record is returned unchanged: a poller cannot infer that a
    different process does not own its worker. Startup inventory preserves
    that status until an exact executor adapter claims the record. *)
val poll : base_path:string -> caller:string -> string -> load_result

(** Canonical-disk lookup for an accepted request in either partition. Unlike
    {!poll}, this never substitutes process-local state for the durable row. *)
val load_canonical_durable_entry :
  base_path:string -> caller:string -> string -> load_result

(** Exact O(1) canonical-disk lookup for a durably committed terminal request.
    It checks only the request's terminal and active filenames; it never
    inventories a partition.  Process-local nonterminal ownership and a visible
    but unconfirmed terminal publication are distinct typed failures, so neither
    can be mistaken for durable truth.  Corrupt, conflicting, nonterminal, and
    noncanonical records remain in place for lane-local recovery. *)
val load_canonical_durable_terminal :
  base_path:string ->
  caller:string ->
  string ->
  (durable_terminal_proof, canonical_terminal_error) result

(** Inventory persisted non-terminal request records that have no live
    in-memory worker. This is intended for server startup recovery. It does not
    execute, reclassify, or rewrite those records. Only the canonical active
    partition and its dedicated atomic staging directory are scanned; the
    terminal partition is excluded. Current-process workers remain protected
    by the in-memory active table; disk-only [Queued]/[Running]/[Cancelling]
    records are returned as typed candidates for the later executor boundary. *)
val recover_request_records :
  base_path:string -> unit -> recovery_report

(** [cancel ~base_path ~caller request_id] validates exact request ownership,
    durably commits a non-terminal [Cancelling] intent, publishes it, and only
    then fails the per-request worker switch. The worker's abort callback owns
    the actual [Cancelled] or [Persistence_failed] settlement. A disk-only
    non-terminal request is rejected as [Cancel_worker_ownership_unknown]:
    process-local absence cannot prove that another runtime does not own the
    worker. If switch signalling fails after [Cancelling] is published, the
    next explicit [cancel] call re-persists that same intent and retries the
    owned switch signal; there is no timer, retry count, or permanently inert
    [Cancelling] branch. Exclusive startup recovery settles true restart
    residue. *)
val cancel : base_path:string -> caller:string -> string -> cancel_result

(** [list_for_keeper ~base_path ~caller ?keeper_name ()] returns active
    [Queued]/[Running]/[Cancelling] entries owned by the exact canonical
    BasePath/caller lane, optionally filtered by target keeper, sorted most-recent-first.
    Terminal results are queried by exact request id from durable storage.
    Cross-workspace and cross-caller entries are omitted. *)
val list_for_keeper
  :  base_path:string
  -> caller:string
  -> ?keeper_name:string
  -> unit
  -> (entry list, access_rejection) result

(** {1 JSON output} *)

val status_to_string : request_status -> string
val access_rejection_to_json : access_rejection -> Yojson.Safe.t
val submit_error_to_json : submit_error -> Yojson.Safe.t
val submit_outcome_to_json : submit_outcome -> Yojson.Safe.t
val cancel_result_to_json : request_id:string -> cancel_result -> Yojson.Safe.t

(** JSON encoding with [request_id], [keeper_name], [status],
    [submitted_at], and — depending on state — [completed_at] /
    [elapsed_sec] / [ok] + [result]. *)
val entry_to_json : entry -> Yojson.Safe.t

module For_testing : sig
  type request_ops

  val make_request_ops
    :  ?before_durable_write:(Keeper_fs.durable_write_stage -> unit)
    -> ?before_durable_remove:(Keeper_fs.durable_remove_stage -> unit)
    -> ?generate_request_id:(unit -> string)
    -> ?before_integrity_projection:(unit -> unit)
    -> ?signal_cancel:(Eio.Switch.t -> exn -> unit)
    -> unit
    -> request_ops
  (** Build immutable dependencies for one test request family. They are
      supplied explicitly to [submit] and [cancel]; production entry points
      always use the closed production dependencies. *)

  val submit
    :  request_ops
    -> ?on_accepted:(string -> (unit, string) result)
    -> ?on_worker_aborted:(worker_abort_reason -> (unit, string) result)
    -> ?on_worker_settled:(request_id:string -> worker_settlement -> unit)
    -> background_sw:Eio.Switch.t
    -> base_path:string
    -> caller:string
    -> f:(Eio.Switch.t -> Keeper_types_profile.tool_result)
    -> request:Keeper_invocation_types.request
    -> unit
    -> (submit_outcome, submit_error) result

  val cancel : request_ops -> base_path:string -> caller:string -> string -> cancel_result
  val record_schema_version : int
  val is_safe_request_id : string -> bool
  val forget : base_path:string -> caller:string -> request_id:string -> unit
  val clear : unit -> unit
  val active_record_path : base_path:string -> request_id:string -> string option
  val terminal_record_path : base_path:string -> request_id:string -> string option
  val atomic_staging_dir : base_path:string -> string
  val load_record : base_path:string -> request_id:string -> load_result
  val recover_request_records :
    base_path:string -> unit -> recovery_report
  val reserved_request_id_count : unit -> int
  val active_switch_count : unit -> int
  val persistence_lane_observation : unit -> int * int * int
  val persistence_lane_samples : unit -> Otel_metrics.sample list
end
