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
  (** Short identifier: "sse", "ws", "grpc", "webrtc". *)
  val name : string

  (** Which protocol enum this provider implements. *)
  val protocol : Transport.protocol

  (** Whether this transport is currently accepting connections. *)
  val is_enabled : unit -> bool

  (** Number of active sessions/connections right now. *)
  val session_count : unit -> int

  (** Protocol-specific status for diagnostic endpoints. *)
  val status_json : unit -> Yojson.Safe.t

  (** Clean up dead/idle sessions. Returns number reaped. *)
  val reap_stale : unit -> int
end

(** {1 Provider Registry} *)

(** Register a transport provider. Replaces any existing provider
    with the same name. Called during server bootstrap.
    @raise Invalid_argument if called after {!seal}. *)
val register_provider : (module PROVIDER) -> unit

(** Freeze the registry. Must be called after all providers are
    registered (end of bootstrap). Post-seal reads from multiple
    fibers are safe without synchronization. *)
val seal : unit -> unit

(** All registered providers, in registration order. *)
val providers : unit -> (module PROVIDER) list

(** Lookup a provider by its [name] field. *)
val provider_by_name : string -> (module PROVIDER) option

(** {1 Aggregate Operations} *)

(** Sum of [session_count] across all enabled providers. *)
val total_session_count : unit -> int

(** Assoc of provider name -> status_json for all providers. *)
val status_all_json : unit -> Yojson.Safe.t

(** Reap stale sessions across all providers. Returns total reaped. *)
val reap_all_stale : unit -> int

(** List of protocols with at least one enabled provider. *)
val enabled_protocols : unit -> Transport.protocol list

(** {1 Agent Card} *)

(** Transport section for A2A Agent Card / MCP discovery.
    Includes enabled protocols, endpoints, session counts. *)
val agent_card_transports_json : host:string -> port:int -> Yojson.Safe.t
