(** Tool_compact — placeholder tool module.

    No-op schemas and dispatch. Used when compact mode disables tools.

    @since 0.1.0 *)

(** {1 Types} *)

type tool_result = Tool_result.t

(** {1 API} *)

val schemas : Masc_domain.tool_schema list
val dispatch : name:string -> args:Yojson.Safe.t -> tool_result option
