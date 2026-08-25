(** Typed-tree audit for the mechanical part of the functional-core boundary.

    The audit reads compiler-produced [.cmt] files. It therefore classifies
    resolved value paths rather than source spellings: a module alias of
    [Option.get] is still found, while an unrelated local [Option.get] is not. *)

type category =
  | Partial_extraction
  | Failure_erasure
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
  ; scanned_sources : int
  ; scanned_cmt_files : int
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

val normalize_resolved_callee : string -> string
(** Normalize compiler path presentation without changing module identity. *)

val category_for_resolved_callee : string -> category option
(** Classify only mechanically forbidden operations. In particular this does
    not classify [Option.value] or catch-all handlers. *)

val effectful_resolved_callee : string -> bool
(** Whether a resolved callee is a canonical external-effect API forbidden in
    a module explicitly registered as pure. *)

val entries_of_sites : site list -> entry list

val audit_repository :
  root:string ->
  build_dir:string ->
  source_roots:string list ->
  pure_modules:string list ->
  (report, string) result
(** Audit every production source and fail if its typed tree is missing. *)

val read_pure_modules : root:string -> string -> (string list, string) result
val read_module_paths : string -> (string list, string) result
(** Parse a module-path registry without requiring the paths to exist in the
    current checkout. Used only to compare a PR-base pure registry after a
    module was legitimately deleted. *)
val read_baseline : string -> (entry list, string) result
val write_baseline : string -> entry list -> (unit, string) result
val compare : baseline:entry list -> current:entry list -> comparison

val report_to_text : report -> string
val report_to_json : report -> string
val comparison_to_text : comparison -> string
