(** Tool_catalog_inference — compatibility shim for effect_domain inference.

    Owns the {!effect_domain} type. [Tool_catalog] re-exports it via type
    aliasing so [tool_catalog.mli] stays byte-compatible.  (The [tool_group]
    display classifier was deleted in the surface-cut refactor.) *)

type effect_domain =
  | Read_only
  | Masc_workspace
  | Playground_write
  | Host_repo_write

val effect_domain_to_string : effect_domain -> string

val inferred_effect_domain : string -> effect_domain option
(** Always [None]. Effect metadata is descriptor/catalog-owned. *)
