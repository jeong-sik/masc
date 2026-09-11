(** Account/server model-list observations, independent of active runtimes. *)
type protocol = Openai | Anthropic | Kimi | Ollama
type connection = {
  protocol : protocol;
  provider_id : string;
  endpoint : string;
  credential : Runtime_schema.credential option;
}
type model = {
  id : string;
  label : string;
  context : int option;
  tools : bool option;
  listed_at : Yojson.Safe.t option;
}
type error = Invalid_connection | Credential_unavailable | Request_failed
  | Http_error of int | Invalid_response | Repeated_page
val error_message : error -> string
val connection_of_json : Yojson.Safe.t -> (connection, error) result
val discover_with : get:(url:string -> (string, error) result) -> connection ->
  (model list, error) result
val discover : sw:Eio.Switch.t -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  connection -> (Yojson.Safe.t, error) result
val to_json : model list -> Yojson.Safe.t
(** Account/server model-list observations, independent of active runtimes. *)
type protocol = Openai | Anthropic | Kimi | Ollama
type connection = {
  protocol : protocol;
  provider_id : string;
  endpoint : string;
  credential : Runtime_schema.credential option;
}
type model = {
  id : string;
  label : string;
  context : int option;
  tools : bool option;
  listed_at : Yojson.Safe.t option;
}
type error = Invalid_connection | Credential_unavailable | Request_failed
  | Http_error of int | Invalid_response | Repeated_page
val error_message : error -> string
val connection_of_json : Yojson.Safe.t -> (connection, error) result
val discover_with : get:(url:string -> (string, error) result) -> connection ->
  (model list, error) result
val discover : sw:Eio.Switch.t -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  connection -> (Yojson.Safe.t, error) result
val to_json : model list -> Yojson.Safe.t
