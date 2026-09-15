(** Docker container naming + host-cwd → container-cwd translation
    for the keeper sandbox.

    [keeper_sandbox_container_name] — names the per-turn sandbox
    container from this process's pid, the wall-clock millisecond and
    an Atomic counter, so two concurrent keeper turns can never collide
    on a single container name even within the same process. The
    counter increments monotonically, eliminating the
    millisecond-resolution collision window that 64 concurrent keepers
    could trigger. The spelling is {!Keeper_sandbox_container_name}'s.

    [keeper_private_container_root] — thin alias to
    [Keeper_sandbox.container_root] returning the fixed
    per-keeper container-side mount point.

    [docker_private_workspace_cwd] — given a host_cwd absolute
    path, returns the corresponding container-side path. If
    host_cwd is *inside* the sandbox host root, the suffix is
    appended to container_root; otherwise the call falls back to
    container_root so the keeper still lands inside its sandbox. *)

let oneshot_container_counter : int Atomic.t = Atomic.make 0

let keeper_sandbox_container_name (meta : Keeper_meta_contract.keeper_meta) =
  let seq = Atomic.fetch_and_add oneshot_container_counter 1 in
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Docker_oneshot
       { keeper_name = meta.name
         (* DET-OK: pid and wall-clock ms make a one-shot name unique per run. *)
       ; pid = Unix.getpid ()
       ; started_ms = int_of_float (Unix.gettimeofday () *. 1000.0)
       ; seq
       })
;;

let keeper_private_container_root (meta : Keeper_meta_contract.keeper_meta) =
  Keeper_sandbox.container_root meta.name
;;

let docker_private_workspace_cwd
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
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
