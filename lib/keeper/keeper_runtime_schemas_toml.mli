(** The keeper runtime tool declarations that moved to [config/tools/*.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial runtime
    surface. The three tools still in OCaml are explained in
    the implementation. *)

val fusion : Masc_domain.tool_schema
val fusion_status : Masc_domain.tool_schema
val artifact_read : Masc_domain.tool_schema
val keeper_analyze_image : Masc_domain.tool_schema

(* RFC-0430 Phase 3 — provider Files tools. *)
val file_upload : Masc_domain.tool_schema
val file_delete : Masc_domain.tool_schema
val file_list : Masc_domain.tool_schema

val schemas : Masc_domain.tool_schema list
(** The seven, in the order a model reads them: artifact_read, fusion,
    fusion_status, file_upload, file_delete, file_list,
    keeper_analyze_image. *)
