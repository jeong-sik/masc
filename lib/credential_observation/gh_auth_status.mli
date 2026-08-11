(** Strict projection of [gh auth status --hostname HOST --json hosts].

    The JSON surface is the GitHub CLI's machine contract. Human prose, colour
    markers, and sentence fragments are deliberately not accepted. The
    command must be invoked without [--show-token]; a token field is schema
    drift and fails closed. *)

type token_source =
  | Keyring
  | Environment of string
      (** The environment variable reported by gh, for example [GH_TOKEN]. *)
  | Config_file of string
      (** The [hosts.yml] path reported by gh. No credential value is kept. *)

type outcome =
  | Logged_in
  | Login_failed
  | Timed_out

type entry =
  { outcome : outcome
  ; host : string
  ; account : string option
  ; source_label : string
  ; source : token_source
  ; active : bool
  ; scopes : string list option
  ; git_protocol : [ `Https | `Ssh ]
  ; error : string option
  }

type verdict =
  | Authenticated
  | Unauthenticated
  | Shadowed
  | Unknown

type t =
  { entries : entry list
  ; schema_error : string option
  }

val command_argv : hostname:string -> string array
(** Exact token-free command for one target host. Raises [Invalid_argument]
    when the hostname is empty after trimming. *)

val parse : string -> t
(** Decode the closed JSON schema. Invalid JSON, duplicate/unknown fields,
    unknown enums or inconsistent host identities return no entries and a
    non-empty [schema_error]. *)

val verdict_for_host : t -> hostname:string -> verdict
(** Decide only the requested host. Exactly one active account is required.
    An active environment credential plus a stored credential on the same
    host is [Shadowed]; entries on other hosts never affect the verdict. *)

val verdict_to_string : verdict -> string
