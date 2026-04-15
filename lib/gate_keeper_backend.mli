(** Gate_keeper_backend -- adapter between the Channel Gate and the keeper subsystem.

    This module owns the coupling to [Tool_keeper], [Agent_identity],
    and [Coord].  The gate orchestrator ([Channel_gate]) calls
    {!dispatch} without knowing how keeper dispatch works internally.

    The return type {!Gate_protocol.dispatch_result} lives in
    [Gate_protocol] so that [Channel_gate] does not need to depend
    on this module for type definitions.

    @since 2.222.0 *)

val dispatch :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  config:Coord.config ->
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_room_id:string ->
  keeper_name:string ->
  content:string ->
  Gate_protocol.dispatch_result
(** Build a keeper context, call [Tool_keeper.dispatch], and parse
    the response.  The [channel] and [channel_user_id] are used to
    construct the agent name ([gate:<channel>:<room_id>:<user_id>]).  The other
    connector fields are injected into the keeper-visible message body so
    external user identity survives memory and handoff boundaries. *)

val agent_name_for_channel_actor :
  channel:string ->
  channel_room_id:string ->
  channel_user_id:string ->
  string
(** Deterministic keeper session key for one external actor inside one
    external room/thread. *)

val contextualize_message :
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_room_id:string ->
  content:string ->
  string
(** Render a stable external-channel context envelope ahead of the raw
    user message so keeper memory can retain actor/channel metadata. *)
