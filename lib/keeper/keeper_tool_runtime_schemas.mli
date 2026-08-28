(** Canonical input schemas for Keeper handlers implemented in the main
    runtime library. Descriptor projection and dispatch registration consume
    these same values. *)

val artifact_read : Masc_domain.tool_schema
val fusion : Masc_domain.tool_schema
val fusion_status : Masc_domain.tool_schema
val keeper_analyze_image : Masc_domain.tool_schema

val schemas : Masc_domain.tool_schema list
(** Complete stable-order runtime schema inventory owned by this module. *)
