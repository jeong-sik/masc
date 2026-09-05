(** Per-keeper GitHub App installation tokens (RFC keeper-github-apps).

    A keeper opts into App identity by carrying
    [keepers/<name>/github-app/{app-id,installation-id,private-key.pem}].
    Before an execution lane projects the keeper's [github-cli/hosts.yml],
    {!ensure_fresh} mints (or reuses) a one-hour installation token for that
    App and rewrites the hosts file, so every lane keeps consuming the same
    [GH_CONFIG_DIR] contract unchanged. A keeper without the credential
    directory stays on whatever identity its hosts file already carries —
    the shared-account path — and {!ensure_fresh} answers
    [No_app_identity] without touching anything. *)

type outcome =
  | No_app_identity
      (** No [github-app/] credential directory: nothing was read or
          written; the keeper's existing hosts file stands. *)
  | Fresh of { expires_at : float }
      (** The stored token is still comfortably inside its lifetime. *)
  | Refreshed of { expires_at : float }
      (** A new installation token was minted and the hosts file rewritten. *)

type http_post =
  url:string
  -> headers:(string * string) list
  -> body:Yojson.Safe.t
  -> (int * string, string) result
(** Injected transport: status code and body text, or a transport error.
    Production passes the shared local-runtime HTTP client; tests pass a
    stub. *)

val ensure_fresh :
  now:float
  -> http_post:http_post
  -> config:Workspace.config
  -> keeper_name:string
  -> (outcome, string) result
(** Fail-closed only when it must: a stale (or absent) token with a failed
    mint is an [Error]; a token that is still fresh never touches the
    network. Freshness means more than five minutes of lifetime
    left. *)

val default_http_post : http_post
(** Production transport: the shared local-runtime curl client, 10s
    timeout. *)

(** Exposed for tests. *)
module For_testing : sig
  val jwt_rs256 :
    now:float -> app_id:string -> private_key_pem:string -> (string, string) result

  val parse_mint_response :
    string -> (string * float, string) result
  (** token, expires_at (unix seconds) from a GitHub
      access_tokens response. *)
end
