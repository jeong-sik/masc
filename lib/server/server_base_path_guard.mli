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

type repo_marker =
  | Git_metadata
  | Dune_project
  | Masc_opam

type violation =
  | Implicit_base_path of resolved
  | Source_repo_base_path of {
      base_path : string;
      executable : string option;
      markers : repo_marker list;
    }

val resolution_source_label : resolution_source -> string

val resolve_startup_base_path :
  ?getenv:(string -> string option) ->
  cli_base_path:string option ->
  default_base_path:(unit -> string) ->
  unit ->
  resolved

val enforce : resolved -> (unit, violation) result

val format_violation : violation -> string

val exit_on_violation : (unit, violation) result -> unit
