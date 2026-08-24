(** The four spawn tool schemas, as declared in
    [config/tools/masc_spawn*.toml].

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial spawn
    surface, so a reader of these values never has to ask whether a schema
    loaded. *)

val start : Masc_domain.tool_schema
val read : Masc_domain.tool_schema
val wait : Masc_domain.tool_schema
val stop : Masc_domain.tool_schema
