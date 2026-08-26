(** Where an MCP server's authorization actually lives, asked rather than
    declared.

    An MCP server publishes its protected-resource metadata, which names the
    authorization server, which publishes its own. Two hops, both public, both
    unauthenticated (RFC 9728 and RFC 8414).

    So a declaration only has to name the MCP server. Endpoints, scopes and
    whether a client secret is needed all come from the answer, which means
    they cannot drift out of date in a file we ship: a provider that moves its
    token endpoint is a provider whose next discovery says so. *)

type error =
  | Bad_mcp_url of string
  | Transport of { url : string; detail : string }
  | Not_published of { url : string; status : int }
  | Malformed of { url : string; detail : string }
  | No_authorization_server of string
      (** the resource published metadata but named no authorization server *)

val error_to_string : error -> string

type t = {
  resource : string;  (** the MCP endpoint this authorizes *)
  issuer : string;
  authorize_url : string;
  token_url : string;
  registration_url : string option;
      (** RFC 7591 dynamic client registration, when the server offers it. A
          server that does is one no operator has to register an app with. *)
  scopes_supported : string list;
  supports_pkce_s256 : bool;
      (** Absent S256 is disqualifying rather than a weaker default: without
          it the authorization code is bearer material in a redirect. *)
  client_secret_optional : bool;
      (** True when the token endpoint accepts ["none"], which is what makes
          a public client possible -- PKCE proves the redemption instead of a
          secret nobody could keep on an operator's machine anyway. *)
}

(** How discovery reads. Injected so the two hops can be exercised against
    recorded answers; the shapes here change when a provider changes them,
    and a test that needs the network cannot say when that happened. *)
type get = url:string -> (int * string, string) result

val discover : ?get:get -> mcp_url:string -> unit -> (t, error) result
(** [discover ~mcp_url] asks [mcp_url]'s origin for its protected-resource
    metadata, then asks the authorization server it names for its own.

    The first hop's URL follows RFC 9728: the well-known segment goes between
    the origin and the resource path, not after it. *)
