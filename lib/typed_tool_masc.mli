(** Typed_tool_masc — MASC-specific typed tool bridge.

    Wraps {!Agent_sdk.Typed_tool} with MASC registration metadata and
    provides atomic registration into {!Tool_spec} + {!Tool_dispatch}.

    The type parameters ['input, 'output] are preserved for compile-time
    handler safety, then erased at registration time.

    @since 2.260.0 *)

(** {1 Core type} *)

type ('input, 'output) t

(** {1 Construction} *)

val create
  :  name:string
  -> description:string
  -> module_tag:Tool_dispatch.module_tag
  -> params:Agent_sdk.Types.tool_param list
  -> parse:(Yojson.Safe.t -> ('input, string) result)
  -> handler:('input -> ('output, string) result)
  -> encode:('output -> Yojson.Safe.t)
  -> ?is_read_only:bool
  -> ?is_destructive:bool
  -> ?is_idempotent:bool
  -> ?visibility:Tool_catalog.visibility
  -> ?requires_join:bool
  -> ?effect_domain:Tool_catalog.effect_domain
  -> unit
  -> ('input, 'output) t

(** {1 Registration} *)

val register : ('input, 'output) t -> unit

(** {1 Conversion} *)

val to_oas : ('input, 'output) t -> ('input, 'output) Agent_sdk.Typed_tool.t
val to_spec : (_, _) t -> Tool_spec.t

(** {1 Introspection} *)

val name : (_, _) t -> string
val schema : (_, _) t -> Agent_sdk.Types.tool_schema
