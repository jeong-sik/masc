(** Typed reaction ledger backed solely by the per-Keeper SQLite v4 store.

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

type board_scan_integrity_error =
  | Initial_scan_contains_stimuli
  | Scan_target_precedes_expected of
      { expected : cursor
      ; target : cursor
      }
  | Scan_cursor_authority_disappeared of { expected : cursor }
  | Scan_cursor_regressed of
      { expected : cursor
      ; current : cursor
      }
  | Scan_stimulus_not_board_signal of { post_id : string }
  | Scan_stimulus_cursor_mismatch of
      { scanned : cursor
      ; stimulus : cursor
      }
  | Scan_stimulus_not_after_expected of
      { expected : cursor
      ; stimulus : cursor
      }
  | Scan_stimulus_after_target of
      { target : cursor
      ; stimulus : cursor
      }
  | Scan_stimuli_not_strictly_ordered of
      { previous : cursor
      ; current : cursor
      }

type ledger_error =
  | Store_error of Keeper_reaction_store.error
  | Invalid_turn_lease_sequence of int64
  | Board_scan_integrity_error of board_scan_integrity_error
  | Event_queue_coordination_lock_error of string
  | Event_queue_stimulus_admission_error of string
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

val current_board_cursor_result :
  base_path:string -> keeper_name:string -> (cursor option, ledger_error) result
(** Read the sole durable Board cursor authority. [None] is an exact
    uninitialized Keeper, including an absent reaction database. *)

type board_scan_entry

val make_board_scan_entry :
  cursor:cursor ->
  Keeper_event_queue.stimulus ->
  (board_scan_entry, ledger_error) result
(** Bind one typed [Board_signal] stimulus to its normalized Board cursor.
    Missing or mismatched [updated_at]/post identity is an explicit integrity
    error; callers cannot construct an unchecked scan entry. *)

type board_scan_reconcile_outcome =
  | Board_scan_cursor_advanced of
      { suffix_stimulus_count : int
      ; skipped_prefix_stimulus_count : int
      }
  | Board_scan_already_reconciled

val reconcile_board_scan_result :
  base_path:string ->
  keeper_name:string ->
  expected_cursor:cursor option ->
  target_cursor:cursor ->
  board_scan_entry list ->
  (board_scan_reconcile_outcome, ledger_error) result
(** Reconcile an ordered scan produced outside the coordination lock. Under
    the lock the SQLite cursor is re-read: an unchanged cursor admits the full
    scan; an advanced cursor admits only entries strictly after it; a cursor at
    or beyond the target is an exact no-op; disappearance/regression fails
    explicitly. Queue admission still commits before the target cursor ACK.

    [expected_cursor = None] is initialization CAS and entries are forbidden:
    the caller's atomically observed Board head is installed only if the
    cursor remains uninitialized. A concurrent initializer wins without
    replaying history. Board activity admitted after that head snapshot is not
    part of initialization and remains strictly after the installed head for
    the next scan. *)

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

module For_testing : sig
  val with_after_board_stimuli_admitted_before_cursor_ack_hook :
    (unit -> unit) -> (unit -> 'a) -> 'a
  (** Deterministic crash/race barrier after the durable queue commit and
      before the SQLite cursor ACK. The previous hook is restored even when
      the test body raises. *)
end
