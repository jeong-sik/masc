(** Server Bootstrap Loops — install tooling and spawn the long-running
    keeper / maintenance fibers during server startup.

    Called once from [bin/main_eio.ml] after [Mcp_server.server_state] is
    constructed.  Every entry returns either [unit] or a small
    diagnostic record; lifecycle of the spawned fibers is bound to the
    caller's [Switch].  Public surface is intentionally tiny — most of
    the work lives in private helpers in the [.ml]. *)

val install_tooling :
  governance_level:string ->
  Mcp_server.server_state ->
  unit
(** Register the keeper / governance / cost tools with [server_state]
    according to [governance_level] (e.g. ["restricted"], ["full"]).
    Idempotent; safe to call once per server instance. *)

type keeper_persistence_report =
  { shutdown : Keeper_shutdown_runtime.restored_inventory
  ; delivery : Keeper_chat_delivery_journal.recovery_report
  ; queue : Keeper_chat_queue.configure_report
  ; requests : Keeper_msg_async.recovery_report
  ; blocked_keeper_names : string list
  }

type keeper_persistence_prepare_error =
  | Shutdown_inventory_unavailable of Keeper_shutdown_store.error
  | Shutdown_admission_unavailable of string
  | Delivery_inventory_unavailable of Keeper_chat_delivery_journal.error list
  | Queue_inventory_unavailable of Keeper_chat_queue.snapshot_load_error list
  | Request_inventory_unavailable of Keeper_msg_async.recovery_store_error list
  | Preparation_superseded

type prepared_keeper_persistence
type claimed_keeper_persistence

type keeper_persistence_claim_error =
  | Claim_base_path_mismatch
  | Claim_superseded
  | Claim_already_claimed
  | Claim_admission_install_failed of Keeper_persistence_admission.install_error

val prepare_keeper_persistence :
  config:Workspace.config ->
  (prepared_keeper_persistence, keeper_persistence_prepare_error) result
(** Synchronously reconcile delivery journals, configure/restore the durable
    queue, then recover keeper message requests. Call this before publishing
    request routes. Per-record failures remain typed in the report and do not
    stop unrelated Keeper lanes. *)

val keeper_persistence_report :
  prepared_keeper_persistence -> keeper_persistence_report

val keeper_persistence_prepare_error_to_string :
  keeper_persistence_prepare_error -> string

val claim_prepared_keeper_persistence :
  config:Workspace.config ->
  prepared_keeper_persistence ->
  (claimed_keeper_persistence, keeper_persistence_claim_error) result
(** Atomically claim the latest successful preparation exactly once. Call this
    before publishing HTTP readiness; a stale, mismatched, or repeated claim
    remains a typed startup error, as does failure to establish the fence's
    canonical BasePath identity. *)

val keeper_persistence_claim_error_to_string :
  keeper_persistence_claim_error -> string

val start_keeper_loops :
  claimed_persistence:claimed_keeper_persistence ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  domain_mgr:[> Eio.Domain_manager.ty ] Eio.Domain_manager.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Process.mgr ->
  Mcp_server.server_state -> unit
(** Spawn the keepalive bootstrap, supervisor sweep, and tool-execution
    fibers under [sw].  Each fiber is bound to the switch so a graceful
    shutdown cancels them in order. The opaque preparation token makes queue
    consumption impossible to start through this API before durable recovery. *)

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
