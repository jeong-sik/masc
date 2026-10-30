(** Transport_bridge — Unified transport provider interface.

    Each transport (SSE, WS, gRPC) implements {!PROVIDER}
    and registers at server bootstrap. The bridge centralizes:
    - Discovery: protocol enumeration, Agent Card generation
    - Metrics: aggregate session/connection counts

    Session reaping is not centralized here: SSE reaps via
    {!Server_bootstrap_maintenance}, and the other transports clean up
    on disconnect.

    Broadcast still flows through SSE's external_subscriber
    pattern. This module does not replace that mechanism. *)

(** Contract that every transport must satisfy. *)
module type PROVIDER = sig
  val name : string
  (** Short identifier: "sse", "ws", "grpc". *)

  val protocol : Transport.protocol
  (** Which protocol enum this provider implements. *)

  val is_enabled : unit -> bool
  (** Whether this transport is currently accepting connections. *)

  val session_count : unit -> int
  (** Number of active sessions/connections right now. *)
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

val provider_by_name : string -> (module PROVIDER) option
(** Lookup a provider by its [name] field. *)

(** {1 Aggregate Operations} *)

val total_session_count : unit -> int
(** Sum of [session_count] across all enabled providers. *)

val enabled_protocols : unit -> Transport.protocol list
(** List of protocols with at least one enabled provider. *)

(** {1 Agent Card} *)

(** Transport section for A2A Agent Card / MCP discovery.
    Includes enabled protocols, endpoints, session counts. *)
val agent_card_transports_json :
  host:string -> port:int -> Yojson.Safe.t
