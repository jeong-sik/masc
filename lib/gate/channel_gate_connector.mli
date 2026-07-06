(** Channel_gate_connector -- connector interface and registry.

    Defines the module type that every connector must satisfy
    and provides a name-based registry for dispatch.

    This module does not know about any specific connector (Discord,
    OpenClaw, etc.).  Concrete connectors register themselves at
    startup via {!register}.

    Relationship to other modules:
    - {!Channel_gate} handles message routing (inbound/outbound).
    - {!Channel_gate_connector} handles connector state (status/bind/unbind).
    - {!Channel_gate_metrics} tracks per-channel traffic metrics.

    @since 2.260.0 *)

(** {1 Connector Module Type} *)

module type S = sig
  val connector_id : string
  (** Unique identifier for this connector (e.g. "discord", "openclaw"). *)

  val display_name : string
  (** Human-readable name (e.g. "Discord", "OpenClaw"). *)

  val channel : string
  (** Channel identifier used in gate message routing. *)

  val status_json : ?audit_limit:int -> unit -> Yojson.Safe.t
  (** Runtime status snapshot for this connector. *)

  val connector_json :
    ?gate_status_json:Yojson.Safe.t ->
    ?audit_limit:int ->
    unit ->
    Yojson.Safe.t
  (** Full connector descriptor for dashboard consumption. *)

  val bind :
    channel_id:string ->
    keeper_name:string ->
    actor_name:string ->
    (Yojson.Safe.t, string) result
  (** Create or update a channel-to-keeper binding. *)

  val unbind :
    channel_id:string ->
    actor_name:string ->
    (Yojson.Safe.t, string) result
  (** Remove a channel-to-keeper binding. *)

  val bound_channels : keeper_name:string -> string list
  (** Channel ids currently bound to [keeper_name], freshly read from
      the connector's binding store on each call (no cached state).
      Sorted by channel id. RFC-0223 P2. *)

  val connected : unit -> bool
  (** Whether the connector's transport is currently believed live.
      Recomputed per call from the connector's own liveness source
      (status file staleness, in-process gateway state). RFC-0223 P2. *)
end

(** {1 Registry} *)

val register : (module S) -> unit
(** Register a connector.  Replaces any existing connector with the
    same [connector_id].  Call at server startup.
    Registry mutation is serialized internally. *)

val find : string -> (module S) option
(** [find name] returns the connector registered under [name], if any.
    Registry lookup is serialized internally. *)

val all : unit -> (module S) list
(** Snapshot of all registered connectors, in unspecified order. *)

val connectors_json : ?gate_status_json:Yojson.Safe.t -> ?audit_limit:int -> unit -> Yojson.Safe.t
(** Aggregate descriptor for all registered connectors.
    Returns [{connectors: [...], total: N, active_count: N, generated_at: "..."}]. *)
