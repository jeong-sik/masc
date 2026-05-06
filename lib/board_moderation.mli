(** Board_moderation — operator-visible moderation queue and action audit trail.

    Implements the dedicated board moderation safety contract described in
    the Phase 2/3 roadmap.  Provides:

    - A typed moderation queue: posts/comments flagged for review.
    - A moderation action audit trail: every operator decision is recorded
      with actor, timestamp, reason, and target.
    - Policy contract: defined reason codes and action kinds that callers
      must use — no free-text blobs.

    Design properties:
    - All queue and audit state is in-memory and serialised to JSONL under
      [<base_path>/.masc/board/moderation/].
    - The store is single-writer (callers must serialise operations —
      see {!Shared_audit.Store} for the same discipline).
    - No silent failures: every mutating operation returns a
      [(unit, string) result].
    - IDs are cryptographic (no prediction).

    @since Phase-2 board moderation pass *)

(** {1 Reason codes — Policy contract} *)

type flag_reason =
  | Spam
      (** Automated or repetitive content without informational value. *)
  | Harassment
      (** Content targeting a specific agent or user in a harmful manner. *)
  | Off_topic
      (** Content unrelated to the board's operational purpose. *)
  | Policy_violation of string
      (** Explicit policy string; use for site-specific rules. *)
[@@deriving show]

val flag_reason_to_string : flag_reason -> string
val flag_reason_of_string : string -> flag_reason option

(** {1 Action kinds — Operator decisions} *)

type action_kind =
  | Approve
      (** Flag was reviewed; content is acceptable.  Clears the queue entry. *)
  | Remove
      (** Content removed from the board.  Triggers {!Board_dispatch.delete_post}. *)
  | Hide
      (** Content hidden from public listing but not deleted. *)
  | Warn
      (** Author warned; content stays visible. *)
[@@deriving show]

val action_kind_to_string : action_kind -> string
val action_kind_of_string : string -> action_kind option

(** {1 Target kinds} *)

type target_kind =
  | Target_post
  | Target_comment
[@@deriving show]

val target_kind_to_string : target_kind -> string
val target_kind_of_string : string -> target_kind option

(** {1 Queue entries — pending operator review} *)

type queue_entry = {
  entry_id : string;
      (** Cryptographic random id, prefix ["mq-"]. *)
  target_kind : target_kind;
  target_id : string;
      (** Post or comment id (unvalidated string — callers supply typed ids). *)
  reporter : string;
      (** Agent id of the reporter. *)
  reason : flag_reason;
  flagged_at : float;
      (** Unix timestamp. *)
  resolved : bool;
      (** [true] once any {!action_kind} is taken by an operator. *)
}

(** {1 Audit entries — immutable action log} *)

type audit_entry = {
  audit_id : string;
      (** Cryptographic random id, prefix ["ma-"]. *)
  target_kind : target_kind;
  target_id : string;
  actor : string;
      (** Operator agent id. *)
  action : action_kind;
  reason : flag_reason option;
      (** Reason carried from the originating queue entry, if any. *)
  note : string option;
      (** Free-text note from the operator (max 500 chars; trimmed on write). *)
  acted_at : float;
}

(** {1 Store lifecycle} *)

val init : unit -> unit
(** Initialise or re-use the in-memory moderation store.  Idempotent. *)

val reset_for_test : unit -> unit
(** Drop all in-memory state.  Test-only. *)

(** {1 Queue operations} *)

val flag :
  target_kind:target_kind ->
  target_id:string ->
  reporter:string ->
  reason:flag_reason ->
  (queue_entry, string) result
(** Flag [target_id] for operator review.  Returns an error if the same
    [target_id] was already flagged and is still unresolved. *)

val get_queue : ?resolved:bool -> unit -> queue_entry list
(** Return queue entries sorted by [flagged_at] descending.
    [~resolved:false] (default) returns only pending entries;
    [~resolved:true] returns only resolved entries;
    omitting the argument returns all. *)

val resolve_entry : entry_id:string -> (unit, string) result
(** Mark a queue entry as resolved without recording an audit action.
    Prefer {!record_action} which calls this automatically. *)

(** {1 Audit trail} *)

val record_action :
  target_kind:target_kind ->
  target_id:string ->
  actor:string ->
  action:action_kind ->
  ?reason:flag_reason ->
  ?note:string ->
  unit ->
  (audit_entry, string) result
(** Record an operator moderation action.  Automatically resolves any
    open queue entry for [target_id].  The [note] is trimmed and capped
    at 500 characters. *)

val get_audit_trail :
  ?target_id:string ->
  ?actor:string ->
  ?limit:int ->
  unit ->
  audit_entry list
(** Return audit entries sorted by [acted_at] descending.
    Optional filters: [~target_id] restricts to one content item;
    [~actor] restricts to one operator. [~limit] caps the result
    (default 100, max 500). *)

(** {1 JSON serialisation — dashboard API projection} *)

val queue_entry_to_json : queue_entry -> Yojson.Safe.t
val audit_entry_to_json : audit_entry -> Yojson.Safe.t
