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
      (** the endpoint answered 404: the metadata document is genuinely absent,
          so the RFC 9728 §3 root fallback is worth trying *)
  | Rejected of { url : string; status : int }
      (** the endpoint answered a non-404 error (400/401/403/429/5xx…): it is
          reachable and answered, but refused this request. The document is not
          known to be absent, so "publishes no such metadata" would misread it *)
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
}

(** How discovery reads. Injected so the two hops can be exercised against
    recorded answers; the shapes here change when a provider changes them,
    and a test that needs the network cannot say when that happened. *)
type get = url:string -> (int * string, string) result

(** How the MCP endpoint is asked where its metadata is: the response
    headers of one unauthenticated request, or [None] when the request did
    not complete. Injected for the same reason [get] is -- the shape here is
    a provider's to change, and a test that needs the network cannot say
    when it did. *)
type ask = url:string -> (string * string) list option

val discover :
  ?get:get -> ?ask:ask -> mcp_url:string -> unit -> (t, error) result
(** [discover ~mcp_url] finds where [mcp_url]'s protected-resource metadata
    is, reads it, then asks the authorization server it names for its own.

    Where the first document is comes from the server when it says: RFC 9728
    5.1 has an unauthenticated request answered with a WWW-Authenticate
    header naming it. Only when no header says so is the URL computed, with
    the well-known segment between the origin and the resource path as RFC
    9728 3 defines it.

    Both routes are needed rather than either alone. Measured across 41 live
    MCP servers on 2026-08-27: eleven name a location the computed URL does
    not reach, because they publish at the origin and serve MCP below it,
    and nine send no such header at all. *)
