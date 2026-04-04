(** Gate_keeper_backend -- adapter between the Channel Gate and the keeper subsystem.

    This module owns the coupling to [Tool_keeper], [Agent_identity],
    and [Room].  The gate orchestrator ([Channel_gate]) calls
    {!dispatch} without knowing how keeper dispatch works internally.

    @since 2.222.0 *)

(** Result of dispatching a message to a keeper. *)
type dispatch_result =
  | Reply of { content : string; stats : Gate_protocol.turn_stats option }
  | Keeper_error of string
  | Unavailable

val dispatch :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  config:Room.config ->
  channel:string ->
  channel_user_id:string ->
  keeper_name:string ->
  content:string ->
  dispatch_result
(** Build a keeper context, call [Tool_keeper.dispatch], and parse
    the response.  The [channel] and [channel_user_id] are used to
    construct the agent name ([gate:<channel>:<user_id>]). *)
