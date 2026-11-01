open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val managed_kind : string

val turn_kind : string


type stop_scope = Keeper_sandbox_control_contract.stop_scope =
  | Stop_managed
  | Stop_turn
  | Stop_all

val parse_stop_scope : string -> (stop_scope, string) result

val stop_scope_to_string : stop_scope -> string

val ensure_host_root : string -> (unit, string) result
(** Make [path] an existing directory for use as a Docker bind-mount source.
    A missing path is created with its parents. An existing regular file or
    device is an [Error] naming what it is; so is a path that cannot be
    inspected or created, and a symbolic link that points nowhere. A link to a
    directory counts as that directory. *)

val start_managed_container :
  config:Workspace.config ->
  meta:keeper_meta ->
  network_mode:network_mode ->
  ttl_sec:float ->
  timeout_sec:float ->
  unit ->
  (Yojson.Safe.t, string) result

val stop_containers :
  ?keeper_name:string ->
  scope:stop_scope ->
  config:Workspace.config ->
  timeout_sec:float ->
  unit ->
  Keeper_sandbox_runtime.stop_result

val repository_checkouts_json :
  include_repository_checkouts:bool ->
  config:Workspace.config ->
  meta:keeper_meta ->
  Yojson.Safe.t
(** Inspect Keeper-visible repository checkouts. Repository identity comes
    from the repository catalog; execution availability comes from the
    checkout directory; freshness is measured against the local tracking ref.
    Missing or ambiguous evidence is returned as an explicit typed state.
    [include_repository_checkouts=false] returns [not_inspected] without
    inspecting directories, entering a sandbox or running Git. *)

(** Where a checkout's HEAD stands relative to the locally known
    [origin/<default_branch>] of its catalog repository. [Current] requires a
    target-ref reflog move or matching FETCH_HEAD observation within 900
    seconds. [Stale_ref] records the last local observation when older or
    unknown. Neither proves the remote's current HEAD.
    [Freshness_unavailable] carries a failed comparison or catalog probe. *)
type checkout_freshness =
  | Current of { target_ref : string; upstream_head : string; last_observed_at_unix : int; age_s : int }
  | Stale_ref of
      { target_ref : string
      ; upstream_head : string
      ; last_observed_at_unix : int option
      ; age_s : int option
      }
  | Ahead of { target_ref : string; upstream_head : string; ahead : int }
  | Behind of { target_ref : string; upstream_head : string; behind : int }
  | Diverged of
      { target_ref : string
      ; upstream_head : string
      ; ahead : int
      ; behind : int
      }
  | Freshness_unavailable of string

(** One checkout's freshness projection for the turn context. Read off the
    same per-checkout probe as {!repository_checkouts_json}, so the tool
    surface and the turn context can never disagree about the same checkout. *)
type freshness_row = {
  row_checkout_path : string;
      (** Playground-relative path — the cwd the keeper passes to its tools.
          Basenames collide across a playground; paths do not. *)
  row_branch : string option;  (** [None] when the branch probe failed. *)
  row_changed_files : int option;  (** [None] when the status probe failed. *)
  row_freshness : checkout_freshness;
}

(** One checkout's identity for a reader of its files. Unlike
    {!freshness_row} it carries no working-tree status: [git status] runs the
    repository's configured fsmonitor and can reach a promisor remote, so a
    verifier reading a producer's checkout does not run it. *)
type identity_row = {
  identity_checkout_path : string;
      (** Playground-relative path, as in {!freshness_row}. *)
  identity_branch : string option;
      (** [None] when the branch probe failed. A detached HEAD answers [Some "HEAD"]. *)
  identity_head : string option;  (** Full HEAD SHA; [None] when the probe failed. *)
  identity_freshness : checkout_freshness;
      (** Where HEAD stands against the local tracking ref, or why that is unknown.
          A path that is not the top of its own git repository is
          [Freshness_unavailable], with no branch and no HEAD. *)
}

val checkout_identity_rows :
  ?inspection_budget_sec:float ->
  config:Workspace.config ->
  Keeper_playground_checkouts.checkout list ->
  identity_row list
(** Measure checkouts that a host-side reader already discovered. Reads the
    local clone only: no fetch, no working-tree status. [?inspection_budget_sec]
    bounds the total git subprocess time across the list (default
    {!Repo_git.inspection_timeout_sec}). *)

val checkout_freshness_rows :
  ?inspection_budget_sec:float ->
  config:Workspace.config ->
  meta:keeper_meta ->
  unit ->
  (freshness_row list, Keeper_playground_checkouts.scan_error) result
(** Measure every discovered checkout for the turn-context freshness layer.
    [Ok []] means the playground holds no checkout; a failed scan is the
    typed [scan_error], not an empty list. [?inspection_budget_sec] bounds
    the total git subprocess time across all checkouts (default
    {!Repo_git.inspection_timeout_sec}). *)

module For_testing : sig
  val repository_checkouts_json_with_budget :
    inspection_budget_sec:float ->
    config:Workspace.config ->
    meta:keeper_meta ->
    Yojson.Safe.t

  val repository_checkouts_json_with_budget_after_discovery :
    before_git_inspection:(unit -> unit) ->
    inspection_budget_sec:float ->
    config:Workspace.config ->
    meta:keeper_meta ->
    Yojson.Safe.t
end

val kata_name_observation_json :
  config:Workspace.config -> meta:keeper_meta -> timeout_sec:float -> Yojson.Safe.t
(** A separate name-only runtime observation. It uses the turn probe's
    scrubbed context. If known host selectors differ or are unavailable, the
    name result is unavailable; matching them does not attest the binary,
    daemon, config file, or a later invocation. It does not establish ownership. *)

type kata_host_environment_alignment =
  | Kata_selectors_match
  | Kata_selectors_differ
  | Kata_selectors_unavailable
(** A comparison of known CLI selectors at one instant, not a daemon or
    configuration-file identity proof. *)

val live_status_json :
  ?include_preflight:bool ->
  ?preflight_override:Keeper_sandbox_runtime.docker_preflight option ->
  ?containers_override:(Keeper_sandbox_runtime.live_container list, string) result ->
  ?include_repository_checkouts:bool ->
  ?include_kata_name_observation:bool ->
  config:Workspace.config ->
  meta:keeper_meta ->
  timeout_sec:float ->
  verbose:bool ->
  unit ->
  Yojson.Safe.t
(** [preflight_override] lets a fleet caller reuse a single Docker
    preflight probe across many keepers; when set (even to [None]),
    the per-keeper render skips its own [docker_preflight] call.
    Pass [Some json] for the cached result, or [None] for "preflight
    was attempted but yielded nothing".  Without this override the
    render falls back to its own preflight invocation.

    [containers_override] lets a fleet caller reuse one base-path-scoped
    Docker listing and filter it by keeper in memory.  Without it the
    render performs its own keeper-scoped Docker listing.

    [include_repository_checkouts=false] skips Git checkout inspection for
    dashboard hot paths.

    [include_kata_name_observation=true] adds a separate, point-in-time
    name/runtime listing for Kata. It does not establish ownership and does
    not read a guest's logs or files. Its scoped-list comparison is from a
    different observation, not an atomic snapshot. The per-command timeout is
    not a deadline for the whole status request.

    A failed container inventory leaves [effective_mode] null and preserves
    the failure in [container_error]. A successful scoped inventory reports
    matching instances; an empty result does not prove a name is available.
    With a separate Kata name observation, [effective_mode] remains null:
    equal names in separate reads do not establish the same current guest.

    Apple microVM [resource_config.work_volume_discard_default] freshly reads
    the actual volume source and ext4 superblock under [timeout_sec] on every
    status request. It is [{state:"set"|"absent",error:null}] or
    [{state:"unreadable",error:string}]; other backends expose null. This
    read-only observation is never cached and never starts a helper. *)

module Kata_status_for_testing : sig
  val environment_alignment :
    ambient:string array -> cwd:string -> kata_host_environment_alignment

  val observe_name :
    run:(timeout_sec:float -> env:string array -> cwd:string -> argv:string list ->
         (Unix.process_status * string, unit) result) ->
    config:Workspace.config -> meta:keeper_meta -> ambient:string array -> cwd:string ->
    timeout_sec:float -> (string * Keeper_sandbox_microvm.kata_name_observation) option

  val observe_inventory :
    run:(execution_context:(string array * string) option ->
         config:Workspace.config -> meta:keeper_meta -> timeout_sec:float ->
         (Keeper_sandbox_runtime.live_container list, string) result) ->
    config:Workspace.config -> meta:keeper_meta -> ambient:string array -> cwd:string ->
    timeout_sec:float -> (Keeper_sandbox_runtime.live_container list, string) result

  val project :
    observation:Keeper_sandbox_microvm.kata_name_observation ->
    scoped_name_seen:bool option -> has_containers:bool ->
    initial_effective_mode:string option -> initial_why_no_container:string option ->
    string option * string option
end

type sandbox_log_backend =
  | Docker_logs
  | Micro_vm_logs of Keeper_microvm_backend.t
      (** The runtime the Keeper declared, so the log call reaches the CLI
          that holds the guest. Before #32837 this had no backend and read
          Apple's [container] for every microvm Keeper, which made a Keeper
          running correctly on [msb] surface as
          [Sandbox_logs_backend_failed]. The wire's [backend] field now
          carries the runtime's own spelling, so a new runtime is a value the
          reader has to accept as well as a constructor the compiler asks
          about. *)

type sandbox_log_source =
  | Local_backend of sandbox_log_backend
      (** The Keeper's tree sits on this host under a container runtime that
          keeps a stdio stream this server can read. *)
  | No_local_stream of string
      (** The Keeper's effective profile keeps no container on this host, so
          there is no stream to read. The payload is the operator-facing
          sentence saying where the logs are instead. This is a normal
          answer, not a failure. *)

type sandbox_logs_error =
  | Sandbox_logs_meta_read_failed of string
  | Sandbox_logs_keeper_not_found
  | Sandbox_logs_backend_failed of string
      (** The local log runtime could not be read, or its execution context
          could not be established before invoking it. A profile that keeps no
          local stream and a successful empty inventory remain [Ok] results. *)

val resolve_sandbox_log_target :
  config:Workspace.config ->
  keeper_name:string ->
  (sandbox_log_source * string, sandbox_logs_error) result
(** Resolve the selected Keeper's effective TOML-owned sandbox profile into a
    log source, paired with the canonical Keeper name. Durable metadata
    carries only a placeholder profile and must never choose the log backend.
    Every profile resolves to a source: a profile with no local container
    stream answers [No_local_stream] rather than an error. Returns only
    [Sandbox_logs_meta_read_failed] or [Sandbox_logs_keeper_not_found]. *)

val logs_json :
  config:Workspace.config ->
  keeper_name:string ->
  timeout_sec:float ->
  tail:int ->
  unit ->
  (Yojson.Safe.t, sandbox_logs_error) result
(** Answer where the selected Keeper's stdio logs are: the Docker or Apple
    Container stream when the profile keeps one on this host, and the
    sentence naming the endpoint when it does not. Container discovery
    remains label-scoped to [config.base_path] and the effective Keeper
    name.

    Kata inventory and log commands use the turn runner's scrubbed env and
    captured cwd. Their selector comparison is carried as
    [kata_host_environment_alignment]; it does not prove CLI, configuration,
    daemon identity, or stability across calls.

    Three success shapes, all under one constant key set ([keeper],
    [backend], [state], [reason], [reason_code], [tail], [instances],
    [kata_host_environment_alignment]): [state="available"]
    with a backend and one or more instances, [state="no_instance"] with a
    backend and none, and [state="no_local_stream"] with [backend] null,
    [instances] empty, [reason] carrying the existing sentence, and
    [reason_code="remote_ssh"] for the SSH endpoint. Other shapes use null.
    A caller separates the last two on [state], and again on whether
    [backend] is null. *)

module Sandbox_logs_for_testing : sig
  val collect :
    list_containers:(env:string array option -> cwd:string option ->
      backend:sandbox_log_backend -> config:Workspace.config -> keeper_name:string ->
      timeout_sec:float -> (Keeper_sandbox_runtime.live_container list, string) result) ->
    read_logs:(env:string array option -> cwd:string option -> timeout_sec:float ->
      argv:string list -> Unix.process_status * string * string) ->
    config:Workspace.config -> meta:keeper_meta -> backend:sandbox_log_backend ->
    ambient:string array -> cwd:string -> timeout_sec:float -> tail:int ->
    (Yojson.Safe.t, sandbox_logs_error) result
end
