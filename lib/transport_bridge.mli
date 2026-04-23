(** Transport_bridge — Unified transport provider interface.

    Each transport (SSE, WS, gRPC, WebRTC) implements {!PROVIDER}
    and registers at server bootstrap. The bridge centralizes:
    - Discovery: protocol enumeration, Agent Card generation
    - Lifecycle: session reaping across all transports
    - Metrics: aggregate session/connection counts

    Broadcast still flows through SSE's external_subscriber
    pattern. This module does not replace that mechanism. *)

(** Contract that every transport must satisfy. *)
module type PROVIDER = sig
  val name : string
  (** Short identifier: "sse", "ws", "grpc", "webrtc". *)

  val protocol : Transport.protocol
  (** Which protocol enum this provider implements. *)

  val is_enabled : unit -> bool
  (** Whether this transport is currently accepting connections. *)

  val session_count : unit -> int
  (** Number of active sessions/connections right now. *)

  val status_json : unit -> Yojson.Safe.t
  (** Protocol-specific status for diagnostic endpoints. *)

  val reap_stale : unit -> int
  (** Clean up dead/idle sessions. Returns number reaped. *)
end

(** {1 Provider Registry} *)

val register_provider : (module PROVIDER) -> unit
(** Register a transport provider. Replaces any existing provider
    with the same name. Called during server bootstrap.
    @raise Invalid_argument if called after {!seal}. *)

val seal : unit -> unit
(** Freeze the registry. Must be called after all providers are
    registered (end of bootstrap). Post-seal reads from multiple
    fibers are safe without synchronization. *)

val providers : unit -> (module PROVIDER) list
(** All registered providers, in registration order. *)

val provider_by_name : string -> (module PROVIDER) option
(** Lookup a provider by its [name] field. *)

(** {1 Aggregate Operations} *)

val total_session_count : unit -> int
(** Sum of [session_count] across all enabled providers. *)

val status_all_json : unit -> Yojson.Safe.t
(** Assoc of provider name -> status_json for all providers. *)

val reap_all_stale : unit -> int
(** Reap stale sessions across all providers. Returns total reaped. *)

val enabled_protocols : unit -> Transport.protocol list
(** List of protocols with at least one enabled provider. *)

(** {1 Agent Card} *)

val agent_card_transports_json : host:string -> port:int -> Yojson.Safe.t
(** Transport section for A2A Agent Card / MCP discovery.
    Includes enabled protocols, endpoints, session counts. *)
