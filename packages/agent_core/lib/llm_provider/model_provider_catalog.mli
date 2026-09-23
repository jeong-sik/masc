(** Provider identity rows embedded in the model catalog TOML. *)

type entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_kind.t
  ; identity_kinds : Provider_kind.t list
  ; base_url : string
  ; base_url_env : string option
  ; request_path : string
  ; api_key_env : string
  ; default_model : string option
  ; capabilities_base : string option
  ; capabilities_base_by_identity_kind : (Provider_kind.t * string) list
    (** Wire-specific capability bases. Keys must also appear in
        [identity_kinds]; absent keys inherit [capabilities_base]. *)
  ; identity_hosts : string list
  ; supports_parallel_tool_suppression : bool
    (** The provider documents a request control that limits a response to at
        most one tool call. Missing declarations are false; this is separate
        from a model being able to generate parallel tool calls. *)
  ; serves_bare_rows : bool
    (** The provider is the vendor's own endpoint for the models the catalog
        describes with bare rows (rows without [provider_name]). Capability
        resolution for a config that names it then reads those rows, by
        prefix, wherever no row is scoped to it
        ({!Capabilities.for_provider_model_id}). Missing declarations are
        false, and the provider's base answers instead. This decides
        capability resolution only: pricing and the Anthropic thinking control
        fall back to bare rows for every provider whatever it declares, and the
        wizard and exact-output lookups read scoped rows only (#37935). *)
  }

val parse_entry : Otoml.t -> (entry, string) result

(** Resolve the exact provider base URL. The optional environment lookup is
    consulted only when the row explicitly declares [base_url_env]; an absent
    or empty override leaves the row's [base_url] unchanged. *)
val resolved_base_url : ?getenv:(string -> string option) -> entry -> string

val provider_label_for_base_url
  :  ?getenv:(string -> string option)
  -> entry list
  -> kind:Provider_kind.t
  -> base_url:string
  -> string option

val provider_label_for_endpoint
  :  ?getenv:(string -> string option)
  -> entry list
  -> kind:Provider_kind.t
  -> base_url:string
  -> request_path:string
  -> string option
