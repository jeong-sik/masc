(** Resolve a cascade name to its ordered list of model strings.

    Owns the materialized-JSON traversal used to pull weighted entries out
    of {!Cascade_config_loader.load_catalog_source}, plus the selection-
    trace builder consumed by dashboards.

    Extracted from [cascade_config.ml]. {!cascade_source} and
    {!selection_trace} are defined here and aliased by {!Cascade_config}
    so the facade contract is unchanged.

    @stability Internal *)

type cascade_source =
  | Named
  | Default_fallback
  | Hardcoded_defaults
  | Load_failed of string
  (** Carries the underlying parse/IO error so dashboards can distinguish
      "config absent / not found" from "config present but unreadable". *)

type selection_trace = {
  candidates : Cascade_config_selection.candidate_info list;
  source : cascade_source;
}

val configured_weighted_entries_from_materialized_json :
  Yojson.Safe.t ->
  name:string ->
  Cascade_config_loader.weighted_entry list

val resolve_model_strings :
  ?config_path:string ->
  name:string ->
  defaults:string list ->
  unit ->
  string list

val resolve_model_strings_traced :
  ?config_path:string ->
  name:string ->
  defaults:string list ->
  unit ->
  string list * cascade_source

val resolve_model_strings_with_trace :
  ?config_path:string ->
  name:string ->
  defaults:string list ->
  unit ->
  string list * selection_trace

val selection_trace_of_weighted_entries :
  ?source:cascade_source ->
  Cascade_config_loader.weighted_entry list ->
  selection_trace

val expand_model_strings_for_execution :
  ?rotation_scope:string -> string list -> string list
