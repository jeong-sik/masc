(** Common tool projection for autonomous approval continuations.
    The actual turn owns its tool rows and an internal ordered binding of the
    canonical approval inputs prepared for it. The binding proves preparation,
    not provider acceptance, checkpoint admission or effect permission.

    Stream mapping and append failures remain optional observations: they
    produce [Projection_dropped] without changing the principal turn result.
    Runtime attempt boundaries quarantine abandoned tool rows; the prepared
    input association stays frozen across those attempts. *)

type t

val create : unit -> t

val bind_prepared_inputs :
  t -> turn_ref:Ids.Turn_ref.t -> Keeper_gate_replay.model_message -> unit
(** Capture the actual preparer's canonical approval input vector and turn
    owner. Repeated runtime attempts keep the same association. A changed or
    invalid vector is an observation failure, never execution authority. *)

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
  | Input_binding_unavailable of string
      (** the actual prepared input or turn association cannot be proved *)
  | Append_failed of string
      (** the chat store refused the rows; the string is its sentence *)

val drop_reason_to_string : drop_reason -> string

type outcome =
  | Nothing_to_project  (** neither prepared input nor finalized tool calls *)
  | Projected of Keeper_chat_store.append_once_result
  | Projection_dropped of drop_reason
      (** the rows of this turn are not in the store, and why *)

type protocol_error =
  Keeper_chat_events.stream_protocol_error_kind
  * Keeper_chat_events.tool_stream_occurrence
  * string
(** A stream event the collector quarantined: its typed conflict, the
    occurrence it hit, and the collector's own sentence. The quarantined row
    is not among the persisted ones. *)

type persisted =
  { outcome : outcome
  ; committed_ownerships : (Keeper_chat_delivery_identity.delivery_key * Keeper_chat_store.tool_ownership) list
  ; quarantined : protocol_error list
        (** drained from the collector at persist time; the chat lane's live
            bridge reports the same conflicts as they happen, the loop lane
            has no bridge, so they are handed back here for the caller to
            say. Empty on a clean stream. *)
  }

val persist_continuation :
  t ->
  base_dir:string ->
  keeper_name:string ->
  turn_ref:Ids.Turn_ref.t ->
  turn_failed:bool ->
  persisted
(** Append the turn's prepared input binding and finalized common tool rows
    once under the actual [Autonomous_turn] identity. With [turn_failed] the
    snapshot is the failure-safe one: an unsealed provider scope is
    invalidated and only sealed evidence is kept. A rejected mapping is
    {!Projection_dropped} whatever the rows, since a refused seal finalizes
    nothing. A clean prepared turn without tools still records its internal input
    binding. The provided owner must equal the preparer's actual turn ref.
    A different input vector conflicts before any append. Common tools are
    neither copied under each approval nor assigned to a representative.
    Projection failures preserve the principal result and existing rows. *)
