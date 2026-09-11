(** Authenticated setup route implementation. Call only after CanAdmin and bind
    [base_path] to the authenticated workspace. Requests never accept credential
    file paths; references are resolved from selected native catalog entries. *)
type error = Invalid_request | Configuration_unavailable | Unsupported_connection
  | Credential_unavailable | Discovery_failed of Runtime_model_discovery.error
  | Save_failed of Runtime_setup_batch.error
val error_message : error -> string
val discover : sw:Eio.Switch.t -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Explicit HTTP metadata request only, not response/tool verification. *)
val save : binary:string -> base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Ordered selections refer to existing IDs or connection/model indexes.
    New IDs come only from the native renderer. Selected runtimes must pass
    response/tool verification before publication. No owner/sandbox proof. *)
