(** Durable keeper stimulus -> reaction ledger.

    This is the runtime mirror for the KeeperReactionLiveness L1/L5
    contract: queue-visible stimuli, turn reactions, execution receipts, and
    board cursor acknowledgements are written to a replayable JSONL store under
    [.masc/keepers/<keeper>/reaction-ledger/YYYY-MM/DD.jsonl]. *)

type cursor =
  { cursor_ts : float
  ; post_id : string option
  }

type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Alive_but_stuck_recovery
  | Unknown of string

type reaction_kind =
  | Turn_started
  | Execution_receipt
  | Terminal_reason
  | Cursor_ack
  | Operator_escalation
  | Unknown_reaction of string

val stimulus_kind_to_string : stimulus_kind -> string
val reaction_kind_to_string : reaction_kind -> string

val board_stimulus_id : post_id:string -> string
(** Stable id for board-originated stimuli. *)

val stimulus_id_of_event_queue : Keeper_event_queue.stimulus -> string
(** Stable id derived from the event queue stimulus payload. *)

val record_event_queue_stimulus :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus -> unit
(** Append a [record_kind="stimulus"] row for an enqueued stimulus. *)

val record_event_queue_reaction :
  base_path:string ->
  keeper_name:string ->
  reaction_kind:reaction_kind ->
  Keeper_event_queue.stimulus ->
  unit
(** Append a [record_kind="reaction"] row tied to an event queue stimulus. *)

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

val record_execution_receipt_reaction :
  Coord.config ->
  keeper_name:string ->
  trace_id:string ->
  ?turn_count:int ->
  current_task_id:string option ->
  goal_ids:string list ->
  outcome:string ->
  terminal_reason_code:string ->
  receipt_json:Yojson.Safe.t ->
  unit ->
  unit
(** Append a reaction row that links a turn execution receipt back into the
    keeper reaction ledger. *)

val read_recent_for_keeper :
  base_path:string -> keeper_name:string -> limit:int -> Yojson.Safe.t list
(** Read the newest rows for tests and dashboards. *)
