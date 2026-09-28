(** The email an official client reports for its signed-in account, shown
    beside that account so the operator can tell accounts apart. It is display
    text, read from the client's own login file each time a surface asks, so it
    follows a sign-in made inside or outside setup. It is never account
    identity, authentication, admission or routing input.

    Sources, confirmed on 2026-09-28 by reading key names and value types of
    the installed clients' files (see
    docs/evidence/2026-09-28-login-account-email-sources.md):
    - Codex: [auth.json] [tokens.id_token], OpenID claim [email]
    - Claude Code: [.claude.json] [oauthAccount.emailAddress]
    - Muse Code: [.config/muse/auth.json] [providers.meta.user_email]
    - Antigravity: OAuth JSON [id_token], OpenID claim [email] *)

type t = private string

val max_bytes : int
(** 254, the longest forward path RFC 5321 section 4.5.3.1.3 admits. *)

val of_string : string -> t option
(** Valid UTF-8 of 1 to [max_bytes] bytes with no ASCII space or control
    byte. Anything else is not displayable email text. *)

val to_string : t -> string

type missing =
  | Source_unavailable  (** the login file could not be read *)
  | Source_unrecognized  (** not the document shape this reader knows *)
  | Not_reported  (** the document names no email for this account *)
  | Invalid_email  (** the reported value fails {!of_string} *)
  | Environment_credential
      (** the client is given a credential it uses before its login file's
          account, so that file's email is not the account it runs on *)

val missing_to_string : missing -> string

val missing_to_wire : missing -> string
(** The spelling of each {!missing} case in the setup inventory. *)

val of_codex_auth : string -> (t, missing) result
val of_claude_account : string -> (t, missing) result
val of_muse_auth : string -> (t, missing) result
val of_google_oauth : string -> (t, missing) result
(** Each reads the bytes of one client's login file. A key that appears twice
    in one object is [Source_unrecognized]; [null] reads as absent. *)

val of_provider : Runtime_schema.provider -> (t, missing) result option
(** Reads, now, the login file of the account a declared provider runs on. A
    Codex, Claude Code or Muse Code provider runs on its [account-home], or
    without one on the home it inherits from this server's environment; the
    file is found there the way that client finds it. An Antigravity provider
    has an account only with a file credential. [None] for a provider with no
    account: an HTTP provider, or Antigravity with an env or inline credential.
    A native client whose environment names no home is [Source_unavailable].
    Claude Code on the inherited home is [Environment_credential] while
    {!Runtime_claude_code.runs_on_environment_credential} holds. How Codex
    ranks an inherited OPENAI_API_KEY or CODEX_API_KEY against its ChatGPT
    login is not documented (checked 2026-09-28), so a Codex row names the
    login file's email whatever the environment holds. *)

val row_json : integration_id:string -> (t, missing) result -> Yojson.Safe.t
(** One setup-inventory row: [{"integration_id", "state": "read", "email"}],
    or [{"integration_id", "state": "not_read", "cause"}] with [cause] from
    {!missing_to_wire}. *)

val inventory_json : Runtime_schema.config -> Yojson.Safe.t
(** {!row_json} of {!of_provider} for each declared provider with an
    account. *)
