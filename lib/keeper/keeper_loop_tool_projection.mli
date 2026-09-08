(** Durable tool rows for a continuation turn the keeper loop runs on its own.

    The chat lane persists the tool calls a turn made by feeding the raw
    AGENT_CORE stream into {!Keeper_stream_tool_accum} and appending the
    finalized rows once the turn settles. The autonomous lane never did: a
    continuation turn that followed an approval replay ran its tools in the
    keeper loop, and the chat surface showed only the approval's lifecycle
    rows and then nothing until the keeper's next utterance (#33127).

    This module is that same collector for the loop lane. Feed it the two
    stream callbacks {!Keeper_agent_run.run_turn} exposes, then
    {!persist_continuation} once the turn has a result.

    The rows are delivery-only: they carry the provider call id, the tool
    name and the arguments, but no canonical execution identity. Joining the
    tool-log execution id needs the run's third callback,
    [on_tool_result_ready], and handing that callback to a turn also makes the
    run's tool-log write failures fatal ({!Keeper_run_tools_setup}'s
    commit-required rule), which is the chat lane's policy and not the loop's.

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
    is dropped. A new attempt clears a rejection kept from the attempt it
    abandons: the collector quarantines that attempt's rows, so the rejection
    no longer describes anything that would be persisted. *)

type drop_reason =
  | Mapping_rejected of string
      (** the collector refused a turn mapping or a sourceless close; the
          string is the collector's own sentence *)
  | Invalid_approval_id of string
      (** the approval id is not a delivery identity; the string is the
          identity parser's sentence *)
  | Append_failed of string
      (** the chat store refused the rows; the string is its sentence *)

val drop_reason_to_string : drop_reason -> string

type outcome =
  | Nothing_to_project  (** the turn finalized no tool call *)
  | Projected of Keeper_chat_store.append_once_result
  | Projection_dropped of drop_reason
      (** the rows of this turn are not in the store, and why *)

val persist_continuation :
  t ->
  base_dir:string ->
  keeper_name:string ->
  approval_id:string ->
  turn_ref:Ids.Turn_ref.t ->
  turn_failed:bool ->
  outcome
(** Append the turn's finalized tool rows once under the delivery identity
    of the approval whose replay this turn continues. With [turn_failed] the
    snapshot is the failure-safe one: an unsealed provider scope is
    invalidated and only sealed evidence is kept. A rejected mapping is
    {!Projection_dropped} whatever the rows, since a refused seal finalizes
    nothing; otherwise a turn with no finalized tool call is
    {!Nothing_to_project} before the approval id is even read. *)
