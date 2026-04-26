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
  (** Unique identifier for this connector (e.g. "discord", "openclaw"). *)
  val connector_id : string

  (** Human-readable name (e.g. "Discord", "OpenClaw"). *)
  val display_name : string

  (** Channel identifier used in gate message routing. *)
  val channel : string

  (** Runtime status snapshot for this connector. *)
  val status_json : ?audit_limit:int -> unit -> Yojson.Safe.t

  (** Full connector descriptor for dashboard consumption. *)
  val connector_json
    :  ?gate_status_json:Yojson.Safe.t
    -> ?audit_limit:int
    -> unit
    -> Yojson.Safe.t

  (** Create or update a channel-to-keeper binding. *)
  val bind
    :  channel_id:string
    -> keeper_name:string
    -> actor_name:string
    -> (Yojson.Safe.t, string) result

  (** Remove a channel-to-keeper binding. *)
  val unbind : channel_id:string -> actor_name:string -> (Yojson.Safe.t, string) result
end

(** {1 Registry} *)

(** Register a connector.  Replaces any existing connector with the
    same [connector_id].  Call at server startup. *)
val register : (module S) -> unit

(** [find name] returns the connector registered under [name], if any. *)
val find : string -> (module S) option

(** All registered connectors, in unspecified order. *)
val all : unit -> (module S) list

(** Aggregate descriptor for all registered connectors.
    Returns [{connectors: [...], total: N, active_count: N, generated_at: "..."}]. *)
val connectors_json
  :  ?gate_status_json:Yojson.Safe.t
  -> ?audit_limit:int
  -> unit
  -> Yojson.Safe.t
