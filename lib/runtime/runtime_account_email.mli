(** The email an official client reports for its signed-in account, shown
    beside that account in setup surfaces so the operator can tell accounts
    apart. It is display text read from the client's own login files once,
    when a setup login completes. It is never account identity,
    authentication, admission or routing input.

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

val missing_to_string : missing -> string

val of_codex_auth : string -> (t, missing) result
val of_claude_account : string -> (t, missing) result
val of_muse_auth : string -> (t, missing) result
val of_google_oauth : string -> (t, missing) result
(** Each reads the bytes of one client's login file. A key that appears twice
    in one object is [Source_unrecognized]; [null] reads as absent. *)

type account =
  | Native_home of string
      (** Codex, Claude Code or Muse Code [account-home], exact spelling *)
  | Credential_file of string  (** Antigravity durable OAuth file *)

val account_of_provider : Runtime_schema.provider -> account option
(** The selected account a declared provider runs on. A native client without
    [account-home] runs on the inherited home, which setup login never
    selects, so it has no account here; neither does any HTTP provider. *)

type recorded =
  | Recorded of t
  | Absent  (** no login through setup recorded an email for this account *)
  | Unreadable  (** the private record exists but could not be read *)

val inventory_json : lookup:(account -> recorded) -> Runtime_schema.config -> Yojson.Safe.t
(** One row per declared provider with an account:
    [{"integration_id", "state": "recorded", "email"}], or [state] ["absent"]
    or ["unreadable"] without [email]. [lookup] reads only setup's own
    records, so building this never opens an account's login files. *)
