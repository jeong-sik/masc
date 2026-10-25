(** Synchronous post-readiness startup attempts. Callback return is not service
    readiness: a start may skip disabled configuration or only fork a worker.
    Transport/gateway readiness and later worker failures keep their own owners. *)

type component =
  | Ready_notification
  | Scheduler_probe
  | Full_health_refresh
  | Heap_roots
  | Owner_lanes
  | Discord_gateway
  | Slack_gateway
  | Slack_poll
  | Imessage_gateway
  | Telegram_gateway
  | Startup_banner
  | Grpc_listener
  | Grpc_client
  | Websocket_handler
  | Transport_providers
  | Execution_refresh
  | Transport_health_refresh
  | Execution_trust_refresh
  | Mission_refresh
  | Operator_snapshot_refresh
  | Operator_digest_refresh
  | Shell_prewarm

type starts =
  { ready_notification : unit -> unit
  ; scheduler_probe : unit -> unit
  ; full_health_refresh : unit -> unit
  ; heap_roots : unit -> unit
  ; owner_lanes : unit -> unit
  ; discord_gateway : unit -> unit
  ; slack_gateway : unit -> unit
  ; slack_poll : unit -> unit
  ; imessage_gateway : unit -> unit
  ; telegram_gateway : unit -> unit
  ; startup_banner : unit -> unit
  ; grpc_listener : unit -> unit
  ; grpc_client : unit -> unit
  ; websocket_handler : unit -> unit
  ; transport_providers : unit -> unit
  ; execution_refresh : unit -> unit
  ; transport_health_refresh : unit -> unit
  ; execution_trust_refresh : unit -> unit
  ; mission_refresh : unit -> unit
  ; operator_snapshot_refresh : unit -> unit
  ; operator_digest_refresh : unit -> unit
  ; shell_prewarm : unit -> unit
  }

type failure = private
  { cause : exn
  ; backtrace : Printexc.raw_backtrace
  }
(** Private diagnostic evidence for the caller; never rendered in health JSON. *)

type attempt = Not_attempted | Starting | Returned | Failed of failure | Cancelled

type t
val create : unit -> t
val global : t
(** The HTTP composition root's process-local startup attempts. *)

val component_name : component -> string
val components : starts -> component list

val run_all : t -> starts -> (component * failure) list
(** Announce a new ordered startup sequence and run its callbacks sequentially.
    Non-cancellation exceptions retain provenance and do not skip later callbacks.
    Cancellation inside a callback is recorded and re-raised unchanged; later
    callbacks remain Not_attempted. Pending cancellation is checked before each
    callback and before returning, so cancellation between callbacks starts no
    new work. An unentered callback remains Not_attempted. The caller owns one
    sequence per instance, dependency ordering,
    partial effects and child lifetimes. No callback effects are rolled back.
    Diagnostics should run after this returns so a faulty logger cannot skip starts. *)

val snapshot : t -> (component * attempt) list
val to_yojson : t -> Yojson.Safe.t
(** One immutable snapshot. Only component labels and attempt phases are public.
    The grade describes startup attempts, not underlying service availability. *)
