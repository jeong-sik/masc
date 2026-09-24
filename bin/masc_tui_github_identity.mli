(** The Keeper GitHub tab: what the keeper's config stores, against what this
    host resolves from it. Apart from the loader so the rows have a test that
    reads them; the loader is an executable module and a test cannot link it. *)

(** Whether the server said the token is signed in. A server that leaves
    [authenticated] out, or sends it as something other than a boolean, has
    not said no. *)
type sign_in =
  | Known of bool
  | Unreported

(** What the token may do, as GitHub listed it. *)
type scopes =
  | Listed of string list
  | Not_listed_by_github
      (** [null]: a fine-grained PAT or an App token GitHub lists no scopes
          for. Not the same as an empty list, which reads as "none". *)
  | Scopes_unreported  (** No key at all: a server that does not report scopes. *)

type reading = {
  sign_in : sign_in;
  login : string option;
  error : string option;
  scopes : scopes;
}

type probe_scope =
  | Host_process
  | Remote_endpoint
  | Probe_scope_unknown

type t = {
  hostname : string;
  config_dir : string option;
  token_env_names : string list;
  stored : reading option;
  effective : reading option;
  probe_scope : probe_scope;
}

val decode : Yojson.Safe.t -> t option
(** The record built by [Keeper_github_identity.observation_to_yojson].
    [None] when the payload is not an object or carries no [hostname], such as
    an error envelope; {!view_lines} then draws the raw block. *)

val lines : t -> string list
(** The tab's rows, unsanitized. The stored and effective readings share one
    row, labelled with both names, when they would draw the same sentence;
    they take a row each when they differ. *)

val view_lines : sanitize:(string -> string) -> Yojson.Safe.t -> string list
(** {!lines} of the decoded payload, or the pretty-printed payload when it
    does not decode, each row through [sanitize]. [sanitize] is mandatory so
    a terminal caller cannot skip it; tests pass [Fun.id]. *)
