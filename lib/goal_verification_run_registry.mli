(** Durable observation registry for standalone Goal-verifier reviews. The
    Goal ledger remains completion authority; this registry records what the
    independent reviewer did, including lookup tool calls, without becoming a
    second lifecycle store. *)

type review_kind = Proof

type evaluated_verdict = Approved of { reason : string } | Rejected of { reason : string }

val evaluated_verdict_of_yojson : Yojson.Safe.t -> (evaluated_verdict option, string) result

type outcome =
  | Reviewed
  | Committed
  | Superseded of { detail : string }
  | Deferred of { detail : string }
  | Raised of { detail : string }
  | Review_cancelled of { detail : string }
      (** The review fiber was cancelled mid-flight; without this a cancelled
          goal review left no completion and vanished on replay (W6). *)

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; evaluated_verdict : evaluated_verdict option
      ; evaluator_runtime : string option
      ; elapsed_s : float
      ; tools : Verification_run_registry.tool_observation list
      }

type run =
  { run_id : string
  ; goal_id : string
  ; request_id : string
  ; criterion : Goal_store.criterion
  ; review_kind : review_kind
  ; authority_actor : string
  ; started_at : float
  ; status : run_status
  }

(** One retained row (RFC-0444 §2.3 row 7). A [Scan_skipped] row is a
    verifier scan the goal store refused: it reviewed nothing, so it is its
    own arm rather than a [run] with blank identity, and it carries the whole
    typed value the scan saw. Every stored event and every served row names
    its arm in [kind] ([review] or [scan_skipped]); a row without it does not
    decode. *)
type row =
  | Review of run
  | Scan_skipped of
      { run_id : string
      ; started_at : float
      ; unavailable : Goal_store.unavailable
      }

type t

val storage_filename : string
val create : ?path:string -> unit -> t
val replay : string -> t

val register_running :
  t ->
  run_id:string ->
  goal_id:string ->
  request_id:string ->
  criterion:Goal_store.criterion ->
  review_kind:review_kind ->
  authority_actor:string ->
  started_at:float ->
  unit

val mark_completed :
  t ->
  run_id:string ->
  outcome:outcome ->
  evaluated_verdict:evaluated_verdict option ->
  tools:Verification_run_registry.tool_observation list ->
  ?evaluator_runtime:string ->
  elapsed_s:float ->
  unit ->
  unit

val record_scan_skipped :
  t ->
  run_id:string ->
  started_at:float ->
  unavailable:Goal_store.unavailable ->
  unit
(** Append one terminal {!Scan_skipped} row: registered and completed under
    the registry's own mutation lock, so it survives replay. Retention is per
    row kind, so skipped scans never evict retained reviews. *)

val list_runs : t -> row list
val get : t -> run_id:string -> row option
val status_label : run_status -> string

val run_to_yojson : run -> Yojson.Safe.t
(** A review row with [kind:"review"]. *)

val row_to_yojson : row -> Yojson.Safe.t
(** {!run_to_yojson} for a review; a skipped scan is
    [{kind:"scan_skipped", run_id, started_at, reason, field, file, mirror,
    reset_step}] — the goal_store_unavailable envelope's own members
    ({!Goal_unavailable_envelope.fields}). *)

val change_observer_fn : (unit -> unit) Atomic.t

type global_install_error = Already_installed

val global : unit -> t
val install_global : t -> (unit, global_install_error) result
val max_completed_retained : int

val cut_replay_log : execute:bool -> string -> Run_registry_core.cut_report
(** Deployment-time store cut for {!storage_filename}. See
    {!Run_registry_core.Make.cut_replay_log}. *)

val validate_event_json : Yojson.Safe.t -> (unit, string) result
(** Validate one stored event without replay, compaction or writes. *)
