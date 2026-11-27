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

val target_ref_stale_after_s : int
(** Maximum age of a local target-ref observation before equality with HEAD
    must be reported as stale in both host and endpoint probes. *)

val probe_budget_sec : float
(** How long the endpoint probe may run as a whole. Separate from
    {!Repo_git.inspection_timeout_sec}, which budgets git subprocesses on this
    host. The measured basis is written next to the value. *)

val checkout_inspection_sec : float
(** How long the git reads of one checkout may take together, inside the
    probe. Shorter than {!probe_budget_sec}: a checkout past it reports its
    git fields as unread and the other checkouts still report. *)

val inspection_workers : int
(** How many checkouts the probe inspects at a time. *)

val guest_state_timeout_sec : float
(** Budget for each container-runtime read around the probe: guest admission
    before it and the absence check after a failure. *)

(** The budgets {!discover_and_inspect} and {!discover_layout} give each step
    for a caller's [timeout_sec]. *)
type budgets =
  { guest_state_sec : float
      (** Guest admission and the absence check after a failure. *)
  ; payload_sec : float  (** The shim's limit on the probe itself. *)
  ; checkout_sec : float  (** One checkout's git reads, inside the probe. *)
  ; workers : int  (** Checkouts inspected at a time. *)
  }

type inspected_checkout =
  { checkout : Keeper_playground_checkouts.checkout
  ; origin : remote_origin
  ; branch : (string, string) result
  ; head : (string, string) result
  ; dirty : (bool * int, string) result
  ; target_ref : string option
  ; upstream_head : string option
  ; target_ref_last_observed_at_unix : int option
  ; ahead : int option
  ; behind : int option
  }

type layout =
  { entries : string list
  ; discovery : Keeper_playground_checkouts.discovery
  }

val discover_layout :
  ?read_authority:Keeper_sandbox_remote_lane.read_authority ->
  timeout_sec:float -> config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta -> unit ->
  (layout, Keeper_playground_checkouts.scan_error) result
(** Observe immediate entries and checkout locations on the attached endpoint,
    without starting a guest or running git. Uses the inspection probe's shared
    traversal and resource bounds. Missing/unreachable endpoints and unreadable
    directories never become an empty complete tree. *)

val parse_layout_json : root:string -> string -> (layout, string) result
(** Strict decoder for the discovery-only endpoint response. *)

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

  val probe_mode_argv_index : int
  (** Zero-based index of the mode argument (["inspect"] or ["layout"]) in the
      full [python3 -c ...] [argv] passed to the endpoint shim. *)

  val budgets : timeout_sec:float -> budgets
  (** The budgets a probe run with [timeout_sec] uses. *)
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
    inspection probe within [timeout_sec], and parse the results. The probe
    inspects {!inspection_workers} checkouts at a time, and each checkout's
    git reads share {!checkout_inspection_sec}. Guest admission and the
    absence check after a failure each take {!guest_state_timeout_sec}, not
    [timeout_sec]. *)
