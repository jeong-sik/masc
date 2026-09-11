(** Authenticated setup route implementation. Call only after CanAdmin and bind
    [base_path] to the authenticated workspace. Requests never accept credential
    file paths; references are resolved from selected native catalog entries. *)
type error = Invalid_request | Configuration_unavailable | Unsupported_connection
  | Credential_unavailable | Discovery_failed of Runtime_model_discovery.error
  | Save_failed of Runtime_setup_batch.error
val error_message : error -> string
val discover : binary:string -> sw:Eio.Switch.t -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Explicit native account/server metadata request only, not response/tool verification. *)
val context : binary:string -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Selected-model serving/CLI context observation. Ollama preload requires the
    explicit [load] request flag. No architectural context is used for local servers. *)
val import_account : binary:string -> base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Explicit selected Antigravity account import; returns only a workspace-bound
    opaque reference and projected metadata. Original source auth is untouched. *)
val save : binary:string -> base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Ordered selections refer to existing IDs or connection/model indexes.
    New IDs come only from the native renderer. Selected runtimes must pass
    response/tool verification before publication. No owner/sandbox proof. *)
