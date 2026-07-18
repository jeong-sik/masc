(** Typed reaction ledger backed solely by the per-Keeper SQLite v3 store.

    Retired file-based generations are outside the current authority. *)

type cursor =
  { cursor_ts : float
  ; post_id : string option
  }

type stimulus_kind = Keeper_reaction_store.stimulus_kind =
  | Board_signal
  | Bootstrap
  | Fusion_completed
  | Bg_completed
  | Schedule_due
  | Connector_attention
  | Hitl_resolved
  | Failure_judgment
  | Manual_compaction
  | Goal_assigned

type reaction_kind = Keeper_reaction_store.reaction_kind =
  | Turn_started
  | Event_queue_ack
  | Event_queue_requeued
  | Event_queue_escalated
  | Cursor_ack

type reaction_decode_error = Unknown_reaction_kind of string

type write_outcome = Keeper_reaction_store.write_outcome =
  | Inserted
  | Already_recorded

type ledger_error =
  | Store_error of Keeper_reaction_store.error
  | Invalid_turn_lease_sequence of int64
  | Event_queue_outbox_read_error of string
  | Event_queue_outbox_invariant of { observed_count : int }
  | Event_queue_outbox_retire_error of string

val stimulus_kind_to_string : stimulus_kind -> string
val stimulus_kind_of_string : string -> stimulus_kind option
val reaction_kind_to_string : reaction_kind -> string
val reaction_kind_of_string : string -> (reaction_kind, reaction_decode_error) result
val ledger_error_to_string : ledger_error -> string

val stimulus_id_of_event_queue : Keeper_event_queue.stimulus -> string

val record_event_queue_stimulus_result :
  base_path:string ->
  keeper_name:string ->
  Keeper_event_queue.stimulus ->
  (write_outcome, ledger_error) result

val record_event_queue_turn_started_result :
  base_path:string ->
  keeper_name:string ->
  lease_sequence:int64 ->
  Keeper_event_queue.stimulus ->
  (write_outcome, ledger_error) result
(** Records one admitted processing attempt. The durable queue lease sequence,
    rather than wall-clock time, gives retries distinct causal identities. *)

val record_event_queue_turn_admission_result :
  base_path:string ->
  keeper_name:string ->
  lease_sequence:int64 ->
  Keeper_event_queue.stimulus list ->
  (unit, ledger_error) result
(** Atomically records every exact stimulus root and turn-start child for one
    claimed lease. The list order is the causal order within the block. *)

val project_event_queue_transition_outbox_result :
  base_path:string -> keeper_name:string -> (unit, ledger_error) result
(** Reads the exact durable outbox entry, atomically stores its transition
    header and complete ordered source set, then retires that entry. *)

val record_board_cursor_ack_result :
  base_path:string ->
  keeper_name:string ->
  cursor_ts:float ->
  post_id:string option ->
  unit ->
  (write_outcome, ledger_error) result

type event_queue_latest_reaction =
  | Latest_turn_started of
      { sequence : int64
      ; event_id : string
      ; recorded_at : float
      }
  | Latest_event_queue_ack of
      { sequence : int64
      ; event_id : string
      ; recorded_at : float
      ; transition_id : string
      ; source_index : int
      ; source_count : int
      }
  | Latest_event_queue_requeued of
      { sequence : int64
      ; event_id : string
      ; recorded_at : float
      ; transition_id : string
      ; source_index : int
      ; source_count : int
      }
  | Latest_event_queue_escalated of
      { sequence : int64
      ; event_id : string
      ; recorded_at : float
      ; transition_id : string
      ; source_index : int
      ; source_count : int
      ; external_input_requested : bool
      }
(** The causally latest event-queue reaction for one stimulus.  [sequence] is
    the SQLite ledger order; wall-clock timestamps do not decide precedence. *)

type event_queue_reaction_evidence =
  { keeper_name : string
  ; stimulus_id : string
  ; stimulus_seen : bool
  ; turn_started_seen : bool
  ; event_queue_ack_seen : bool
  ; stimulus_recorded_at : float option
  ; turn_started_recorded_at : float option
  ; event_queue_ack_recorded_at : float option
  ; latest_reaction : event_queue_latest_reaction option
  ; latest_recorded_at : float option
  ; matched_record_count : int
  }

type event_queue_reaction_evidence_error =
  | Evidence_invalid_stimulus_id
  | Evidence_store_error of Keeper_reaction_store.error

val event_queue_reaction_evidence_error_to_string :
  event_queue_reaction_evidence_error -> string

val event_queue_reaction_evidence_batch_result :
  base_path:string ->
  keeper_name:string ->
  stimulus_ids:string list ->
  ((string * event_queue_reaction_evidence) list, event_queue_reaction_evidence_error) result
(** One indexed read transaction per Keeper.  A successful empty match is the
    only negative evidence; storage/schema failures remain typed errors. *)

val event_queue_reaction_evidence_result :
  base_path:string ->
  keeper_name:string ->
  stimulus_id:string ->
  (event_queue_reaction_evidence, event_queue_reaction_evidence_error) result

val summary_for_keeper :
  base_path:string ->
  keeper_name:string ->
  pending_id_display_limit:int ->
  Yojson.Safe.t

type keeper_name_discovery =
  | Keeper_names_discovered of string list
  | Keeper_name_discovery_failed of string
(** Typed outcome of the configured Keeper authority lookup. A failed lookup
    must never be represented as an empty configured fleet. *)

val fleet_summary_json :
  base_path:string ->
  keeper_name_discovery:keeper_name_discovery ->
  pending_id_display_limit_per_keeper:int ->
  Yojson.Safe.t

val unavailable_fleet_summary_json : unit -> Yojson.Safe.t
