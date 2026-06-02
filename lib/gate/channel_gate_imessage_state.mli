(** Channel_gate_imessage_state — iMessage connector state.

    Implements the {!Channel_gate_connector.S} module signature so it
    can be registered at server startup via
    [Channel_gate_connector.register (module Channel_gate_imessage_state)].

    Every internal helper (path resolvers, audit log,
    binding-store IO, JSON lookups, state classifiers) is hidden —
    only the {!Channel_gate_connector.S} surface is public. The same
    narrow strategy applied to {!Channel_gate_discord_state} so the
    two connectors stay structurally interchangeable. *)

(** {1 Connector identity} *)

val connector_id : string
(** ["imessage"]. *)

val display_name : string
(** ["iMessage"]. *)

val channel : string
(** ["imessage"]. *)

(** {1 Connector status} *)

val status_json : ?audit_limit:int -> unit -> Yojson.Safe.t
(** Runtime status snapshot — bindings, recent audit events,
    staleness flag, and connector liveness. [audit_limit] caps the
    audit-history slice (default [10]). *)

val connector_json :
  ?gate_status_json:Yojson.Safe.t ->
  ?audit_limit:int ->
  unit ->
  Yojson.Safe.t
(** Full connector descriptor for the dashboard, layering
    [gate_status_json] (if provided) on top of {!status_json}. *)

(** {1 Binding lifecycle} *)

val bind :
  channel_id:string ->
  keeper_name:string ->
  actor_name:string ->
  (Yojson.Safe.t, string) result
(** Create or update a channel→keeper binding, append an audit
    event, and return the resulting binding row as JSON. *)

val unbind :
  channel_id:string ->
  actor_name:string ->
  (Yojson.Safe.t, string) result
(** Remove a channel→keeper binding, append an audit event, and
    return the removed binding row as JSON. *)
