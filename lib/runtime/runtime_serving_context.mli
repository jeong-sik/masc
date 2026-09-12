(** Observe the selected local model's serving window, never its architectural
    maximum. Only [load=true] may preload the selected Ollama model. *)
type source = Running_model | Configured_model | Serving_endpoint | Not_reported
type observation = { model : string; context : int option; source : source; tools : bool option }
val observe : sw:Eio.Switch.t -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  Runtime_model_discovery.connection -> model:string -> load:bool ->
  (Yojson.Safe.t, Runtime_model_discovery.error) result
