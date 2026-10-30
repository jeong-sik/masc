(** Account/server model-list observations, independent of active runtimes. *)
type protocol = Openai | Anthropic | Kimi | Ollama
type provider = Anonymous_endpoint | Named_provider of string
type connection = {
  protocol : protocol;
  provider : provider;
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
val resolve_credential : connection -> (Llm_provider.Secret.t, error) result
(** An unnamed custom endpoint without a credential requests anonymous access;
    a named provider retains its catalog credential requirement. *)
val discover : sw:Eio.Switch.t -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  connection -> (Yojson.Safe.t, error) result
val to_json : model list -> Yojson.Safe.t
