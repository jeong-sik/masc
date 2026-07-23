(** Shared startup guard for server runtime base paths. *)

type resolution_source =
  | Explicit_cli
  | Explicit_env
  | Implicit_default

type resolved = {
  raw_base_path : string;
  normalized_base_path : string;
  resolution_source : resolution_source;
}

type violation = Implicit_base_path of resolved

type canonicalization_error =
  { base_path : string
  ; cause : exn
  ; backtrace : Printexc.raw_backtrace
  }

val resolution_source_label : resolution_source -> string

val resolve_startup_base_path :
  ?getenv:(string -> string option) ->
  cli_base_path:string option ->
  default_base_path:(unit -> string) ->
  unit ->
  resolved

val enforce : resolved -> (unit, violation) result
(** Require an explicit caller-selected base path. The guard does not inspect
    product marker files or executable locations: an explicit base path is the
    runtime boundary, even when that directory is also a source checkout. *)

val canonicalize_existing :
  string -> (string, canonicalization_error) result
(** Resolve an already-created workspace root to the immutable owner identity
    used by locks, configuration, backends, and runtime state. Cancellation is
    never converted to an error. *)

val format_canonicalization_error : canonicalization_error -> string

val format_violation : violation -> string

val exit_on_violation : (unit, violation) result -> unit
