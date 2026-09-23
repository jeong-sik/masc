(** Discover and inspect git checkouts for an [Endpoint_owned] keeper.

    For [Shared_mount] (Docker), checkouts sit on the host filesystem and are
    discovered by {!Keeper_playground_checkouts.discover} and inspected via
    host git subprocesses.

    For [Endpoint_owned] (Micro_vm and Remote_ssh), checkouts sit exclusively
    on the endpoint (in a guest VM work volume or on a remote machine). This
    module executes discovery and inspection on the endpoint in a single
    bounded pass. *)

(** What the endpoint probe learned about a checkout's [origin] remote. *)
type remote_origin =
  | Origin_url of string
  | Origin_not_configured
      (** [git remote get-url origin] exited 2: the repository has no
          [origin] remote. *)
  | Origin_unread
      (** The lookup timed out, git was missing, or it failed otherwise. *)

type inspected_checkout =
  { checkout : Keeper_playground_checkouts.checkout
  ; origin : remote_origin
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
    script. Every field is read by shape: a row, a limit or a [git_link] value
    that does not decode is an [Error] naming the field, never a default.
    Exposed for unit testing. *)

module For_testing : sig
  val probe_script : string
  (** The Python the endpoint runs, so a test can run it on a real tree. *)
end

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
