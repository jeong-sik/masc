(** Immutable login-context selection. The private environment may contain
    credentials; this type deliberately has no JSON or pretty-print projection. *)
type claude_code
type codex

type _ client =
  | Claude_code : claude_code client
  | Codex : codex client

type source =
  | Declared_directory
  | Inherited_directory
  | Inherited_user_home

type 'client t

type 'client selection =
  | Current of string option
  | Captured of 'client t
(** Direct CLI calls may select their current declaration at call time.
    Materialized runtimes carry only the captured value. *)

val default_directory : 'client client -> string
(** The client's configuration-directory name beneath its inherited user HOME. *)

val capture
  :  client:'client client
  -> declaration:string option
  -> ('client t, string) result
(** Observe the process environment once, derive home/source, and apply the
    client's credential projection. Callers cannot certify arbitrary bytes as
    a projected context. Codex includes credential names declared in the selected
    home's root config.toml; MASC does not select a separate CLI profile. *)

(** Why {!capture_on_key} captured no account. *)
type key_capture_error =
  | Key_not_read of Runtime_api_key_file.read_error
      (** The file gave no key ({!Runtime_api_key_file.read}). *)
  | Key_not_captured of string
      (** The key was read and the account was not captured: what {!capture}
          answers. *)

(** {!capture} for Claude Code on the API key of [key_file] (RFC
    a-persons-api-key-is-their-own-provider-account 3.4). The capture reads
    the file itself ({!Runtime_api_key_file.read}), so a caller cannot name
    one file and hand over the key of another: {!key_file} of the account is
    the file its key came from.

    The child takes from the environment of the server only the names a
    declared account takes, whether or not [declaration] names a home: no API
    key, authentication token, provider choice, cloud credential or endpoint
    of the server. A home the environment chose keeps its
    [CLAUDE_CONFIG_DIR]. The key is then the one [ANTHROPIC_API_KEY] of the
    child, which a non-interactive session uses before the account signed in
    to the home. *)
val capture_on_key
  :  declaration:string option
  -> key_file:string
  -> (claude_code t, key_capture_error) result

val resolve_home : client:'client client -> declaration:string option -> (string, string) result
(** Current directory metadata for setup/display boundaries. This does not
    capture credentials or certify an executable context. *)

val private_codex_environment : home:string -> codex t -> (string array, string) result
(** Derive an isolated process view from the captured credentials, reapplying
    the private configuration's explicit isolation filter. *)

val client : 'client t -> 'client client
(** The client the account was captured for. *)

val home : 'client t -> string
val source : 'client t -> source

(** The file the API key of the account was read from, as {!capture_on_key}
    was given it. [None] for an account of {!capture}, which carries no key
    of a file. *)
val key_file : 'client t -> string option

(** The names of the environment variables the configuration of the home
    asks for: [env_key] and [env_http_headers] of the providers in the
    [config.toml] of a Codex home, sorted. {!capture} took the value of each
    one the environment of the process has. A Claude Code home asks for
    none. *)
val names_asked_by_the_home : 'client t -> string list
val environment : 'client t -> string array
(** Return a fresh copy; mutation cannot change the captured selection. *)

val environment_value : 'client t -> string -> string option
val same : 'client t -> 'client t -> bool
(** Compare privately for reload identity; never render credential values. *)
