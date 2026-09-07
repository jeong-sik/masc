(** Build identity for the running server process.

    Captures release version, git commit, start time, and uptime.
    [commit] is kept as a backwards-compatible field, but callers that
    need binary freshness must inspect [binary_commit] / [commit_source]
    rather than treating a runtime git probe as compile-time proof. *)

type t = {
  release_version : string;
  binary_version : string;
    (** Alias for [release_version], named explicitly for callers that
        compare the running executable against [repo_version]. *)
  repo_version : string option;
    (** Package version read from the runtime checkout's [dune-project],
        when available.  This is runtime repo truth, not binary truth. *)
  commit : string option;
    (** Backwards-compatible identity field.  Uses [binary_commit] when
        the build-time stamp is present, otherwise falls back to
        [repo_head_commit].  Inspect [commit_source] before using this as
        deploy proof. *)
  commit_source : string option;
    (** [Some "embedded"] when [commit] came from the build-time stamp,
        [Some "runtime_repo_head"] when it came from probing the current
        checkout, [None] when unknown. *)
  binary_commit : string option;
    (** Commit stamped into the binary at build time, when available.  This
        is the only commit field that operators should use as binary-build
        identity in this module. *)
  binary_commit_source : string option;
  source_fingerprint : string option;
    (** SHA-256 identity of the exact Dune link action and dependency bytes
        bound to this executable by a validated provenance sidecar. *)
  provenance_source : string;
    (** How [executable_sha256] below was obtained.

        ["launcher_verified"] when run-local.sh materialised the binary,
        hashed it, and re-checked that nothing moved before exec.
        ["self_observed"] when the running binary hashed its own path with
        no launcher involved.

        The two answer different questions -- "this is what the build
        produced" against "this is what is answering you" -- and a consumer
        that reads them alike is trusting a check nobody ran. *)
  executable_sha256 : string option;
    (** SHA-256 of the running executable. Read [provenance_source] to know
        whether the launcher verified it or the process hashed itself.
        Absent only when the executable could not be read. *)
  executable_provenance_path : string option;
  executable_provenance_sha256 : string option;
  binary_commit_unix_ts : float option;
  binary_commit_age_seconds : int option;
  repo_head_commit : string option;
    (** Current checkout HEAD probed at runtime from [repo_root], when
        available. A run-local provenance binding projects its launch-time
        source HEAD so this field and [repo_root] share one authority. Useful
        operational context, but not proof without the provenance fields. *)
  repo_head_commit_source : string option;
  repo_head_commit_unix_ts : float option;
  repo_head_commit_age_seconds : int option;
  executable_path : string;
    (** Absolute best-effort path to the running executable.  Exposed on
        [/health] so operators can distinguish a root-lane binary from a
        worktree binary. *)
  executable_dir : string;
    (** Directory containing [executable_path]. *)
  executable_in_worktree : bool;
    (** Whether [executable_path] resolves inside a [.worktrees/] directory —
        a working tree's build serving live traffic. Judged by the workspace
        path convention (worktrees live under [<repo>/.worktrees/]); surfaces
        warn on it so an old-generation worktree binary on the live port is
        seen, not deduced. *)
  repo_root : string option;
    (** Git root resolved from the executable path first, then cwd. *)
  runtime_instance_id : string;
    (** Process-unique UUIDv7 minted once when this module initializes. Unlike
        [started_at], this remains collision-free across same-second restarts
        of the same binary and is the server-process identity for evidence. *)
  started_at : string;
  uptime_seconds : int;
}

val path_is_in_worktree : string -> bool
(** Whether [path] contains a [.worktrees/] segment — the workspace
    convention for worktree checkouts. The judgement behind
    [executable_in_worktree], exposed so the convention is pinned by test
    rather than re-derived by readers. *)

val to_yojson : t -> Yojson.Safe.t
(** PPX-generated serializer. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** PPX-generated deserializer. *)

val current : unit -> t
(** Snapshot of the running build identity with current uptime. *)

type executable_provenance = {
  binary_commit : string;
  build_input_fingerprint : string;
  source_root : string;
  source_root_device : int;
  source_root_inode : int;
  dashboard_assets : dashboard_assets_provenance option;
  executable_sha256 : string;
  executable_device : int;
  executable_inode : int;
}

and dashboard_asset_entry = {
  relative_path : string;
  size : int;
  sha256 : string;
}

and dashboard_assets_provenance = {
  source_root : string;
  snapshot_root : string;
  snapshot_device : int;
  snapshot_inode : int;
  tree_sha256 : string;
  build_source_commit : string;
  build_head_tree : string;
  build_index_tree : string;
  build_input_sha256 : string;
  build_input_file_count : int;
  build_input_matches_head : bool;
  build_lock_sha256 : string;
  build_mode : string;
  build_environment_path : string;
  build_environment_path_identity_sha256 : string;
  build_environment_path_executable_sha256 : string;
  build_environment_path_executable_count : int;
  build_environment_profile_sha256 : string;
  build_producer : string;
  build_node_executable : string;
  build_node_executable_sha256 : string;
  build_node_version : string;
  build_node_platform : string;
  build_node_arch : string;
  build_package_manager_kind : string;
  build_package_manager_executable : string;
  build_package_manager_executable_sha256 : string;
  build_pnpm_version : string;
  build_vite_version : string;
  build_installed_graph_metadata_sha256 : string;
  build_installed_graph_metadata_count : int;
  files : dashboard_asset_entry list;
}

type source_root_invalid_reason =
  | Source_root_unreadable
  | Source_root_not_canonical
  | Source_root_not_directory
  | Source_root_owner_differs
  | Source_root_device_differs
  | Source_root_inode_differs

type launch_source_root_state =
  | Unbound
  | Bound_valid of string
  | Bound_invalid of source_root_invalid_reason

type dashboard_asset_invalid_reason =
  | Dashboard_source_root_invalid of source_root_invalid_reason
  | Dashboard_snapshot_unreadable
  | Dashboard_snapshot_not_canonical
  | Dashboard_snapshot_metadata_differs
  | Dashboard_asset_metadata_differs

type dashboard_asset_resolution =
  | Dashboard_assets_unbound
  | Dashboard_assets_invalid of dashboard_asset_invalid_reason
  | Dashboard_assets_unavailable
  | Dashboard_asset_not_manifested
  | Dashboard_asset_bound of {
      path : string;
      launch_source_root : string;
      launch_source_device : int;
      launch_source_inode : int;
      expected_size : int;
      expected_sha256 : string;
      tree_sha256 : string;
      snapshot_root : string;
      snapshot_device : int;
      snapshot_inode : int;
      file_count : int;
      build_source_commit : string;
      build_head_tree : string;
      build_index_tree : string;
      build_input_sha256 : string;
      build_input_file_count : int;
      build_input_matches_head : bool;
      build_lock_sha256 : string;
      build_mode : string;
      build_environment_path : string;
      build_environment_path_identity_sha256 : string;
      build_environment_path_executable_sha256 : string;
      build_environment_path_executable_count : int;
      build_environment_profile_sha256 : string;
      build_producer : string;
      build_node_executable : string;
      build_node_executable_sha256 : string;
      build_node_version : string;
      build_node_platform : string;
      build_node_arch : string;
      build_package_manager_kind : string;
      build_package_manager_executable : string;
      build_package_manager_executable_sha256 : string;
      build_pnpm_version : string;
      build_vite_version : string;
      build_installed_graph_metadata_sha256 : string;
      build_installed_graph_metadata_count : int;
    }


val parse_executable_provenance :
  expected_binary_commit:string ->
  expected_executable_sha256:string ->
  expected_executable_device:int ->
  expected_executable_inode:int ->
  string ->
  (executable_provenance, string) result
(** Decode the exact sidecar bound to a content-addressed local executable.
    The sidecar is accepted only when its commit, source-root identity,
    executable digest, device, and inode match the independently observed
    values. *)

val bind_executable_provenance :
  path:string -> sha256:string -> device:int -> inode:int -> (unit, string) result
(** Bind a content-addressed provenance sidecar to this process exactly once.
    The supplied digest, embedded commit, source-root device/inode, and running
    executable bytes are validated before the immutable value becomes visible
    through [current]. *)

val repo_root : unit -> string option
(** Exact source root from the immutable run-local provenance binding when
    present. General launches fall back to probing the executable directory,
    then the process cwd. This is separate from the MASC base path. *)

val launch_source_root_state : unit -> launch_source_root_state
(** Revalidate the bound source pathname/device/inode on every observation.
    [Bound_invalid] never authorizes a fallback to cwd, environment, or another
    checkout. *)

val resolve_dashboard_asset : string -> dashboard_asset_resolution
(** Resolve one dashboard-relative path against the immutable content-addressed
    launch snapshot. General launches return [Dashboard_assets_unbound]. Bound
    launches fail closed on source/snapshot replacement and return the exact
    expected byte identity for manifested files. *)

val dashboard_manifest_identity : unit -> dashboard_assets_provenance option
(** Frozen launch manifest identity without current-path validity inference.
    This remains inspectable after source/snapshot replacement; callers must
    pair it with [resolve_dashboard_asset] for current serving validity. *)


val resolve_commit :
  embedded:string option ->
  probe:(unit -> string option) ->
  string option
(** Resolve commit hash: build-time embedded stamp first, then the probe
    function. Exposed for testing. *)

type commit_resolution = {
  commit : string option;
  commit_source : string option;
  binary_commit : string option;
  binary_commit_source : string option;
  repo_head_commit : string option;
  repo_head_commit_source : string option;
}

val resolve_commit_details :
  embedded:string option ->
  probe:(unit -> string option) ->
  commit_resolution
(** Resolve the compatibility [commit] plus the source-specific binary and
    runtime repo-head fields. [binary_commit] carries the build-time
    embedded stamp (source ["embedded"]); the repo-head probe never
    populates it because the source tree next to the process moves
    independently of the binary. Exposed for testing. *)

val pick_repo_candidates :
  exe_dir:string -> cwd:string -> string list
(** Ordered list of directories to probe for a git repo. Places [exe_dir]
    before [cwd] so the binary's own source tree wins when the process is
    launched from an unrelated cwd. Returns a single entry when both
    arguments are equal. Pure — exposed for unit testing. *)

val executable_candidate :
  cwd:string -> executable_name:string -> argv0:string -> string
(** The path to try for the running binary.

    A relative [argv0] is not relative to [cwd]: POSIX resolves a name with no
    slash through [PATH], so joining "masc" to a checkout at
    [.../yousleepwhen/masc] built [.../masc/masc], realpath failed, and
    [executable_dir] fell back to [cwd] -- which makes {!pick_repo_candidates}
    a single entry and hands the repo probe to whatever directory the process
    was started from.

    Prefers [executable_name] ([Sys.executable_name], resolved by the runtime
    at start-up), joins to [cwd] only when a name carries a directory of its
    own, and answers the bare name rather than a wrong path when neither can
    be resolved here. Pure — exposed for unit testing. *)

val parse_commit_unix_ts_output : string -> float option
(** Parse raw [git log -1 --format=%ct] output. Pure — exposed for unit
    testing. *)

val parse_dune_project_version : string -> string option
(** Parse the top-level [(version ...)] field from [dune-project] contents. *)

module For_testing : sig
  val validate_executable_provenance_binding :
    path:string ->
    expected_sidecar_sha256:string ->
    expected_sidecar_device:int ->
    expected_sidecar_inode:int ->
    expected_binary_commit:string ->
    expected_executable_sha256:string ->
    expected_executable_device:int ->
    expected_executable_inode:int ->
    (executable_provenance, string) result
  val observe_probe_failure : site:string -> exn -> unit
  val probe_commit_unix_ts : string option -> float option
  val runtime_cwd : unit -> string
  val resolve_dashboard_asset :
    executable_provenance -> string -> dashboard_asset_resolution
end
