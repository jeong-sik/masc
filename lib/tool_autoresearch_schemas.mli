open Base

(** Tool_autoresearch_schemas — Autoresearch + swarm-facing synthesis
    schema definitions.

    Extracted from [tool_autoresearch.ml] to keep schema data
    separate from logic.

    @since 2.80.0 *)

(** Autoresearch tool schemas: [masc_autoresearch_start],
    [masc_autoresearch_status], [masc_autoresearch_stop],
    [masc_autoresearch_inject], [masc_autoresearch_cycle],
    [masc_autoresearch_record_finding], and
    [masc_autoresearch_search_findings]. *)
val schemas : Types.tool_schema list
