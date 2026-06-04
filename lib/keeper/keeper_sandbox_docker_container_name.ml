(** Docker container naming + host-cwd → container-cwd translation
    for the keeper sandbox.

    [keeper_sandbox_container_name] — names the per-turn sandbox
    container using [masc-keeper-<safe_filename>-<pid>-<ms>-<seq>]
    so two concurrent keeper turns can never collide on a single
    container name even within the same process. The trailing [seq]
    is an Atomic counter that increments monotonically, eliminating
    the millisecond-resolution collision window that 64 concurrent
    keepers could trigger.

    [keeper_private_container_root] — thin alias to
    [Keeper_sandbox.container_root] returning the fixed
    per-keeper container-side mount point.

    [docker_private_workspace_cwd] — given a host_cwd absolute
    path, returns the corresponding container-side path. If
    host_cwd is *inside* the sandbox host root, the suffix is
    appended to container_root; otherwise the call falls back to
    container_root so the keeper still lands inside its sandbox.

    Verbatim extract from [Keeper_sandbox_docker]; all 3 functions
    are exposed by the parent .mli at lines 37, 40, 45. *)

let oneshot_container_counter : int Atomic.t = Atomic.make 0

let keeper_sandbox_container_name (meta : Keeper_meta_contract.keeper_meta) =
  let seq = Atomic.fetch_and_add oneshot_container_counter 1 in
  Printf.sprintf
    "masc-keeper-%s-%d-%d-%d"
    (Workspace_utils.safe_filename meta.name)
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))
    seq
;;

let keeper_private_container_root (meta : Keeper_meta_contract.keeper_meta) =
  Keeper_sandbox.container_root meta.name
;;

let docker_private_workspace_cwd
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      host_cwd
  =
  Keeper_sandbox.container_cwd_of_host
    (Keeper_sandbox.docker_mount_layout_of_meta ~config meta)
    ~host_cwd
;;
