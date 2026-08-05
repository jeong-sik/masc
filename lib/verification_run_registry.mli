(** Completion-authority review registry — in-progress + recent verdict
    visibility (RFC-0361 D4).

    [Completion_authority_agent] calls {!register_running} when it starts
    reviewing a submitted verification and {!mark_completed} on every exit path,
    so an operator surface can see which reviews are running, which ones ended,
    and why. Before this registry the only durable trace of a review was the
    single [task_completion_verdict] event on the paths that produced a verdict
    — a deferred or contract-rejected review left nothing.

    Shaped after {!Fusion_run_registry}: lock-free Atomic + CAS, optional
    append-only JSONL backing under [<base-path>/.masc/verification-runs.jsonl].

    This is an observation record, not an execution abstraction (RFC-0284 §2):
    it stores post-hoc facts and never drives, retries, or gates a review. *)

type run_status =
  | Running
  | Completed of
      { outcome : Verification_run_registry_event.outcome
      ; evaluator_runtime : string option
      ; elapsed_s : float
      }

type run =
  { verification_id : string
  ; task_id : string
  ; producer : string  (** the Keeper whose work is under review *)
  ; authority_kind : string  (** [Masc_domain.completion_authority_kind] *)
  ; authority_actor : string  (** [Masc_domain.completion_authority_actor] *)
  ; started_at : float
  ; status : run_status
  }

type t

val create : ?path:string -> unit -> t
(** A fresh, isolated registry. Production uses the process-wide {!global}
    (initialized from disk at server boot); tests use [create ()] so each case
    starts empty (no shared-state reset backdoor). *)

val replay : string -> t
(** Hydrate a registry from an append-only JSONL file. Missing files yield an
    empty registry. Unreadable files and malformed lines are logged and skipped,
    so persistence problems are visible without blocking in-memory tracking.
    Persisted registers without a completed event are dropped: the review fiber
    does not survive a restart, and [Completion_authority_agent] rescans every
    [AwaitingVerification] task at boot, so a replayed [Running] entry would name
    a review that is not happening. Replayed completed runs are pruned to the
    newest {!max_completed_retained}. *)

val register_running
  :  t
  -> verification_id:string
  -> task_id:string
  -> producer:string
  -> authority_kind:string
  -> authority_actor:string
  -> started_at:float
  -> unit
(** Record a review as [Running]. A repeated [verification_id] replaces its
    prior entry — a deferred review is retried under a fresh authority actor and
    the newest attempt is the live one. When the registry was created with a
    path, appends a [Register] event. *)

val mark_completed
  :  t
  -> verification_id:string
  -> outcome:Verification_run_registry_event.outcome
  -> ?evaluator_runtime:string
  -> elapsed_s:float
  -> unit
  -> unit
(** Transition a review to [Completed]. No-op if [verification_id] is unknown.
    Every exit path records, including rejection, deferral and raise — a review
    that spent tokens and produced nothing is exactly the one an operator needs
    to see. When the registry was created with a path, appends a [Complete]
    event. *)

val list_runs : t -> run list
(** All tracked reviews, newest [started_at] first. *)

val get : t -> verification_id:string -> run option
(** The review for [verification_id], if still tracked. *)

val status_label : run_status -> string
(** Stable wire label: [Running -> "running"], [Completed -> the outcome label]
    from {!Verification_run_registry_event.outcome_label}. One vocabulary for
    every surface. *)

val run_to_yojson : run -> Yojson.Safe.t
(** Canonical per-run JSON. The single serializer for every verification-run
    surface, so the field set never drifts between them. *)

val global : unit -> t
(** Process-wide registry the completion authority writes to (server-lifetime).
    Use {!set_global} to install a path-backed, replayed instance at boot. *)

val set_global : t -> unit
(** Install a registry as the process-wide {!global}. Called once at server boot
    after replaying the persisted JSONL. *)

val max_completed_retained : int
(** Retention bound for completed reviews (newest first). Exposed for tests. *)
