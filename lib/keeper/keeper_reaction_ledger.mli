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
  | Fusion_completed  (** RFC-0266: async masc_fusion completion wake *)
  | Bg_completed  (** RFC-0290: generic background job completion wake *)
  | Schedule_due  (** Scheduled automation due wake for a specific keeper *)
  | Connector_attention
      (** RFC-connector-ambient-attention-wake: ambient connector message wake *)
  | Hitl_resolved  (** HITL resolution delivered as an ordinary Keeper wake. *)
  | Failure_judgment
      (** RFC-0313 W2: deterministic turn-failure escalated for LLM judgment. *)
  | Goal_assigned
      (** RFC-0315 P3 W0: goal entered active_goal_ids — assignment edge wake. *)

type reaction_kind =
  | Turn_started
  | Event_queue_ack
  | Event_queue_requeued
  | Event_queue_escalated
  | Execution_receipt
  | Terminal_reason
  | Cursor_ack
  | Operator_escalation
  | Supervisor_recovery_requested
  | Unknown_reaction of string

val stimulus_kind_to_string : stimulus_kind -> string
val reaction_kind_to_string : reaction_kind -> string

val stimulus_kind_of_string : string -> stimulus_kind option
(** Inverse of {!stimulus_kind_to_string}.  Strings outside the closed sum
    (schema drift / corruption) map to [None].  Summary classification parses
    through this and matches the variant exhaustively, so adding a stimulus
    variant forces the classifier to be updated (RFC-0266 regression guard). *)

val reaction_kind_of_string : string -> reaction_kind
(** Inverse of {!reaction_kind_to_string}.  Total: unknown strings map to
    [Unknown_reaction], mirroring the open [Unknown_reaction of string] escape. *)

val board_stimulus_id : post_id:string -> string
(** Stable id for board-originated stimuli. *)

val stimulus_id_of_event_queue : Keeper_event_queue.stimulus -> string
(** Stable id derived from the event queue stimulus payload. Scheduled wakes
    preserve the enclosing schedule occurrence [post_id] exactly. *)

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

val record_event_queue_transition_reaction_result :
  base_path:string ->
  keeper_name:string ->
  reaction_kind:reaction_kind ->
  receipt:Keeper_event_queue_state.transition_receipt ->
  Keeper_event_queue.stimulus ->
  (unit, string) result
(** Append the outbox-owned terminal transition with a stable event id.  A
    retry may append the same id after a crash, so readers treat [event_id] as
    the idempotency identity.  Persistence failures remain explicit [Error]. *)

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
  }

val event_queue_reaction_evidence :
  base_path:string -> keeper_name:string -> stimulus_id:string -> event_queue_reaction_evidence
(** Stream the durable reaction ledger for exact rows sharing [stimulus_id].
    This intentionally does not use a "recent rows" limit, because dashboards
    use it to prove a specific queue stimulus was observed by the keeper. *)

val event_queue_reaction_evidence_result :
  base_path:string ->
  keeper_name:string ->
  stimulus_id:string ->
  (event_queue_reaction_evidence, string) result
(** Fail-loud exact-id scan for delivery invariants. Unlike the dashboard
    projection above, malformed or unreadable ledger rows return [Error]. *)

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
  Workspace.config ->
  keeper_name:string ->
  trace_id:string ->
  ?turn_count:int ->
  current_task_id:string option ->
  goal_ids:string list ->
  outcome:string ->
  reaction_kind:reaction_kind ->
  terminal_reason_code:string ->
  receipt_json:Yojson.Safe.t ->
  unit ->
  unit
(** Append a reaction row that links a turn execution receipt back into the
    keeper reaction ledger. [reaction_kind] is a typed decision from the
    receipt owner; this persistence boundary does not reclassify wire text. *)

val read_recent_for_keeper :
  base_path:string -> keeper_name:string -> limit:int -> Yojson.Safe.t list
(** Read the newest rows for tests and dashboards. *)

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
