(** What a route says about who may call it, as data.

    [Server_route] derives a value from the typed auth kind of a registration and
    stores it on the route, so the route table can be read without running a
    handler. *)

(** Why a route authenticates the request itself instead of using one of the
    other kinds. Each reason is a route family whose handler answers a missing
    credential on its own; the A1 baseline
    (docs/evidence/2026-10-28-auth-route-baseline/) measured how these families
    answer without one. *)
type self_authenticated_reason =
  | Mcp_transport
      (** [/mcp] and its profiles, and the observer streams [/ag-ui/events] and
          [/events/presence]: the transport answers 401 with a
          [WWW-Authenticate] challenge. *)
  | Oauth_protocol
      (** The OAuth endpoints, the discovery documents that go with them and the
          callback pages, which run before the caller has a credential. *)
  | Websocket_upgrade
      (** An upgrade route ([/ws], the IDE LSP proxy): the handler checks the
          credential before it upgrades. [/ws] checks it for an upgrade only: a
          [GET /ws] that does not ask to upgrade gets the discovery document
          without one. The IDE LSP proxy checks every request. *)
  | Browser_lane
      (** The browser lane add-on's endpoints: the handler checks the lane token
          and answers 403 without it. *)
  | Loopback_dev_token
      (** [/api/v1/dashboard/dev-token]: the handler answers 404 unless the bind
          is loopback and strict auth is off. Past that it runs [with_public_read]
          itself (503 before the server is ready, 400 or 409 for a workspace
          precondition that fails) and hands out the dashboard token without a
          credential (#46560). *)
  | Subpath_dispatch
      (** A prefix route whose handler picks the authentication by the part of
          the path after the prefix ([/api/v1/keepers/]). The kinds of its
          sub-routes are not in the route table. *)

type t =
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
