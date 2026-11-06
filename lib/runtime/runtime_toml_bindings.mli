(** Layer 3 of the Runtime TOML parser: the binding tables of each provider
    and the model sets that generate bindings. It also refuses the obsolete
    top-level namespaces. *)

open Runtime_toml_base

val reject_obsolete_top_level_namespaces :
  Otoml.t -> (unit, parse_error list) result

val is_toml_table : Otoml.t -> bool

val parse_bindings :
  Otoml.t ->
  (Runtime_schema.binding list, parse_error list) result
