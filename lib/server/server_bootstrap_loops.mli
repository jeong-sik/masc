(** Server Bootstrap Loops — install tooling and spawn the long-running
    keeper / maintenance fibers during server startup.

    Called once from [bin/main_eio.ml] after [Mcp_server.server_state] is
    constructed.  Every entry returns either [unit] or a small
    diagnostic record; lifecycle of the spawned fibers is bound to the
    caller's [Switch].  Public surface is intentionally tiny — most of
    the work lives in private helpers in the [.ml]. *)

type keeper_persistence_report =
  { shutdown : Keeper_shutdown_runtime.restored_inventory
  ; queue : Keeper_chat_queue.configure_report
  ; requests : Keeper_msg_async.recovery_report
  }

type keeper_persistence_failure_phase =
  | Resolving_base_path
  | Restoring_shutdown
  | Configuring_queue
  | Recovering_requests
  | Starting_keeper_loops

type keeper_persistence_raised_cause =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type keeper_persistence_failure_cause =
  | Base_path_identity_unavailable_cause of keeper_persistence_raised_cause
  | Noncanonical_config_cause of
      { configured_base_path : string
      ; canonical_base_path : string
      ; configured_backend_base_path : string
      ; expected_backend_base_path : string
      }
  | Shutdown_inventory_unavailable_cause of Keeper_shutdown_store.error
  | Shutdown_admission_unavailable_cause of string
  | Unexpected_exception_cause of keeper_persistence_raised_cause
  | Lifecycle_invariant_cause of string

type keeper_persistence_failure =
  { phase : keeper_persistence_failure_phase
  ; base_path : string
  ; cause : keeper_persistence_failure_cause
  }

type keeper_persistence_prepare_error =
  | Shutdown_inventory_unavailable of Keeper_shutdown_store.error
  | Shutdown_admission_unavailable of string
  | Preparation_base_path_identity_unavailable of keeper_persistence_failure
  | Preparation_config_not_canonical of keeper_persistence_failure
  | Preparation_in_progress
  | Preparation_awaiting_claim
  | Preparation_already_claimed
  | Preparation_failed_previously of keeper_persistence_failure
  | Preparation_ownership_lost

type prepared_keeper_persistence
type claimed_keeper_persistence

type keeper_persistence_claim_error =
  | Claim_base_path_mismatch
  | Claim_base_path_identity_unavailable of keeper_persistence_failure
  | Claim_superseded
  | Claim_already_claimed
  | Claim_failed_previously of keeper_persistence_failure

type keeper_persistence_start_error =
  | Start_base_path_mismatch of
      { claimed_base_path : string
      ; state_base_path : string
      }
  | Start_base_path_identity_unavailable of keeper_persistence_failure
  | Start_superseded
  | Start_in_progress
  | Start_already_started
  | Start_execution_failed of keeper_persistence_failure
  | Start_failed_previously of keeper_persistence_failure

exception Keeper_persistence_start_failed of keeper_persistence_start_error

val prepare_keeper_persistence :
  ?requested_base_path:string ->
  config:Workspace.config ->
  unit ->
  (prepared_keeper_persistence, keeper_persistence_prepare_error) result
(** Synchronously configure/restore the durable queue, then recover keeper
    message requests against one canonical BasePath identity captured at entry.
    Direct chat checkpoints are request-local and deliberately excluded from a
    global startup inventory. Only an idle process lifecycle may prepare; ready
    state cannot be replaced by a second preparation. Per-record failures remain
    typed in the report and do not stop unrelated Keeper lanes.
    [requested_base_path] is diagnostic identity only; every persistence and
    backend operation uses the canonical [config]. *)

val keeper_persistence_report :
  prepared_keeper_persistence -> keeper_persistence_report

val keeper_persistence_prepare_error_to_string :
  keeper_persistence_prepare_error -> string

val keeper_persistence_failure_to_string : keeper_persistence_failure -> string

val claim_prepared_keeper_persistence :
  config:Workspace.config ->
  prepared_keeper_persistence ->
  (claimed_keeper_persistence, keeper_persistence_claim_error) result
(** Atomically claim the ready preparation exactly once. The current config
    path is resolved again and must identify the canonical BasePath captured by
    preparation, including across symlink retargeting. A racing or repeated
    claim returns [Claim_already_claimed]; stale tokens and retained lifecycle
    failures remain distinct typed errors. Call only after every other fallible
    pre-readiness step. *)

val keeper_persistence_claim_error_to_string :
  keeper_persistence_claim_error -> string

val keeper_persistence_start_error_to_string :
  keeper_persistence_start_error -> string

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
    shutdown cancels them in order. The claimed token is affine: start reserves
    it before spawning, rejects concurrent or repeated use, and revalidates the
    current state BasePath against the preparation's canonical identity.
    Synchronous startup failure is retained in the lifecycle and raised as
    [Keeper_persistence_start_failed]. *)

module For_testing : sig
  type keeper_loops_start_ownership

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

  val reset_keeper_persistence_lifecycle : unit -> unit

  val prepared_base_paths : prepared_keeper_persistence -> string * string

  val begin_keeper_loops_start :
    config:Workspace.config ->
    claimed_keeper_persistence ->
    (keeper_loops_start_ownership, keeper_persistence_start_error) result

  val finish_keeper_loops_start :
    keeper_loops_start_ownership ->
    (unit, keeper_persistence_start_error) result
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
