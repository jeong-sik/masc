(** Docker container naming + host-cwd → container-cwd translation
    for the keeper sandbox.

    [keeper_sandbox_container_name] — names the per-turn sandbox
    container using [masc-keeper-<safe_filename>-<pid>-<ms>] so two
    concurrent keeper turns can never collide on a single container
    name even within the same process.

    [keeper_private_container_root] — thin alias to
    [Keeper_sandbox.container_root] returning the fixed
    per-keeper container-side mount point.

    [docker_private_workspace_cwd] — given a host_cwd absolute
    path, returns the corresponding container-side path. If
    host_cwd is *inside* the sandbox host root, the suffix is
    appended to container_root; otherwise the call falls back to
    container_root so the keeper still lands inside its sandbox.

    Verbatim extract from [Keeper_shell_docker]; all 3 functions
    are exposed by the parent .mli at lines 37, 40, 45. *)

let keeper_sandbox_container_name (meta : Keeper_types.keeper_meta) =
  Printf.sprintf
    "masc-keeper-%s-%d-%d"
    (Coord_utils.safe_filename meta.name)
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))
;;

let keeper_private_container_root (meta : Keeper_types.keeper_meta) =
  Keeper_sandbox.container_root meta.name
;;

let docker_private_workspace_cwd
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      host_cwd
  =
  let normalize_path_for_containment path =
    Keeper_alerting_path.normalize_path_for_check_stripped path
  in
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta |> normalize_path_for_containment
  in
  let container_root = keeper_private_container_root meta in
  let host_cwd = normalize_path_for_containment host_cwd in
  if host_cwd = host_root
  then container_root
  else if String.starts_with ~prefix:(host_root ^ "/") host_cwd
  then (
    let suffix =
      String.sub
        host_cwd
        (String.length host_root + 1)
        (String.length host_cwd - String.length host_root - 1)
    in
    Filename.concat container_root suffix)
  else container_root
;;
