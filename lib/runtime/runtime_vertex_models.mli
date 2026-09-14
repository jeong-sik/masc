(** Current Google publisher inventory retrieved with ADC. Listing a model is
    not proof that the selected project can invoke it. *)
type model = { id : string; display_name : string }
type page = { models : model list; next_page_token : string option }
val parse_page : string -> (page, string) result
val discover_with : get:(url:string -> (string, string) result) -> base_url:string ->
  (model list, string) result
(** Headers for one discovery request: the Gemini codec over an OAuth bearer
    token from [credential_source]. No [Provider_config.t] is built because
    discovery runs before any model id exists. *)
val auth_headers : credential_source:Llm_provider.Provider_config.credential_source ->
  ((string * string) list, string) result
val discover : sw:Eio.Switch.t -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_url:string -> (Yojson.Safe.t, string) result
