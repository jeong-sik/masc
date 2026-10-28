(** What a route says about who may call it, as data.

    [Server_route] derives a value from the typed auth kind of a registration and
    stores it on the route, so the route table can be read without running a
    handler. [Unclassified] is what the older registration functions of
    {!Http_server_eio.Router} record. The stack that introduces this module
    removes both in its last layer (docs/rfc/RFC-typed-route-auth.md). *)

(** Why a route authenticates the request itself instead of using one of the
    other kinds. Each reason is a route family whose handler answers a missing
    credential on its own; the A1 baseline
    (docs/evidence/2026-10-28-auth-route-baseline/) measured all three. *)
type self_authenticated_reason =
  | Mcp_transport
      (** [/mcp] and its profiles: the transport answers 401 with a
          [WWW-Authenticate] challenge. *)
  | Oauth_protocol
      (** The OAuth endpoints and the discovery documents that go with them,
          which run before the caller has a credential. *)
  | Websocket_upgrade
      (** An upgrade route ([/ws], the IDE LSP proxy): the handler checks the
          credential before it upgrades. *)

type t =
  | Unclassified
  | Always_public  (** Open on every configuration, strict auth included. *)
  | Public_read
      (** Open on the default configuration; strict auth asks for a read
          credential unless the path is on the public-read list. *)
  | Read_auth
  | Permission of Masc_domain.permission
  | Token_permission of Masc_domain.permission
  | Private_token_permission of Masc_domain.permission
  | Tool of { tool_name : string }
  | Tool_actor of { tool_name : string }
  | Self_authenticated of self_authenticated_reason

(** JSON for the route inventory. [kind] is the constructor in snake case;
    permissions use {!Masc_domain.permission_to_string}. *)
val to_json : t -> Yojson.Safe.t
