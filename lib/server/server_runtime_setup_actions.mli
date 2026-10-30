(** Authenticated setup route implementation. Call only after CanAdmin and bind
    [base_path] to the authenticated workspace. Requests never accept credential
    file paths; references are resolved from selected native catalog entries. *)
type error = Invalid_request | Configuration_unavailable | Network_unavailable | Unsupported_connection | Disabled_connection
  | Credential_unavailable | Discovery_failed of Runtime_model_discovery.error
  | Save_failed of Runtime_setup_batch.error
(** [Network_unavailable]: the route was reached on a server whose Eio context
    holds no network, so discovery cannot start. *)
val error_message : error -> string
val status_of_error : error -> Httpun.Status.t
(** 400 for a wrong request or selected connection, 409 when the workspace
    revision or writer lock moved, 502 when the connected runtime answered
    badly, 503 when this server cannot read its configuration or reach the
    network. *)
val discover : binary:string -> sw:Eio.Switch.t -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Explicit native account/server metadata request only, not response/tool verification. *)
val context : binary:string -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Selected-model serving/CLI context observation. Ollama preload requires the
    explicit [load] request flag. No architectural context is used for local servers. *)
val select_account : base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Explicitly select the declared or server-native default account HOME for
    Claude Code, Codex or Muse. Returns an opaque lease, not authentication proof.
    Paths and commands are resolved by the server, never supplied by the browser. *)
type login_target = {
  client : Runtime_setup_login_client.client;
  cli_path : string;
  spawn_path : string;
}
(** [cli_path] is the catalog's original command spelling and scopes account
    references; [spawn_path] is that command resolved to the executable the
    login process spawns. *)
val login_target : base_path:string -> integration_id:string -> (login_target, error) result
(** Resolve the official client and executable from the current server catalog.
    [spawn_path] is resolved in the server working directory, before the login
    process moves to the account home. *)
val import_account : binary:string -> base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Explicit selected Antigravity account import; returns only a workspace-bound
    opaque reference and projected metadata. Original source auth is untouched. *)
val save : binary:string -> base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t,error) result
(** Ordered selections refer to existing IDs or connection/model indexes.
    Optional [default_runtime_id] preserves the current named default lane,
    using the concrete selections as its candidate order; otherwise it must
    name a selected concrete binding. Omission selects the first binding.
    New IDs come only from the native renderer. Selected runtimes must pass
    response/tool verification before publication. Muse selections must match
    a model ID and positive context freshly reported for the selected account
    before configuration or verification begins. No owner/sandbox proof. *)
