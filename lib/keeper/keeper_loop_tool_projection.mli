(** Durable tool rows for a turn the keeper loop runs on its own.

    The chat lane persists the tool calls a turn made by feeding the raw
    AGENT_CORE stream into {!Keeper_stream_tool_accum} and appending the
    finalized rows once the turn settles. The autonomous lane never did: a
    continuation turn that followed an approval replay ran its tools in the
    keeper loop, and the chat surface showed only the approval's lifecycle
    rows and then nothing until the keeper's next utterance (#33127).

    This module is that same collector for the loop lane. Feed it the three
    callbacks {!Keeper_agent_run.run_turn} exposes, then {!persist} once the
    turn has a result.

    The projection is visibility, not authority: a stream whose occurrence
    mapping the collector rejects loses its rows for this turn and says so
    through {!Projection_dropped}; it never fails the turn. The chat lane
    aborts on the same rejection because there the live stream is what the
    operator is acting on. *)

type t

val create : unit -> t

val on_event : t -> Agent_core.Types.sse_event -> unit
(** One raw stream event of the turn. *)

val on_tool_stream_observation :
  t -> Keeper_hooks_agent_core.tool_stream_observation -> unit
(** An attempt boundary, a sealed turn mapping, or a sourceless close from
    the run's hooks. A rejected mapping is kept as the reason the projection
    is dropped; later observations of the same turn are still applied. *)

val on_tool_result_ready :
  t ->
  tool_call_id:string ->
  turn:int ->
  planned_index:int ->
  execution_id:Ids.Execution_id.t ->
  unit
(** The canonical execution identity of one call after its tool-log commit.
    A join the collector cannot make is kept as a drop reason. *)

type outcome =
  | Nothing_to_project  (** the turn finalized no tool call *)
  | Projected of Keeper_chat_store.append_once_result
  | Projection_dropped of string
      (** a mapping, join, or append failure; the rows of this turn are not
          in the store and the reason names why *)

val persist :
  t ->
  base_dir:string ->
  keeper_name:string ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  turn_ref:Ids.Turn_ref.t ->
  turn_failed:bool ->
  outcome
(** Append the turn's finalized tool rows once under [delivery_key]. With
    [turn_failed] the snapshot is the failure-safe one: an unsealed provider
    scope is invalidated and only sealed evidence is kept. *)
