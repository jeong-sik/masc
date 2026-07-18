(** Durable keeper stimulus -> reaction ledger.

    This is the runtime mirror for the KeeperReactionLiveness L1/L5
    contract: queue-visible stimuli, queue settlement reactions, and board
    cursor acknowledgements are written to a replayable JSONL store under
    [.masc/keepers/<keeper>/reaction-ledger/YYYY-MM/DD.jsonl]. *)

type cursor =
  { cursor_ts : float
  ; post_id : string option
  }

type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Fusion_completed  (** RFC-0266: async masc_fusion completion wake *)
  | Bg_completed  (** RFC-0290: generic background job completion wake *)
  | Schedule_due  (** Scheduled automation due wake for a specific keeper *)
  | Connector_attention
      (** RFC-connector-ambient-attention-wake: ambient connector message wake *)
  | Hitl_resolved  (** HITL resolution delivered as an ordinary Keeper wake. *)
  | Failure_judgment
      (** RFC-0313 W2: deterministic turn-failure escalated for LLM judgment. *)
  | Manual_compaction
  | Goal_assigned
      (** RFC-0315 P3 W0: goal entered active_goal_ids — assignment edge wake. *)

type reaction_kind =
  | Turn_started
  | Event_queue_ack
  | Event_queue_requeued
  | Event_queue_escalated
  | Cursor_ack

type reaction_decode_error = Unknown_reaction_kind of string
type row_quarantine_reason

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

val board_stimulus_id : post_id:string -> string
(** Stable id for board-originated stimuli. *)

val stimulus_id_of_event_queue : Keeper_event_queue.stimulus -> string
(** Stable id derived from the event queue stimulus payload. Scheduled wakes
    preserve the enclosing schedule occurrence [post_id] exactly. *)

val record_event_queue_stimulus :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus -> unit
(** Append a [record_kind="stimulus"] row for an enqueued stimulus. *)

val record_event_queue_turn_started :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus -> unit
(** Append the sole non-settlement event-queue reaction. The writer fixes the
    reaction kind so callers cannot manufacture settlement evidence. *)

val record_event_queue_transition_reaction_result :
  base_path:string ->
  keeper_name:string ->
  source_index:int ->
  receipt:Keeper_event_queue_state.transition_receipt ->
  Keeper_event_queue.stimulus ->
  (unit, string) result
(** Append one settlement source at its exact ordered index. Persistence
    failures remain explicit [Error]. Readers use the deterministic event id
    as the logical idempotency identity. *)

type event_queue_reaction_evidence =
  { keeper_name : string
  ; stimulus_id : string
  ; stimulus_seen : bool
  ; turn_started_seen : bool
  ; event_queue_ack_seen : bool
  ; stimulus_recorded_at : float option
  ; turn_started_recorded_at : float option
  ; event_queue_ack_recorded_at : float option
  ; latest_recorded_at : float option
  ; matched_record_count : int
  ; quarantined_record_count : int
  ; unattributed_syntax_error_count : int
  ; unattributed_identity_quarantine_count : int
  }

type unattributed_syntax_error =
  { path : string
  ; line_number : int option
  ; detail : string
  }

type event_queue_reaction_evidence_outcome =
  | Evidence_complete of event_queue_reaction_evidence
  | Evidence_quarantined of
      { evidence : event_queue_reaction_evidence
      ; first_reason : row_quarantine_reason
      }
  | Evidence_incomplete of
      { evidence : event_queue_reaction_evidence
      ; first_syntax_error : unattributed_syntax_error option
      ; first_identity_quarantine_reason : row_quarantine_reason option
      ; first_matching_quarantine_reason : row_quarantine_reason option
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
    and parseable rows without a usable stimulus identity cannot be attributed
    and therefore produce {!Evidence_incomplete}; they never become negative
    evidence. Empty query identities and storage failures remain typed errors. *)

val record_board_cursor_ack :
  base_path:string ->
  keeper_name:string ->
  ?stimulus_id:string ->
  cursor_ts:float ->
  post_id:string option ->
  unit ->
  unit
(** Append a durable cursor acknowledgement. Callers should write this before
    advancing the in-memory board cursor so every cursor advance has a replayable
    ack row. *)

val summary_for_keeper :
  base_path:string -> keeper_name:string -> limit:int -> Yojson.Safe.t
(** Summarize the recent ledger rows for a keeper.  The summary is intentionally
    derived from the durable JSONL rows so an operator can see a stimulus that
    has not yet produced a turn/reaction/cursor acknowledgement. *)

val fleet_summary_json :
  base_path:string ->
  keeper_names:string list ->
  limit_per_keeper:int ->
  Yojson.Safe.t
(** Summarize recent reaction-ledger state for a bounded keeper fleet. *)

val unavailable_fleet_summary_json : unit -> Yojson.Safe.t
(** Canonical empty fleet projection used when server state is unavailable.
    Kept here so schema and field ownership remain single-source. *)
