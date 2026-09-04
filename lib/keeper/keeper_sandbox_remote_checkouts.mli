(** Discover and inspect git checkouts for an [Endpoint_owned] keeper.

    For [Shared_mount] (Docker), checkouts sit on the host filesystem and are
    discovered by {!Keeper_playground_checkouts.discover} and inspected via
    host git subprocesses.

    For [Endpoint_owned] (Micro_vm and Remote_ssh), checkouts sit exclusively
    on the endpoint (in a guest VM work volume or on a remote machine). This
    module executes discovery and inspection on the endpoint in a single
    bounded pass. *)

type inspected_checkout =
  { checkout : Keeper_playground_checkouts.checkout
  ; origin_url : string option
  ; branch : (string, string) result
  ; head : (string, string) result
  ; dirty : (bool * int, string) result
  ; target_ref : string option
  ; upstream_head : string option
  ; ahead : int option
  ; behind : int option
  }

val parse_probe_json :
  root:string ->
  string ->
  ( (Keeper_playground_checkouts.discovery, Keeper_playground_checkouts.scan_error) result
    * inspected_checkout list
  , string ) result
(** Parse the raw JSON output produced by the remote discovery and inspection
    script. Exposed for unit testing. *)

val discover_and_inspect :
  timeout_sec:float ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  catalog:(Repo_manager_types.repository list, string) result ->
  unit ->
  ( (Keeper_playground_checkouts.discovery, Keeper_playground_checkouts.scan_error) result
    * inspected_checkout list
  , Keeper_playground_checkouts.scan_error ) result
(** Acquire the keeper's attached endpoint, run the remote discovery and
    inspection probe within [timeout_sec], and parse the results. *)
