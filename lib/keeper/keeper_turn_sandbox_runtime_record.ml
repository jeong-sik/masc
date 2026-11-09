open Keeper_meta_contract
open Keeper_types_profile
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_boot

type state =
  | Not_started
  | Running of { container_name : string }

type t =
  { config : Workspace.config
  ; meta : keeper_meta
  ; image : (string, Keeper_sandbox_image_resolver.error) result
      (** Resolved once for the turn that made this runtime, so every start in
          the turn uses the same build even if a promote lands meanwhile. *)
  ; raw_host_root : string
  ; host_root : string
  ; container_root : string
  ; uid : int
  ; gid : int
  ; network_mode : network_mode
  ; state : state Atomic.t
  ; github_identity_snapshots : github_identity_snapshots Atomic.t
  }

let get_state t = Atomic.get t.state
let set_state t state = Atomic.set t.state state

let rec update_github_identity_snapshots t update =
  let current = Atomic.get t.github_identity_snapshots in
  let updated = update current in
  if not (Atomic.compare_and_set t.github_identity_snapshots current updated)
  then update_github_identity_snapshots t update
;;

let bind_github_identity_snapshot t snapshot =
  update_github_identity_snapshots t (fun snapshots ->
    { snapshots with current = Some snapshot })
;;

let forget_github_identity_snapshots t =
  let (_ : github_identity_snapshots) =
    Atomic.exchange t.github_identity_snapshots no_github_identity_snapshots
  in
  ()
;;

(* Microvm only: the boot-time identity snapshot a guest holds for its
   lifetime. The persistent Docker container mounts the stable config
   directory instead and has no snapshots. *)
let github_identity_secret_files t =
  let snapshots = Atomic.get t.github_identity_snapshots in
  let snapshots =
    match snapshots.current with
    | None -> snapshots.retired
    | Some current -> current :: snapshots.retired
  in
  List.map (fun snapshot -> Filename.concat (identity_host_dir snapshot) "hosts.yml") snapshots
;;

let host_root t = t.host_root
let normalize_path path = Keeper_alerting_path.normalize_path_for_check_stripped path
let container_root_of_meta (meta : keeper_meta) =
  Keeper_sandbox.container_root meta.name
  |> Keeper_alerting_path.strip_trailing_slashes
;;

let create
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~image
      ?(network_mode = Network_none)
      ()
  =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  { config
  ; meta
  ; image
  ; raw_host_root
  ; host_root = raw_host_root |> normalize_path
  ; container_root = container_root_of_meta meta
  ; uid = Unix.getuid ()
  ; gid = Unix.getgid ()
  ; network_mode
  ; state = Atomic.make Not_started
  ; github_identity_snapshots = Atomic.make no_github_identity_snapshots
  }
;;

(* A Keeper whose image cannot be resolved starts no container. The catalog's
   reason carries the commands that fix it. *)
let image_unresolved_message error =
  "sandbox_image_unresolved: " ^ Keeper_sandbox_image_resolver.error_to_string error
;;

let image t = t.image

(* One container per keeper configuration, not per turn: the name is stable, an already
   running container is adopted instead of created (amortising the container
   start and image preflight across turns), and turn cleanup leaves
   it running. State accumulated inside the container between turns belongs
   to the same keeper. Teardown is [teardown_keeper_sandbox_by_name], which
   shutdown finalization runs after the registry unregister succeeds -- the
   one point that knows the keeper is gone for good rather than between
   turns.

   The network mode is part of the name because it is part of [docker run]:
   a keeper whose network config changed must not adopt a container wired to
   the old network. The resolved image reference is also part of the
   coordinate: a newly promoted build must not adopt the old image. This
   distinguishes references, not mutations behind the same tag. Existing
   turn runtimes keep their cached container until that turn ends. Teardown
   lists by label rather than by name and takes all builds that remain: a new
   turn cannot know whether another turn still uses an older container. *)
let docker_container_name_for_image (t : t) ~image =
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Docker_persistent
       { keeper_name = t.meta.name
       ; network_mode = t.network_mode
       ; base_path = t.config.base_path
       ; image
       })
  |> Keeper_sandbox_container_name.to_string
;;

module For_testing = struct
  let minimal_image = "masc-test-minimal:image"

  let create_minimal ~config ~meta ~state =
    { config
    ; meta
    ; image = Ok minimal_image
    ; raw_host_root = ""
    ; host_root = ""
    ; container_root = ""
    ; uid = 0
    ; gid = 0
    ; network_mode = Network_none
    ; state = Atomic.make state
    ; github_identity_snapshots = Atomic.make no_github_identity_snapshots
    }
  ;;

  let get_state = get_state
  let set_state = set_state

  let keeper_docker_container_name t =
    match t.image with
    | Ok image -> docker_container_name_for_image t ~image
    | Error error -> invalid_arg (image_unresolved_message error)
  let policy_route_holds = policy_route_holds
  let microvm_adoption = microvm_adoption
  let microvm_boot_nameserver = microvm_boot_nameserver
end
