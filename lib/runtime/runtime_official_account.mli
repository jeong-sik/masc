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
val environment : 'client t -> string array
(** Return a fresh copy; mutation cannot change the captured selection. *)

val environment_value : 'client t -> string -> string option
val same : 'client t -> 'client t -> bool
(** Compare privately for reload identity; never render credential values. *)
