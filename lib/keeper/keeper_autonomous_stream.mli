(** Autonomous turn visibility through the same stream bridge and journal
    envelopes as operator chat. Identity is the actual durable turn reference;
    no chat operation or user-message receipt is created. *)
type t

val create : base_path:string -> keeper_name:string -> turn_ref:Ids.Turn_ref.t -> t
val current : base_path:string -> keeper_name:string -> Ids.Turn_ref.t option
(** In-flight autonomous journal, absent once its producer closes. *)
val on_event : t -> Agent_core.Types.sse_event -> unit
val on_tool_stream_observation : t -> Keeper_hooks_agent_core.tool_stream_observation -> unit
val on_tool_result_ready :
  t -> tool_call_id:string -> turn:int -> planned_index:int -> execution_id:Ids.Execution_id.t -> unit

type ending =
  | Completed of { reply : string; turn_outcome : Keeper_turn_outcome.t }
  | Failed of string
  | Cancelled

val finish : t -> ending -> unit
(** Flush held redacted text, publish the real terminal boundary, close the
    journal producer, and remove only this turn's current identity. Idempotent. *)

(** Collector-local failures only, not historical completeness evidence. *)
val child_journal_health : t -> Keeper_child_content_journal.issue list
val task_journal_health : t -> Keeper_native_task_journal.issue list
(** Persistence/cleanup issues retained independently of the root event bus.
    A closed root stream does not disable bound task observation persistence. *)
