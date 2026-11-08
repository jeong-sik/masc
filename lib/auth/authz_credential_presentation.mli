(* HIGH-RISK-UNREVIEWED: this module decides which credential a request in
   multi-account mode presents. The gate authenticates only what it says. *)

(** The credential a request presents in multi-account mode (design 5.2 and
    5.3, plan C4-7).

    A request authenticates with exactly one credential (design 5.3). This
    module reads what the server took from the request and says which one, or
    that there is none, several, or one that does not read. It reads no state
    and checks no secret: {!Authz_browser_session.authenticate},
    {!Authz_pat.authenticate} and {!Authz_service_credential.authenticate} do,
    and the gate of C4-8 decides what each answer means for a route.

    {b No silent winner.} Two credentials are {!Several}, whichever they are: a
    cookie does not win over a bearer, a bearer does not win over the internal
    token header, and two fields of one header are two credentials. Single-user
    mode reads its own way and does not use this module. *)

(** What the server took from the request, as it came. *)
type request =
  { authorization : string list  (** Every [Authorization] field. *)
  ; internal_token : string list  (** Every [x-masc-internal-token] field. *)
  ; session_cookies : string list
        (** Every value of the [__Host-masc_session] cookie, from every
            [Cookie] field. *)
  ; query_credential : bool
        (** A credential in the query string: [token], [sse_kind=observer], or
            the IDE LSP token. *)
  }

(** A credential that is there and does not read. *)
type unreadable =
  | Not_a_bearer  (** An [Authorization] field that is not [Bearer] and a token. *)
  | Malformed_pat  (** A bearer with the PAT prefix whose rest is not a PAT. *)
  | Malformed_service_credential  (** The same, for the Service credential prefix. *)
  | Not_a_session_cookie  (** A session cookie whose value is not one. *)

type t =
  | No_credential
  | Session of Authz_browser_session.Cookie.t
  | Pat of Authz_credential_token.Pat.t
  | Service_credential of Authz_credential_token.Service_credential.t
  | Mcp_oauth_token
      (** A bearer with the [mat_] prefix of an MCP OAuth access token. It is
          refused until the layer that binds it to a session (plan C5). *)
  | Legacy_bearer
      (** Any other bearer, and the internal token header: the workspace
          secret, an [agent_credential] token, or a Keeper internal token.
          Multi-account mode refuses them ([Legacy_credential_forbidden],
          design 5.3). *)
  | Query_credential  (** Multi-account mode reads no credential from a query string. *)
  | Several  (** Two or more credentials. *)
  | Unreadable of unreadable

val unreadable_to_string : unreadable -> string

(** A label for logs and answers. It names the kind, never the token. *)
val to_string : t -> string

(** Counts the credentials first, then reads the one that is there. A bearer
    is [Bearer], a space, and the token, with the scheme in any case; the
    token is read without the blanks around it. *)
val read : request -> t
