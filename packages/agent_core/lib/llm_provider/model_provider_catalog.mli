(** Provider identity rows embedded in the model catalog TOML. *)

type entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_kind.t
  ; identity_kinds : Provider_kind.t list
  ; base_url : string
  ; request_path : string
  ; requires_api_key : bool
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
  ; serves_bare_models : Model_identifiers.Model_id.t list
    (** Explicit exact provider-independent model IDs served by this endpoint.
        Authorization uses ASCII case equality, never a family prefix. Absence or an empty list grants no
        bare-row authority. The request model id alone cannot grant it, and
        capability manifests are outside this declaration. *)
  }

val parse_entry : Otoml.t -> (entry, string) result

(** Resolve the exact provider base URL: the row's [base_url] as written. *)
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
