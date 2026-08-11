(** Compiler-AST audit for functional-core/effect-shell boundaries. *)

type category =
  | Partial_extraction
  | Failure_erasure
  | Implicit_default
  | Catch_all_exception
  | Effect_in_pure_module

type site =
  { category : category
  ; path : string
  ; scope : string
  ; callee : string
  ; line : int
  ; column : int
  }

type entry =
  { category : category
  ; path : string
  ; scope : string
  ; callee : string
  ; count : int
  }

type report =
  { sites : site list
  ; entries : entry list
  }

type drift =
  { entry : entry
  ; baseline_count : int
  ; current_count : int
  }

type comparison =
  { increases : drift list
  ; reductions : drift list
  }

val default_source_roots : string list
val category_to_string : category -> string
val category_of_string : string -> (category, string) result

val audit_source :
  path:string -> pure:bool -> string -> (site list, string) result
(** Parse one implementation and return semantic sites. Comments and string
    literals are not inspected. *)

val entries_of_sites : site list -> entry list

val audit_repository :
  root:string ->
  source_roots:string list ->
  pure_modules:string list ->
  (report, string) result

val read_pure_modules : root:string -> string -> (string list, string) result
val read_baseline : string -> (entry list, string) result
val write_baseline : string -> entry list -> (unit, string) result
val compare : baseline:entry list -> current:entry list -> comparison

val report_to_text : report -> string
val report_to_json : report -> string
val comparison_to_text : comparison -> string
