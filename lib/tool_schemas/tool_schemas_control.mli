(** Tool schemas for [Tool_control] — separated to break the Config
    dependency cycle.

    Carries the [masc_pause] / [masc_resume] schema definitions used
    by the control surface. *)

val schemas : Masc_domain.tool_schema list
