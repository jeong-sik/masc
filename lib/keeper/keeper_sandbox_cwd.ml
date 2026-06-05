(** Keeper_sandbox_cwd — unified playground root interface.

    Phase B (task-658): consolidates five ad-hoc implementations into one
    canonical module. See .mli for full contract. *)

(** {1 Internal helpers} *)

let normalize p =
  Keeper_alerting_path.normalize_path_for_check_stripped p

(** {1 Resolved type} *)

type playground_resolved = {
  host_abs : string;
  container_abs : string option;
}

(** {1 Core: playground_root_abs}

    Replaces [Keeper_sandbox_containment.playground_root_abs],
    [Keeper_sandbox_read_backend.host_playground_root],
    and [Keeper_tool_execute_path.playground_root]. *)

let playground_root_abs ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) =
  Keeper_sandbox.host_root_abs_of_meta ~config meta |> normalize

(** {1 resolve_playground} *)

let resolve_playground ~config ~meta =
  let host_abs = playground_root_abs ~config ~meta in
  let container_abs =
    match meta.Keeper_meta_contract.sandbox_profile with
    | Keeper_types_profile_sandbox.Docker ->
      Some (Keeper_sandbox.container_root meta.Keeper_meta_contract.name)
    | Keeper_types_profile_sandbox.Local ->
      None
  in
  { host_abs; container_abs }

(** {1 container_path_of_host}

    Translates a host absolute path into its container equivalent.
    For Docker profile, strips the host playground prefix and prepends
    the container root. For Local profile it's a no-op. *)

let container_path_of_host ~config ~meta ~host_path =
  let playground = playground_root_abs ~config ~meta in
  let host_norm = normalize host_path in
  if not (String.starts_with ~prefix:playground host_norm) then
    invalid_arg (Printf.sprintf
      "container_path_of_host: %s is outside playground %s" host_path playground);
  match meta.Keeper_meta_contract.sandbox_profile with
  | Keeper_types_profile_sandbox.Docker ->
    let suffix = String.sub host_norm (String.length playground)
        (String.length host_norm - String.length playground) in
    Keeper_sandbox.container_root meta.Keeper_meta_contract.name ^ suffix
  | Keeper_types_profile_sandbox.Local ->
    host_norm

(** {1 host_path_of_container}

    Reverse translation: container path → host path. *)

let host_path_of_container ~config ~meta ~container_path =
  match meta.Keeper_meta_contract.sandbox_profile with
  | Keeper_types_profile_sandbox.Local ->
    normalize container_path
  | Keeper_types_profile_sandbox.Docker ->
    let container_root = Keeper_sandbox.container_root meta.Keeper_meta_contract.name in
    let cont_norm = normalize container_path in
    if not (String.starts_with ~prefix:container_root cont_norm) then
      invalid_arg (Printf.sprintf
        "host_path_of_container: %s is outside container root %s"
        container_path container_root);
    let suffix = String.sub cont_norm (String.length container_root)
        (String.length cont_norm - String.length container_root) in
    let playground = playground_root_abs ~config ~meta in
    playground ^ suffix

(** {1 Derived: repos_dir} *)

let repos_dir ~config ~meta =
  Filename.concat (playground_root_abs ~config ~meta) "repos"

(** {1 Derived: worktree_dir} *)

let worktree_dir ~config ~meta ~repo ~branch =
  Filename.concat
    (Filename.concat (repos_dir ~config ~meta) repo)
    (Filename.concat ".worktrees" branch)