(** Server Bootstrap Loops — install tooling and spawn the long-running
    keeper / maintenance fibers during server startup.

    Called once from [bin/main_eio.ml] after [Mcp_server.server_state] is
    constructed.  Every entry returns either [unit] or a small
    diagnostic record; lifecycle of the spawned fibers is bound to the
    caller's [Switch].  Public surface is intentionally tiny — most of
    the work lives in private helpers in the [.ml]. *)

val start_keeper_loops :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  domain_mgr:[> Eio.Domain_manager.ty ] Eio.Domain_manager.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Process.mgr ->
  Mcp_server.server_state -> unit
(** Spawn the keepalive bootstrap, supervisor sweep, and tool-execution
    fibers under [sw].  Each fiber is bound to the switch so a graceful
    shutdown cancels them in order. *)

module For_testing : sig
  type queued_chat_projection = {
    payload_channel : string;
    payload_channel_user_id : string;
    payload_channel_user_name : string;
    payload_channel_workspace_id : string;
    agent_name : string;
  }

  val autoboot_proactive_warmup_sec :
    base_warmup:int -> stagger_window_sec:int -> keeper_name:string -> int

  val board_sse_event_params : Board_dispatch.board_sse_event -> Yojson.Safe.t

  val broadcast_mention_wakeup_action :
    string option -> [ `Suppress_no_target | `Wake_keeper of string ]

  val queued_chat_projection :
    Keeper_chat_queue.queued_message -> queued_chat_projection
end

val start_background_maintenance :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Time.clock ->
  env:Eio_unix.Stdenv.base ->
  Mcp_server.server_state -> string * string
(** Spawn the periodic maintenance fibers (institution episode capping,
    cost ledger flush, dashboard cache warmer, etc.) under [sw].
    Returns a [(summary, diagnostics_hint)] pair printed at boot so an
    operator can see what schedules are active and where to look when
    one stops. *)
