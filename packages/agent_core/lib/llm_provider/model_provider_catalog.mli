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
  ; identity_hosts : string list
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
