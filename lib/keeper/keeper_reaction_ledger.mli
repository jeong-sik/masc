(** Durable keeper stimulus -> reaction ledger.

    Queue-visible stimuli and queue transition reactions are
    written to a replayable JSONL store under
    [.masc/keepers/<keeper>/reaction-ledger/<generation>/YYYY-MM/DD.jsonl].
    The generation namespace is a hard boundary: older stores are neither read
    nor written by this module. Ask {!store_dir} for the path rather than
    spelling the generation out. *)

type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Fusion_completed  (** RFC-0266: async masc_fusion completion wake *)
  | Schedule_due  (** Scheduled automation due wake for a specific keeper *)
  | Connector_attention
      (** RFC-connector-ambient-attention-wake: ambient connector message wake *)
  | Hitl_resolved
  | Ask_answered  (** HITL resolution delivered as an ordinary Keeper wake. *)
  | Completion_authority_rejected
      (** System completion authority rejected Keeper evidence. *)
  | Task_cancelled
      (** Another Keeper cancelled a Task this Keeper authored. *)
  | Workspace_message
  | Delegate_completed
  | Composition_completed
      (** A committed workspace message named this Keeper. *)

type reaction_kind =
  | Turn_started
  | Turn_finished
      (** The turn the stimulus opened reached its boundary. Carries the turn's
          own typed disposition as a token; this ledger records what the turn
          boundary decided and never decides it. *)
  | Event_queue_ack
  | Event_queue_cancelled

type reaction_decode_error = Unknown_reaction_kind of string
type row_quarantine_reason

val install_state_change_observer : (unit -> unit) -> unit
(** Install the process-wide non-yielding observer invoked after a direct
    stimulus or turn-start row append succeeds. Observer failures are logged
    and never change the already persisted ledger result. Transition-outbox
    reactions are followed by event-queue retirement persistence, whose own
    observer supplies the ordered full-health invalidation. *)

val digest_id : string -> string -> string
(** [digest_id prefix payload] is the durable event id: [prefix], a colon, and
    the SHA-256 of [payload] in full hex. Readers recompute and compare it, so
    a collision is a replay decision rather than a display artefact. *)

val schema : string
(** The schema string current rows carry. Readers reject any other value, so
    a test that spells the generation out is asserting against a literal the
    writer can move without it. *)

val store_dir : masc_root:string -> keeper_name:string -> string
(** Where rows are written and read, generation included. A reader that
    rebuilds this path itself keeps looking at the old namespace after a
    generation bump and sees an empty store rather than an error. *)

val stimulus_kind_to_string : stimulus_kind -> string
val reaction_kind_to_string : reaction_kind -> string
val row_quarantine_reason_to_string : row_quarantine_reason -> string

val stimulus_kind_of_string : string -> stimulus_kind option
(** Inverse of {!stimulus_kind_to_string}.  Strings outside the closed sum
    (schema drift / corruption) map to [None].  Summary classification parses
    through this and matches the variant exhaustively, so adding a stimulus
    variant forces the classifier to be updated (RFC-0266 regression guard). *)

val reaction_kind_of_string : string -> (reaction_kind, reaction_decode_error) result
(** Closed inverse of {!reaction_kind_to_string}. Strings outside the current
    reaction algebra return a typed decoder error and can never become a
    current reaction. *)

val stimulus_id_of_event_queue : Keeper_event_queue.stimulus -> string
(** Stable id derived from the event queue stimulus payload. Scheduled wakes
    preserve the enclosing schedule occurrence [post_id] exactly. *)

val record_event_queue_stimulus :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus -> unit
(** Append a [record_kind="stimulus"] row for an enqueued stimulus. *)

val record_event_queue_turn_started :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus -> unit
(** Append a turn-entry reaction. The writer fixes the reaction kind so callers
    cannot manufacture transition evidence. *)

val record_event_queue_turn_finished :
  base_path:string ->
  keeper_name:string ->
  disposition:string ->
  Keeper_event_queue.stimulus ->
  unit
(** Append the closing half of {!record_event_queue_turn_started}. Without it a
    stimulus's evidence ends at "a turn started", and what the turn did is
    recovered by comparing that timestamp against the keeper's calls -- a
    reconstruction rather than a record. [disposition] is the turn boundary's
    own outcome; this writer does not classify. *)

val project_event_queue_transition_outbox_result :
  base_path:string ->
  keeper_name:string ->
  expected_transition_id:string ->
  (unit, string) result
(** Read the sole durable event-queue transition outbox, append every source in
    exact order, then retire that same transition. [expected_transition_id]
    binds the outbox read to the transfer whose target the recovery caller
    already projected; a newer transition remains authoritative. Callers
    supply no receipt, stimulus, source index, or outbox record, so transition
    evidence can only originate from the event-queue SSOT. Persistence failures
    remain explicit [Error]. Retries are logically idempotent through
    deterministic per-source event ids. *)

type event_queue_reaction_evidence =
  { keeper_name : string
  ; stimulus_id : string
  ; stimulus_seen : bool
  ; turn_started_seen : bool
  ; turn_finished_seen : bool
  ; event_queue_ack_seen : bool
  ; event_queue_cancelled_seen : bool
  ; stimulus_recorded_at : float option
  ; turn_started_recorded_at : float option
  ; turn_finished_recorded_at : float option
  ; event_queue_ack_recorded_at : float option
  ; event_queue_cancelled_recorded_at : float option
  ; latest_recorded_at : float option
  ; matched_record_count : int
  ; quarantined_record_count : int
  }

type event_queue_reaction_evidence_outcome =
  | Evidence_complete of event_queue_reaction_evidence
  | Evidence_quarantined of
      { evidence : event_queue_reaction_evidence
      ; first_reason : row_quarantine_reason
      }

type event_queue_reaction_evidence_error =
  | Evidence_invalid_stimulus_id
  | Evidence_read_error of Dated_jsonl.read_error

val event_queue_reaction_evidence_error_to_string :
  event_queue_reaction_evidence_error -> string

val event_queue_reaction_evidence_result :
  base_path:string ->
  keeper_name:string ->
  stimulus_id:string ->
  (event_queue_reaction_evidence_outcome, event_queue_reaction_evidence_error) result
(** Exact-id delivery scan over the complete keeper-local ledger. Matching
    semantic-invalid rows produce {!Evidence_quarantined}. Syntax-invalid rows
    and parseable rows without the queried identity remain visible through the
    operator summary, but cannot be attributed to this occurrence and therefore
    do not become its negative evidence. Exact ACK and accepted-cancellation
    terminals remain distinct typed evidence. Empty query identities and
    storage failures remain typed errors. *)

val event_queue_reaction_evidence_batch_result :
  base_path:string ->
  keeper_name:string ->
  stimulus_ids:string list ->
  ( (string * event_queue_reaction_evidence_outcome) list
  , event_queue_reaction_evidence_error )
  result
(** Build exact evidence for every requested stimulus identity from the
    keeper-local ledger. Duplicate identities are collapsed while preserving
    first-request order. This is the request-level projection seam for bounded
    dashboards: rendering N rows for one Keeper performs one ledger read, not
    N. An empty identity rejects the whole batch with
    {!Evidence_invalid_stimulus_id}; an empty query list returns [Ok []].

    The read is incremental. A day file is append-only, so the accumulators
    and the per-file cursors are kept between calls and only what the ledger
    gained is folded in. A stimulus identity asked about for the first time
    cannot be answered from a partial read, so it restarts every tracked
    accumulator from a complete read - the same full scan as before, once per
    identity rather than once per call. A file shorter than its cursor was
    rotated or rewritten, and the whole Keeper's answer is rebuilt from a
    complete read rather than kept.

    What is kept is one accumulator per identity the caller has asked about,
    never the ledger and never every identity in it. A read failure drops that
    Keeper's cache and returns {!Evidence_read_error}. *)

val event_queue_turn_started_seen_for_source_result :
  base_path:string ->
  keeper_name:string ->
  post_id:string ->
  stimulus_kind:stimulus_kind ->
  (bool, event_queue_reaction_evidence_error) result
(** Return [true] only when a current-schema, semantically valid turn-start
    reaction exists for the exact durable source identity. Invalid matching
    rows do not become positive evidence; read failures remain explicit so
    callers can conservatively replay. *)

val event_queue_delivery_seen_for_source_result :
  base_path:string ->
  keeper_name:string ->
  post_id:string ->
  stimulus_kind:stimulus_kind ->
  (bool, event_queue_reaction_evidence_error) result
(** Return [true] when the exact durable source has either started a turn or
    reached an accepted queue terminal (ACK, transfer, or cancellation).
    This is the restart fence for one-shot delivery producers: a terminally
    cancelled or transferred source must not be recreated on startup. Invalid
    matching rows do not become positive evidence; read failures remain
    explicit so callers can conservatively replay. *)

val summary_for_keeper :
  base_path:string -> keeper_name:string -> limit:int -> Yojson.Safe.t
(** Summarize the recent ledger rows for a keeper.  The summary is intentionally
    derived from the durable JSONL rows so an operator can see a stimulus that
    has not yet produced a turn or terminal reaction. *)

val fleet_summary_json :
  base_path:string ->
  keeper_names:string list ->
  limit_per_keeper:int ->
  Yojson.Safe.t
(** Summarize recent reaction-ledger state for a bounded keeper fleet. *)

val fleet_summary_status_strings : string list
(** Every value the fleet summary's ["status"] field can carry. A reader that
    has to enumerate them was previously reading four from a type and a fifth
    from a string literal elsewhere in the same file (#27560). *)

val unavailable_fleet_summary_json : unit -> Yojson.Safe.t
(** Canonical empty fleet projection used when server state is unavailable.
    Kept here so schema and field ownership remain single-source. *)

module For_testing : sig
  val with_after_ledger_append :
    after_ledger_append:(unit -> (unit, string) result) ->
    (unit -> 'a) ->
    'a
  (** Scoped post-append fault seam. The callback must invoke the canonical
      recovery projector; this seam cannot read or retire an outbox itself.

      This declaration is part of the projection boundary contract that
      [scripts/keeper_event_queue_projection_boundary_check.ml] enforces: the
      seam must exist exactly once as a definition and once as a declaration,
      so the fault path cannot acquire a second entry point. No test calls it,
      which is why an unused-declaration sweep read it as dead. *)
end
