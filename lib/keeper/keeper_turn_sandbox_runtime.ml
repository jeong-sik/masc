open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type state =
  | Not_started
  | Running of { container_name : string }

type process_github_identity_snapshot =
  { args : string list
  ; host_dir : string
  ; revision : string
  ; cleanup : unit -> unit
  }

type github_identity_snapshot =
  | Process_identity of process_github_identity_snapshot
  | Guest_identity of Keeper_microvm_github_identity.snapshot

let identity_host_dir = function
  | Process_identity snapshot -> snapshot.host_dir
  | Guest_identity snapshot -> Keeper_microvm_github_identity.path snapshot

let identity_revision = function
  | Process_identity snapshot -> snapshot.revision
  | Guest_identity snapshot -> Keeper_microvm_github_identity.revision snapshot

type github_identity_snapshots =
  { current : github_identity_snapshot option
  ; retired : github_identity_snapshot list
  }

let no_github_identity_snapshots = { current = None; retired = [] }

(* Backends whose inspect cannot establish a full boot identity retain their
   process-owned snapshots. Apple credentials belong to its durable guest
   store and are never registered for turn/process cleanup. *)
let microvm_identity_snapshots :
  (string * process_github_identity_snapshot) list Atomic.t
  =
  Atomic.make []
;;

(* A Keeper's guest names and volumes share lifecycle ownership. Different
   Keepers must not wait behind an unrelated slow container CLI or boot.
   Inventory maintenance still excludes all owners from listing to deletion,
   preserving the stable-name adoption boundary. *)
let microvm_lifecycle = Keeper_microvm_lifecycle.create ()

let with_microvm_lifecycle_lock ~keeper_name ~operation f =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> f ()
  | Fs_compat.Eio_fiber ->
    let requested_at = Time_compat.now () in
    Keeper_microvm_lifecycle.with_keeper microvm_lifecycle ~keeper_name (fun () ->
      Log.Keeper.debug "microvm lifecycle admitted keeper=%s operation=%s wait_ms=%.3f"
        keeper_name operation ((Time_compat.now () -. requested_at) *. 1000.0);
      f ())
;;

let with_microvm_inventory_lock f =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> f ()
  | Fs_compat.Eio_fiber -> Keeper_microvm_lifecycle.with_inventory microvm_lifecycle f
;;

let sweep_process_bound_microvm_guests
      ~base_path ~command_available ~timeout_sec ~is_pid_alive ~run_argv =
  Keeper_sandbox_microvm.sweep_abandoned_guests ~base_path
    ~command_available:(fun command ->
      not (String.equal command (Keeper_microvm_backend.cli_name Keeper_microvm_backend.Apple_container))
      && command_available command)
    ~timeout_sec ~is_pid_alive ~run_argv
;;

let microvm_identity_snapshot container_name =
  Atomic.get microvm_identity_snapshots |> List.assoc_opt container_name
;;

let rec claim_microvm_identity_snapshot container_name snapshot =
  let current = Atomic.get microvm_identity_snapshots in
  match List.assoc_opt container_name current with
  | Some existing -> `Existing existing
  | None ->
    if Atomic.compare_and_set
         microvm_identity_snapshots
         current
         ((container_name, snapshot) :: current)
    then `Claimed
    else claim_microvm_identity_snapshot container_name snapshot
;;

let rec take_microvm_identity_snapshot_if container_name expected =
  let current = Atomic.get microvm_identity_snapshots in
  match List.assoc_opt container_name current with
  | None -> None
  | Some snapshot when Option.for_all (fun value -> value == snapshot) expected ->
    let updated = List.remove_assoc container_name current in
    if Atomic.compare_and_set microvm_identity_snapshots current updated
    then Some snapshot
    else take_microvm_identity_snapshot_if container_name expected
  | Some _ -> None
;;

let release_registered_microvm_identity ?expected container_name =
  match take_microvm_identity_snapshot_if container_name expected with
  | None -> ()
  | Some snapshot -> snapshot.cleanup ()
;;

(* Guests whose keeper root on the work volume this server process has made.
   The volume outlives the guest, so the [mkdir] is paid once per guest per
   process, at boot. A guest whose boot could not make the root and could
   not be taken down either is still running and still registered, so the
   next start adopts it: it stays out of this set, and the endpoint request
   makes the root before handing the guest out rather than handing out a
   guest every call fails in. *)
type microvm_build_links_state =
  | Build_links_not_prepared
  | Build_links_effect_unverified
  | Build_links_prepared

type microvm_work_root_ready =
  { container_name : string
  ; generation : unit ref
  ; build_links_state : microvm_build_links_state
  }

(* A fresh generation prevents an in-flight link scan from marking a guest
   ready after its root was forgotten or replaced in this process. *)
let microvm_work_roots_ready : microvm_work_root_ready list Atomic.t = Atomic.make []

let microvm_work_root_entry container_name =
  Atomic.get microvm_work_roots_ready
  |> List.find_opt (fun entry -> String.equal entry.container_name container_name)
;;

let microvm_work_root_ready container_name =
  Option.is_some (microvm_work_root_entry container_name)
;;

let rec mark_microvm_work_root_ready container_name =
  let current = Atomic.get microvm_work_roots_ready in
  if List.exists (fun entry -> String.equal entry.container_name container_name) current
  then ()
  else if not (Atomic.compare_and_set microvm_work_roots_ready current
      ({ container_name; generation = ref (); build_links_state = Build_links_not_prepared } :: current))
  then mark_microvm_work_root_ready container_name
;;

let rec set_microvm_build_links_state container_name generation ~expected state =
  let current = Atomic.get microvm_work_roots_ready in
  match List.find_opt (fun entry -> String.equal entry.container_name container_name) current with
  | Some entry when entry.generation == generation && entry.build_links_state = expected ->
    let updated = List.map (fun candidate ->
      if candidate == entry then { candidate with build_links_state = state } else candidate) current in
    if not (Atomic.compare_and_set microvm_work_roots_ready current updated)
    then set_microvm_build_links_state container_name generation ~expected state
    else true
  | Some _ | None -> false
;;

let rec forget_microvm_work_root container_name =
  let current = Atomic.get microvm_work_roots_ready in
  let updated = List.filter (fun entry -> not (String.equal entry.container_name container_name)) current in
  if not (Atomic.compare_and_set microvm_work_roots_ready current updated)
  then forget_microvm_work_root container_name
;;

(* Backends without authoritative complete boot facts use a process-owned
   boot record alongside their process-owned credential capability. Apple
   instead compares actual inspect facts and its durable guest snapshot. *)
type microvm_boot =
  { policy_port : int option
  ; image : string
  ; guest_size : Keeper_microvm_guest_size.t
  }

let microvm_boots : (string * microvm_boot) list Atomic.t = Atomic.make []

let microvm_boot container_name =
  Atomic.get microvm_boots |> List.assoc_opt container_name
;;

let rec record_microvm_boot container_name boot =
  let current = Atomic.get microvm_boots in
  let updated = (container_name, boot) :: List.remove_assoc container_name current in
  if not (Atomic.compare_and_set microvm_boots current updated)
  then record_microvm_boot container_name boot
;;

let rec forget_microvm_boot container_name =
  let current = Atomic.get microvm_boots in
  let updated = List.remove_assoc container_name current in
  if not (Atomic.compare_and_set microvm_boots current updated)
  then forget_microvm_boot container_name
;;

(* Whether an adoptable policy guest still points at a live listener.

   Only [Network_policy] guests carry a proxy address, so every other mode
   answers true: there is no route to go stale. *)
let policy_route_holds ~network_mode ~booted_port ~bound_port =
  match (network_mode : Keeper_types_profile_sandbox.network_mode) with
  | Network_none | Network_inherit -> true
  | Network_policy ->
    (match booted_port, bound_port with
     | Some booted, Some bound -> booted = bound
     (* No record means this process did not boot it, and no bound port means
        there is nothing to point at. Neither is adoptable. *)
     | None, _ | _, None -> false)
;;

type microvm_replacement_reason =
  | Boot_not_recorded
  | Image_changed of
      { booted : string
      ; target : string
      }
  | Memory_changed of
      { booted : Keeper_microvm_guest_size.memory
      ; target : Keeper_microvm_guest_size.memory
      }
  | Cpus_changed of
      { booted : Keeper_microvm_guest_size.cpus
      ; target : Keeper_microvm_guest_size.cpus
      }
  | Policy_route_stale of
      { booted_port : int option
      ; bound_port : int option
      }

type microvm_adoption =
  | Adopt_running_guest
  | Replace_running_guest of microvm_replacement_reason list
      (** Never empty: every reason the guest may not be adopted. *)

(* A running guest whose identity snapshot this process holds may be adopted
   when it was booted with what the keeper asks for now. Every difference is
   named, not only the first, so the log line that replaces a guest says all
   of what changed. *)
let microvm_adoption
      ~booted
      ~image
      ~(guest_size : Keeper_microvm_guest_size.t)
      ~network_mode
      ~bound_port
  =
  match booted with
  | None -> Replace_running_guest [ Boot_not_recorded ]
  | Some (booted : microvm_boot) ->
    let differs changed reason = if changed then Some reason else None in
    let booted_size = booted.guest_size in
    let reasons =
      List.filter_map
        Fun.id
        [ differs
            (not (String.equal booted.image image))
            (Image_changed { booted = booted.image; target = image })
        ; differs
            (not
               (Int.equal
                  (Keeper_microvm_guest_size.memory_mib booted_size.memory)
                  (Keeper_microvm_guest_size.memory_mib guest_size.memory)))
            (Memory_changed { booted = booted_size.memory; target = guest_size.memory })
        ; differs
            (not
               (Int.equal
                  (Keeper_microvm_guest_size.cpus_count booted_size.cpus)
                  (Keeper_microvm_guest_size.cpus_count guest_size.cpus)))
            (Cpus_changed { booted = booted_size.cpus; target = guest_size.cpus })
        ; differs
            (not
               (policy_route_holds
                  ~network_mode
                  ~booted_port:booted.policy_port
                  ~bound_port))
            (Policy_route_stale { booted_port = booted.policy_port; bound_port })
        ]
    in
    (match reasons with
     | [] -> Adopt_running_guest
     | _ :: _ -> Replace_running_guest reasons)
;;

let microvm_replacement_reason_to_string reason =
  let port = Option.fold ~none:"none" ~some:string_of_int in
  match reason with
  | Boot_not_recorded -> "this process has no record of booting it"
  | Image_changed { booted; target } -> Printf.sprintf "image %s -> %s" booted target
  | Memory_changed { booted; target } ->
    Printf.sprintf
      "memory %s -> %s"
      (Keeper_microvm_guest_size.memory_argv booted)
      (Keeper_microvm_guest_size.memory_argv target)
  | Cpus_changed { booted; target } ->
    Printf.sprintf
      "cpus %d -> %d"
      (Keeper_microvm_guest_size.cpus_count booted)
      (Keeper_microvm_guest_size.cpus_count target)
  | Policy_route_stale { booted_port; bound_port } ->
    Printf.sprintf "policy proxy port %s -> %s" (port booted_port) (port bound_port)
;;

(* The nameserver a guest is booted with: the one the workspace named, else the
   host's. Only the default network hands one, on a backend that spells
   [--dns]. [Network_none] has nothing to resolve on, [Network_policy] boots
   with [--no-dns] so the egress proxy is the only resolver, and Microsandbox
   spells its own [--dns-nameserver] and refuses the default network in
   [network_args_for]: asking there would refuse boots that never use one, or
   put an unrelated refusal in front of msb's own.

   The start reads it once it has decided to boot, and before anything is
   stopped or deleted for that boot. A refusal after the running guest was
   deleted and its work volume trimmed would cost the keeper a guest for
   nothing. A start that adopts never reads it, so a host that joins another
   network does not refuse a guest that resolves. *)
let microvm_boot_nameserver ~backend ~network_mode =
  match (network_mode : Keeper_types_profile_sandbox.network_mode) with
  | Keeper_types_profile_sandbox.Network_none
  | Keeper_types_profile_sandbox.Network_policy -> Ok None
  | Keeper_types_profile_sandbox.Network_inherit ->
    (match (backend : Keeper_microvm_backend.t) with
     | Keeper_microvm_backend.Microsandbox -> Ok None
     | Keeper_microvm_backend.Apple_container | Keeper_microvm_backend.Nerdctl_kata ->
       Result.map Option.some (Env_config_sandbox.Runtime.microvm_dns ()))
;;

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


let container_path_of_host (t : t) ~host_path =
  let host_norm = normalize_path host_path in
  if host_norm = t.host_root
  then Ok t.container_root
  else if String.starts_with ~prefix:(t.host_root ^ "/") host_norm
  then (
    let suffix =
      String.sub
        host_norm
        (String.length t.host_root + 1)
        (String.length host_norm - String.length t.host_root - 1)
    in
    Ok (Filename.concat t.container_root suffix))
  else
    Error
      (Printf.sprintf
         "container_path_of_host: %s is not inside playground %s"
         host_norm
         t.host_root)
;;

(* Previously listed [<host_root>/repos/*] and swallowed every failure into an
   empty list, which made "no checkout", "no repos directory" and "could not
   read" indistinguishable. A cwd that cannot be mapped is silently redirected
   to the container root, so the reason has to reach the log. *)
let discovered_checkouts (t : t) =
  match Keeper_playground_checkouts.discover ~root:t.host_root with
  | Ok (Keeper_playground_checkouts.Complete checkouts) -> checkouts
  | Ok (Keeper_playground_checkouts.Partial { found; limit }) ->
    Log.Keeper.warn
      "playground checkout scan incomplete keeper=%s root=%s limit=%s"
      t.meta.name
      t.host_root
      (Keeper_playground_checkouts.limit_to_string limit);
    found
  | Error error ->
    Log.Keeper.warn
      "playground checkout scan failed keeper=%s root=%s error=%s"
      t.meta.name
      t.host_root
      (Keeper_playground_checkouts.scan_error_to_string error);
    []
;;

let skip_worktree_prefix = function
  | ".worktrees" :: _branch :: rest -> rest
  | "./.worktrees" :: _branch :: rest -> rest
  | other -> other

type cwd_match =
  | Matched of Keeper_playground_checkouts.checkout * string
  | Ambiguous_segment of string * Keeper_playground_checkouts.checkout list
  | No_match

(* Once the layout is free, two checkouts can share a basename (a keeper
   holding both [repos/masc] and [.masc/repos/masc]). The previous [List.mem]
   answered such a case by sort order, i.e. arbitrarily. *)
let find_checkout_and_suffix ~checkouts ~host_cwd =
  let rec find = function
    | [] -> No_match
    | head :: tail ->
      (match
         List.filter
           (fun (c : Keeper_playground_checkouts.checkout) ->
              String.equal c.name head)
           checkouts
       with
       | [ checkout ] ->
         Matched (checkout, String.concat "/" (skip_worktree_prefix tail))
       | [] -> find tail
       | many -> Ambiguous_segment (head, many))
  in
  find (String.split_on_char '/' host_cwd)

let container_cwd_of_host (t : t) ~host_cwd =
  match container_path_of_host t ~host_path:host_cwd with
  | Ok container_cwd -> container_cwd
  | Error _ ->
    match Keeper_cwd_response.profile_independent_cwd
            ~container_root:t.container_root ~host_cwd with
    | Some cwd -> cwd
    | None ->
      let checkouts = discovered_checkouts t in
      (match find_checkout_and_suffix ~checkouts ~host_cwd with
       | Matched (checkout, suffix) ->
         Filename.concat
           t.container_root
           (Keeper_playground_checkouts.join checkout ~suffix)
       | Ambiguous_segment (segment, many) ->
         (* Falling back to the container root is still the answer — there is
            no better one — but which of the candidates was meant is now
            recorded instead of decided by sort order. *)
         Log.Keeper.warn
           "playground cwd segment matches multiple checkouts keeper=%s segment=%s \
            paths=%s"
           t.meta.name
           segment
           (String.concat
              ","
              (List.map
                 (fun (c : Keeper_playground_checkouts.checkout) -> c.relative_path)
                 many));
         t.container_root
       | No_match -> t.container_root)
;;

let format_docker_exec_error ~head_program ~st ~out =
  match st with
  | Unix.WEXITED code ->
    Printf.sprintf
      "docker_%s_failed: exit=%d output=%s"
      head_program
      code
      (Keeper_sandbox_runtime.docker_failure_output_for_log out)
  | Unix.WSIGNALED n -> Printf.sprintf "docker_%s_signaled: signal=%d" head_program n
  | Unix.WSTOPPED n -> Printf.sprintf "docker_%s_stopped: signal=%d" head_program n
;;

let sandbox_environment () =
  Env_keeper_scrub.filter_environment (Unix.environment ())
;;

let run_argv_with_status ?timeout_sec argv =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_with_status
      ?timeout_sec
      ~env:(sandbox_environment ())
      ~cwd:(Config_dir_resolver.current_working_dir ())
      argv)
;;

(* The policy lane attaches a guest to a host-only network, and [container
   run] fails rather than falling back when that network is absent. Creating
   it here rather than at server boot keeps the failure next to the keeper
   that needed it, and keeps a server with no policy keeper from creating a
   network nothing uses.

   Idempotent by listing first: a create against an existing name is an
   error on this CLI, and swallowing that error would also swallow the real
   ones. *)
(* Named because a bare 30. and 60. in a boot path is the kind of number a
   later edit rounds without knowing which call it bounds. Listing is a local
   read; creating brings up a vmnet interface. *)
let policy_network_list_timeout_s = 30.0
let policy_network_create_timeout_s = 60.0

(* Returns the gateway a guest on the policy network reaches the host at, so
   the boot can point the guest's clients at the proxy behind it. [None] for
   every other mode, which needs no gateway. *)
let ensure_policy_network backend ~keeper_name (mode : Keeper_types_profile_sandbox.network_mode) =
  let gateway_of_network () =
    match Keeper_sandbox_microvm.policy_network_inspect_argv_for backend ~keeper_name with
    | Error _ as error -> error
    | Ok inspect_argv ->
      (match run_argv_with_status ~timeout_sec:policy_network_list_timeout_s inspect_argv with
       | Unix.WEXITED 0, inspect ->
         (match Keeper_sandbox_microvm.policy_network_gateway ~inspect with
          | Ok gateway -> Ok (Some gateway)
          | Error detail -> Error ("microvm_policy_network_unreadable: " ^ detail))
       | (Unix.WEXITED _, output) | (Unix.WSIGNALED _, output) | (Unix.WSTOPPED _, output) ->
         Error
           (Printf.sprintf
              "microvm_policy_network_unreadable: %s: %s"
              (String.concat " " inspect_argv)
              (String.trim output)))
  in
  match mode with
  | Keeper_types_profile_sandbox.Network_none | Keeper_types_profile_sandbox.Network_inherit
    -> Ok None
  | Keeper_types_profile_sandbox.Network_policy ->
    (match Keeper_sandbox_microvm.policy_network_list_argv_for backend with
     | Error _ as error -> error
     | Ok list_argv ->
       let create_network () =
         match Keeper_sandbox_microvm.policy_network_create_argv_for backend ~keeper_name with
         | Error _ as error -> error
         | Ok create_argv ->
           (match run_argv_with_status ~timeout_sec:policy_network_create_timeout_s create_argv with
            | Unix.WEXITED 0, _ -> Ok ()
            | (Unix.WEXITED _, output) | (Unix.WSIGNALED _, output) | (Unix.WSTOPPED _, output) ->
              Error
                (Printf.sprintf
                   "microvm_policy_network_uncreatable: %s: %s"
                   (String.concat " " create_argv)
                   (String.trim output)))
       in
       (match run_argv_with_status ~timeout_sec:policy_network_list_timeout_s list_argv with
        | Unix.WEXITED 0, listing ->
          (match Keeper_sandbox_microvm.policy_network_present ~keeper_name ~listing with
           | Ok true -> gateway_of_network ()
           | Ok false ->
             (match create_network () with
              | Error _ as error -> error
              | Ok () -> gateway_of_network ())
           | Error detail ->
             Error ("microvm_policy_network_unreadable: " ^ detail))
        | (Unix.WEXITED _, listing) | (Unix.WSIGNALED _, listing) | (Unix.WSTOPPED _, listing) ->
          Error
            (Printf.sprintf
               "microvm_policy_network_unreadable: %s: %s"
               (String.concat " " list_argv)
               (String.trim listing))))
;;

let output_for_status ~(stdout : string) ~(stderr : string) =
  match stdout, stderr with
  | "", err -> err
  | out, "" -> out
  | out, err -> out ^ "\n" ^ err
;;

let run_argv_with_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?output_capture
      argv
  =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    let env = sandbox_environment () in
    let cwd = Config_dir_resolver.current_working_dir () in
    match on_stdout_chunk, on_stderr_chunk, output_capture with
    | None, None, None ->
      Process_eio.run_argv_with_status_split
        ?timeout_sec
        ~env
        ~cwd
        argv
    | _ ->
      (* DET-OK: absent stream callbacks mean the caller requested capture only. *)
      let on_stdout_chunk = Option.value on_stdout_chunk ~default:(fun _ -> ()) in
      (* DET-OK: stderr callback absence has the same capture-only meaning. *)
      let on_stderr_chunk = Option.value on_stderr_chunk ~default:(fun _ -> ()) in
      Process_eio.run_argv_with_status_split_streaming
        ?timeout_sec
        ?output_capture
        ~env
        ~cwd
        ~on_stdout_chunk
        ~on_stderr_chunk
        argv)
;;

let run_argv_with_stdin_and_status ?timeout_sec ~stdin_content argv =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_with_stdin_and_status
      ?timeout_sec
      ~env:(sandbox_environment ())
      ~cwd:(Config_dir_resolver.current_working_dir ())
      ~stdin_content
      argv)
;;

(* A failed transport can leave a guest effect running. Do not start another
   process in response to an Eio bind error for these requests. *)
let run_build_link_effect ?timeout_sec ~stdin_content argv =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    let status, _, _ =
      Process_eio.run_argv_with_stdin_and_status_split
        ?timeout_sec ~fallback_policy:Process_eio.Eio_only
        ~env:(sandbox_environment ())
        ~cwd:(Config_dir_resolver.current_working_dir ())
        ~stdin_content argv in
    status)
;;

let run_argv_with_stdin_and_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?output_capture
      ~stdin_content
      argv
  =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_with_stdin_and_status_split
      ?timeout_sec
      ?output_capture
      ~env:(sandbox_environment ())
      ~cwd:(Config_dir_resolver.current_working_dir ())
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~stdin_content
      argv)
;;

let run_argv_pipeline_with_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      stages
  =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_pipeline_with_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      stages)
;;

let is_microvm (t : t) =
  t.meta.sandbox_profile = Keeper_types_profile_sandbox.Micro_vm
;;

(* Which runtime this guest is on. [effective_meta_of_profile_defaults]
   resolves it and refuses a Micro_vm keeper that has none, so a guest that
   reached dispatch has one -- but two constructors write the field directly
   ([Keeper_turn_up_create], [Keeper_meta_json_parse]), so the empty case is
   reachable. It is a refusal rather than an assumed runtime: naming Apple
   here is how a keeper that declared microsandbox booted under container
   and was then stopped with msb (#32837). *)
let microvm_backend_of_meta (meta : keeper_meta) =
  match meta.microvm_backend with
  | Some backend -> Ok backend
  | None ->
    Error
      (Printf.sprintf
         "microvm_backend_unresolved: keeper %s declares sandbox_profile=microvm \
          and no microvm_backend, so there is no runtime to boot it on. Next: \
          set microvm_backend in the keeper's TOML to one of: %s"
         meta.name
         (String.concat ", " Keeper_microvm_backend.valid_strings))
;;

let microvm_backend_of (t : t) = microvm_backend_of_meta t.meta

(* The Docker exec prefix: [docker exec [-i] --user u:g -w cwd [env...]].
   Only the Docker lane execs into a mounted tree. A microvm guest owns its
   tree on the work volume and is reached through the shim over the remote
   lane (RFC-0400), so every exec entrypoint below refuses it first. *)
let exec_prefix (t : t) ~container_cwd ~stdin =
  Keeper_sandbox_runtime.docker_command_argv ()
  @ [ "exec" ]
  @ (if stdin then [ "-i" ] else [])
  @ [ "--user"; Printf.sprintf "%d:%d" t.uid t.gid; "-w"; container_cwd ]
  @ Keeper_sandbox_runtime.docker_sandbox_env_args
      ~base_path:t.config.base_path
      ~container_root:t.container_root
;;

let docker_exec_only (t : t) =
  if is_microvm t
  then
    Error
      (Printf.sprintf
         "microvm_exec_is_remote: keeper %s's guest owns its tree on the work volume; commands reach it through the remote lane (Keeper_sandbox_remote), not a docker-shaped exec"
         t.meta.name)
  else Ok ()
;;

(* Whether the Docker daemon can see the named container, in any state. A
   microvm guest is asked through [probe_microvm_container_state], which also
   tells a missing guest from a runtime that could not be asked. *)
let inspect_container_exists ?timeout_sec container_name =
  let inspect_argv =
    Keeper_sandbox_runtime.docker_command_argv ()
    @ [ "inspect"; "--format"; "{{.Id}}"; container_name ]
  in
  let inspect_st, inspect_out =
    run_argv_with_status ?timeout_sec inspect_argv
  in
  match inspect_st with
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error inspect_out
;;

(* An inspect that exits 0 is the whole answer. Any other end -- a missing
   name, an apiserver that stalled before it could look, a timeout -- is
   followed by the runtime's own listing, so [Docker_container_absent] means
   a listing was read and the name is not in it, and [Error] means nobody
   could say (#44676). *)
let probe_microvm_container_state ?timeout_sec ~backend container_name =
  let inspect =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.inspect_argv_for backend ~container_name)
  in
  let listing =
    match inspect with
    | Unix.WEXITED 0, _ -> None
    | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ ->
      Some
        (run_argv_with_status_split
           ?timeout_sec
           (Keeper_sandbox_microvm.guest_listing_argv_for backend))
  in
  Keeper_sandbox_microvm.classify_guest_probe_for
    backend
    ~container_name
    ~inspect
    ~listing
;;

let inspect_container_running ?timeout_sec container_name =
  match
    Keeper_sandbox_runtime.probe_container_state_optional ~container_name ?timeout_sec ()
  with
  | Ok Keeper_sandbox_runtime.Docker_container_running -> Ok ()
  | Ok Keeper_sandbox_runtime.Docker_container_stopped ->
    Error (Printf.sprintf "docker container %s is stopped" container_name)
  | Ok Keeper_sandbox_runtime.Docker_container_absent ->
    Error (Printf.sprintf "docker container %s is absent" container_name)
  | Error _ as error -> error
;;

type failed_exec_recovery =
  | Preserve_failed_exec
  | Restart_failed_exec
  | Failed_exec_state_probe_error of string

(* Asked only after a Docker exec failed: every exec entrypoint runs
   [docker_exec_only] first, which refuses a microvm runtime. *)
let failed_exec_recovery ?timeout_sec (t : t) =
  match get_state t with
  | Not_started -> Restart_failed_exec
  | Running { container_name } ->
    (match
       Keeper_sandbox_runtime.probe_container_state_optional
         ~container_name
         ?timeout_sec
         ()
     with
     | Ok Keeper_sandbox_runtime.Docker_container_running -> Preserve_failed_exec
     | Ok Keeper_sandbox_runtime.Docker_container_stopped
     | Ok Keeper_sandbox_runtime.Docker_container_absent -> Restart_failed_exec
     | Error detail -> Failed_exec_state_probe_error detail)
;;

let failed_exec_state_probe_error ~status ~output detail =
  Printf.sprintf
    "docker_container_state_probe_failed_after_exec: status=%s output=%s probe_error=%s"
    (Keeper_sandbox_exec_failure.status_label status)
    (Keeper_sandbox_runtime.docker_failure_output_for_log output)
    detail
;;

(* A microvm guest mounts its work volume, the shim, runtime config, and its
   immutable GitHub identity snapshot -- never the host playground. It still
   has no generic secret projection or workspace-state mounts, and no
   seccomp/pids/security-opt flags (container rejects those; the guest kernel
   is the boundary). *)
(* One guest per keeper, not per turn: the name is stable, an already
   running guest is adopted instead of booted (amortising the 1.3-2.4s VM
   start to once per keeper), and turn cleanup leaves it running. State
   accumulated inside the guest between turns belongs to the same keeper.
   Teardown is [teardown_keeper_sandbox], which shutdown finalization runs after
   the registry unregister succeeds -- the one point that knows the keeper is
   gone for good rather than between turns. *)
(* The network mode is in the name for the reason it is in the Docker
   container's: adopt matches by name, so a name that ignores the mode lets a
   guest booted under one policy be adopted under another.

   For [Network_policy] that is not only a wrong network. The guest carries
   the proxy address in its environment, and the port is ephemeral, so a
   guest adopted across a server restart would keep CONNECTing to a port
   nothing is listening on -- no refusal, no event, and a keeper that looks
   idle rather than cut off. A distinct name makes that guest a different
   guest, so it is replaced instead of adopted. *)
let microvm_container_name ~(config : Workspace.config) ~keeper_name ~network_mode =
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Micro_vm_persistent
       { keeper_name; network_mode; base_path = config.base_path })
  |> Keeper_sandbox_container_name.to_string
;;

(* The port is read from the keeper's registry entry rather than carried in
   the turn state: the proxy is bound once per keeper lane and a guest boots
   per turn, so the two ends have different lifetimes and the entry is what
   both can see. [None] means no listener -- the lane is down, or its fiber
   died -- and no guest may be pointed at it. *)
let bound_egress_proxy_port (t : t) =
  Keeper_registry.get ~base_path:t.config.base_path t.meta.name
  |> Option.map (fun (entry : Keeper_registry_types.registry_entry) ->
       Atomic.get entry.egress_proxy_port)
  |> Option.join
;;

let keeper_vm_name (t : t) =
  microvm_container_name
    ~config:t.config
    ~keeper_name:t.meta.name
    ~network_mode:t.network_mode
;;

let bind_registered_microvm_identity t container_name =
  match microvm_identity_snapshot container_name with
  | None -> None
  | Some snapshot ->
    bind_github_identity_snapshot t (Process_identity snapshot);
    Some snapshot
;;

let stop_and_delete_microvm_container ?timeout_sec ~backend container_name =
  let stop_st, stop_out =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.stop_argv_for backend ~container_name)
  in
  let delete_st, delete_out =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.delete_force_argv_for backend ~container_name)
  in
  (* Both commands can race a guest that is already absent, so their exit
     codes are only diagnostics. The postcondition is authoritative: do not
     release the mounted identity snapshot until the guest name is gone. *)
  let absence = match backend with
    | Keeper_microvm_backend.Apple_container ->
      let timeout_sec = match timeout_sec with Some seconds -> seconds
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm () in
      Keeper_microvm_guest_inventory.read ~backend ~guest_name:container_name ~timeout_sec
      |> Result.map (function
        | Keeper_microvm_guest_inventory.Absent -> Keeper_sandbox_runtime.Docker_container_absent
        | Keeper_microvm_guest_inventory.Present -> Keeper_sandbox_runtime.Docker_container_running)
      |> Result.map_error Keeper_microvm_guest_inventory.error_message
    | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
      probe_microvm_container_state ?timeout_sec ~backend container_name in
  match absence with
  | Ok Keeper_sandbox_runtime.Docker_container_absent ->
    forget_microvm_work_root container_name;
    forget_microvm_boot container_name;
    Keeper_microvm_shim_readiness.forget ~backend ~guest_name:container_name;
    Ok ()
  | Ok Keeper_sandbox_runtime.Docker_container_running
  | Ok Keeper_sandbox_runtime.Docker_container_stopped ->
    Error
      (Printf.sprintf
         "microvm_teardown_failed: guest remains after stop=%s (%s), delete=%s (%s)"
         (Keeper_sandbox_exec_failure.status_label stop_st)
         (Keeper_sandbox_runtime.docker_failure_output_for_log stop_out)
         (Keeper_sandbox_exec_failure.status_label delete_st)
         (Keeper_sandbox_runtime.docker_failure_output_for_log delete_out))
  | Error probe_error ->
    Error
      (Printf.sprintf
         "microvm_teardown_failed: post-delete state unknown: %s; stop=%s (%s), delete=%s (%s)"
         probe_error
         (Keeper_sandbox_exec_failure.status_label stop_st)
         (Keeper_sandbox_runtime.docker_failure_output_for_log stop_out)
         (Keeper_sandbox_exec_failure.status_label delete_st)
         (Keeper_sandbox_runtime.docker_failure_output_for_log delete_out))
;;

(** The work volume (RFC-0400): Apple's working tree is on a guest ext4 disk;
    Linux nerdctl uses a persistent runtime-managed directory, without Apple's
    capacity or flat host-descriptor guarantee. Created if
    it is not there yet; refusing rather than booting without it follows
    [image_present] in the same lane -- a guest with no work volume has no
    tree, and the remote lane has nowhere to run. *)
let microvm_work_volume ~backend ~keeper_name ~timeout_sec =
  match Keeper_sandbox_microvm.work_volume_name ~keeper_name with
  | Error message -> Error ("microvm_work_volume_unnamed: " ^ message)
  | Ok volume_name ->
    (match
       Keeper_sandbox_microvm.ensure_work_volume_for
         backend
         ~volume_name
         ~size:(Env_config_sandbox.Runtime.microvm_work_volume_size ())
         ~timeout_sec
     with
     | Error _ as err -> err
     | Ok _ -> Ok volume_name)
;;

(** The build volume (RFC-keeper-build-output-returns-to-a-disposable-volume),
    `Apple_container` only: `msb` and `nerdctl`
    back their named work volumes with a host directory, so a guest [rm -rf
    _build] already returns host disk immediately there and this volume is
    not provisioned for them -- [None], not a refusal, since its absence
    costs a `Micro_vm` keeper on those backends nothing. On Apple, absence
    is a refusal like {!microvm_work_volume}'s: a guest that cannot get the
    volume this RFC's disk-reclaim path depends on does not start rather
    than fall back to writing `_build` onto the unified work volume, which
    is exactly the unbounded growth this exists to bound. Recreated, not
    merely ensured: this runs only on a fresh [container run] (never on
    adoption of an already-running guest, the same boundary
    {!microvm_work_volume} keeps its own volume across), so "fresh boot"
    and "empty build volume" coincide by construction, and every guest
    restart is the host-disk reclaim this RFC exists for. *)
let microvm_build_volume ~backend ~keeper_name ~timeout_sec =
  match (backend : Keeper_microvm_backend.t) with
  | Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata -> Ok None
  | Keeper_microvm_backend.Apple_container ->
    (match Keeper_sandbox_microvm.build_volume_name ~keeper_name with
     | Error message -> Error ("microvm_build_volume_unnamed: " ^ message)
     | Ok volume_name ->
       (match
          Keeper_sandbox_microvm.recreate_apple_build_volume
            ~volume_name
            ~size:(Env_config_sandbox.Runtime.microvm_build_volume_size ())
            ~timeout_sec
        with
        | Error _ as err -> err
        | Ok _ -> Ok (Some volume_name)))
;;

let microvm_shim_host_dir (t : t) =
  Config_dir_resolver.microvm_shim_dir ~base_path:t.config.base_path
;;

(* Startup installs the shared config before endpoint admission. Every guest
   reaches the same once-per-process verification authority, including adoption
   and attached reads; provisioning does not rewrite the mounted config. *)
let prepare_microvm_shim_dir (t : t) ~backend =
  Keeper_microvm_shim_readiness.verify ~base_path:t.config.base_path ~backend
    ~guest_name:(keeper_vm_name t)
  |> Result.map (fun () -> microvm_shim_host_dir t)
  |> Result.map_error Keeper_microvm_shim_readiness.error_message
;;

type microvm_guest_provisions =
  { work_volume_name : string
  ; build_volume_name : string option
        (** [Some] on `Apple_container`; [None] on backends whose
            work volume already returns host disk on a guest delete. *)
  ; shim_host_dir : string
  }

(* Both legacy helper names are shared across workspaces. A complete listing
   can show a helper is present, but cannot establish who owns it or stop an
   older process from starting one after this observation. *)
let ensure_apple_volume_helpers_absent ~keeper_name ~timeout_sec =
  let module Inventory = Keeper_microvm_guest_inventory in
  let unknown error =
    Error ("microvm_volume_helper_inventory_unverified: " ^ Inventory.error_message error)
  in
  match Inventory.read_apple ~timeout_sec with
  | Error error -> unknown error
  | Ok inventory ->
    let rec check = function
      | [] -> Ok ()
      | name :: rest ->
        (match Inventory.presence ~guest_name:name inventory with
         | Ok Inventory.Absent -> check rest
         | Ok Inventory.Present ->
           Error
             (Printf.sprintf
                "microvm_volume_helper_ownership_unverified: helper %s is present; its workspace owner is unknown"
                name)
         | Error error -> unknown error)
    in
    check [ Keeper_sandbox_microvm.work_volume_trim_name ~keeper_name
          ; Keeper_sandbox_microvm.volume_repair_name ~keeper_name ]
;;

(** Everything a guest boot mounts besides config and identity, established
    before [container run] so a boot never starts without one of them. *)
let microvm_guest_provisions (t : t) ~backend ~timeout_sec =
  (* Until helper and volume ownership are bound to a workspace, boot must
     neither launch a name-scoped trim helper nor delete a possible peer's
     helper. A present or unreadable helper inventory refuses provisioning.
     The observation does not fence an older process from starting one later. *)
  let helper_check = match (backend : Keeper_microvm_backend.t) with
    | Keeper_microvm_backend.Apple_container ->
      ensure_apple_volume_helpers_absent ~keeper_name:t.meta.name ~timeout_sec
    | Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata -> Ok ()
  in
  match helper_check with
  | Error _ as error -> error
  | Ok () ->
    (match microvm_work_volume ~backend ~keeper_name:t.meta.name ~timeout_sec with
     | Error _ as err -> err
     | Ok work_volume_name ->
       (match microvm_build_volume ~backend ~keeper_name:t.meta.name ~timeout_sec with
        | Error _ as err -> err
        | Ok build_volume_name ->
          (match prepare_microvm_shim_dir t ~backend with
           | Error _ as err -> err
           | Ok shim_host_dir -> Ok { work_volume_name; build_volume_name; shim_host_dir })))
;;

(** Boot invariant (RFC-0052), fail-closed:
    {!Keeper_sandbox_microvm.work_volume_guest_root} must be a real mountpoint
    inside the guest before anything is written there. The
    mkdir and write probe below both succeed against a writable rootfs
    directory, so without this check a guest whose volume mount is absent at
    boot serves an ephemeral tree silently -- keeper writes evaporate on the
    next boot and a delivered paste's log line is a lie (2026-09-04, analyst
    guest on a stale rootfs tree). *)
let ensure_microvm_work_volume_mounted ?timeout_sec (t : t) ~backend ~container_name =
  match Keeper_sandbox_microvm.work_volume_name ~keeper_name:t.meta.name with
  | Error detail -> Error ("microvm_work_volume_unnamed: " ^ detail)
  | Ok volume_name ->
    let probe =
      Keeper_sandbox_microvm.work_volume_mounted_probe_argv_for backend ~container_name
    in
    let status, stdout, stderr = run_argv_with_status_split ?timeout_sec probe in
    (match Keeper_sandbox_microvm.work_volume_mount_probe_of_result ~status ~stdout ~stderr with
     | Keeper_sandbox_microvm.Work_volume_mounted -> Ok ()
     | Keeper_sandbox_microvm.Work_volume_not_mounted ->
       Error
         (Printf.sprintf
            "microvm_work_volume_not_mounted: guest %s reported that %s is not a mountpoint (volume %s); the guest cannot be used until its work volume is mounted"
            container_name
            Keeper_sandbox_microvm.work_volume_guest_root
            volume_name)
     | Keeper_sandbox_microvm.Work_volume_probe_unverified { status; stdout; stderr } ->
       let detail =
         output_for_status ~stdout ~stderr
         |> Keeper_sandbox_runtime.docker_failure_output_for_log
       in
       Error
         (Printf.sprintf
            "microvm_work_volume_probe_unverified: could not verify %s in guest %s (volume %s; %s)%s; inspect the guest and its execution transport before recovery"
            Keeper_sandbox_microvm.work_volume_guest_root
            container_name
            volume_name
            (Keeper_sandbox_exec_failure.status_label status)
            (if String.equal (String.trim detail) "" then ""
             else "; unverified probe output: " ^ detail)))
;;

module For_testing_microvm = struct
  type build_link_generation = unit ref

  let build_link_generation ~container_name =
    Option.map (fun entry -> entry.generation) (microvm_work_root_entry container_name)
  ;;

  let complete_build_link_scan ~container_name generation =
    set_microvm_build_links_state container_name generation
      ~expected:Build_links_not_prepared Build_links_prepared
  ;;

  let build_link_scan_prepared ~container_name =
    match microvm_work_root_entry container_name with
    | Some { build_links_state = Build_links_prepared; _ } -> true
    | Some { build_links_state = (Build_links_not_prepared | Build_links_effect_unverified); _ }
    | None -> false
  ;;

  let microvm_container_name = microvm_container_name

  let microvm_identity_snapshot_registered ~container_name =
    Option.is_some (microvm_identity_snapshot container_name)
  ;;

  let mark_microvm_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
    let container_name =
      microvm_container_name
        ~config
        ~keeper_name:meta.name
        ~network_mode:meta.network_mode
    in
    mark_microvm_work_root_ready container_name
  ;;

  let ensure_work_volume_mounted = ensure_microvm_work_volume_mounted

  let provision_guest t ~backend ~timeout_sec =
    microvm_guest_provisions t ~backend ~timeout_sec |> Result.map (fun _ -> ())
end

(** The keeper's root on the work volume, made inside the guest once it is
    up. The volume outlives the guest, so this is a no-op after the first
    boot; it runs as root because the volume root is root-owned. The mount
    invariant runs first: existence and writability of the root prove nothing
    while {!Keeper_sandbox_microvm.work_volume_guest_root} itself may be a
    rootfs directory. *)
let ensure_microvm_keeper_work_root ?timeout_sec (t : t) ~backend ~container_name =
  let prepare_volume =
    match ensure_microvm_work_volume_mounted ?timeout_sec t ~backend ~container_name with
    | Error _ as err -> err
    | Ok () ->
      (match Keeper_sandbox_microvm.work_volume_search_argv_for backend ~container_name with
       | None -> Ok ()
       | Some argv ->
         match run_argv_with_status ?timeout_sec argv with
         | Unix.WEXITED 0, _ -> Ok ()
         | (Unix.WEXITED _, out) | (Unix.WSIGNALED _, out) | (Unix.WSTOPPED _, out) ->
           Error
             ("microvm_work_volume_search_failed: "
              ^ Keeper_sandbox_runtime.docker_failure_output_for_log out))
  in
  match prepare_volume with
  | Error _ as err -> err
  | Ok () ->
  let root = Keeper_sandbox_microvm.keeper_work_root ~keeper_name:t.meta.name in
  let mkdir =
    Keeper_sandbox_microvm.keeper_work_root_mkdir_argv_for
      backend
      ~container_name
      ~keeper_name:t.meta.name
  in
  match run_argv_with_status ?timeout_sec mkdir with
  | Unix.WEXITED 0, _ ->
    (* Existence is root's doing; use is the keeper's. The probe writes as
       the uid every command of this keeper will run as, so a root the
       keeper cannot write -- imported under another uid, or a mode the
       volume kept from an earlier life -- is refused here, with its owner
       and mode, instead of on the first Write of a turn. *)
    let probe =
      Keeper_sandbox_microvm.keeper_work_root_write_probe_argv_for
        backend
        ~container_name
        ~uid:t.uid
        ~gid:t.gid
        ~keeper_name:t.meta.name
    in
    (match run_argv_with_status ?timeout_sec probe with
     | Unix.WEXITED 0, _ -> Ok ()
     | (Unix.WEXITED _, out) | (Unix.WSIGNALED _, out) | (Unix.WSTOPPED _, out) ->
       Error
         (Printf.sprintf
            "microvm_keeper_work_root_not_writable: %s as %d:%d: %s"
            root
            t.uid
            t.gid
            (Keeper_sandbox_runtime.docker_failure_output_for_log out)))
  | (Unix.WEXITED _, out) | (Unix.WSIGNALED _, out) | (Unix.WSTOPPED _, out) ->
    Error
      (Printf.sprintf
         "microvm_keeper_work_root_failed: %s: %s"
         root
         (Keeper_sandbox_runtime.docker_failure_output_for_log out))
;;

(** Best-effort Apple build-link preparation. A read-only scan failure can be
    retried by a later turn. Once an effect may have been sent, its unknown
    outcome is retained while this guest generation remains cached. A forget
    or process restart clears that state; it does not establish workspace
    ownership or fence an effect already in flight. *)
let ensure_microvm_build_links ?timeout_sec (t : t) ~container_name ~generation =
    let backend = Keeper_microvm_backend.Apple_container in
    let keeper_work_root = Keeper_sandbox_microvm.keeper_work_root ~keeper_name:t.meta.name in
    let scan =
      Keeper_sandbox_microvm.build_scan_argv_for
        backend
        ~container_name
        ~keeper_work_root
        ~uid:t.uid
        ~gid:t.gid
    in
    let scanned = Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
      Keeper_microvm_cli_output.read_with_environment ?timeout_sec
        ~stdout_limit:Common.max_process_capture_head_bytes
        ~stderr_limit:Common.max_process_capture_tail_bytes
        ~env:(sandbox_environment ()) ~cwd:(Config_dir_resolver.current_working_dir ())
        ~argv:scan ()) in
    let mark ~expected state =
      set_microvm_build_links_state container_name generation ~expected state in
    let prepared ~expected = ignore (mark ~expected Build_links_prepared) in
    let effect_unverified () =
      Log.Keeper.warn ~keeper_name:t.meta.name
        "microvm_build_link_effect_unverified: inspect the guest before retrying; this guest generation will not automatically retry while its state is retained; see Keeper User Manual: Build preparation reports a failure" in
    let effect_failed operation status =
      Log.Keeper.warn ~keeper_name:t.meta.name "%s: %s"
        operation (Keeper_sandbox_exec_failure.status_label status);
      (match status with
       | Unix.WEXITED 127 ->
         Log.Keeper.warn ~keeper_name:t.meta.name
           "microvm_build_link_interpreter_unverified: check guest /usr/bin/python3 and /usr/local/bin/python3 as the user executing this step; exit 127 alone does not establish the cause or effect outcome"
       | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> ());
      effect_unverified () in
    (match scanned with
     | Ok (Unix.WEXITED 0, stdout, _) ->
       (match Keeper_sandbox_microvm.build_scan_rows_of_output stdout with
        | Error detail ->
          Log.Keeper.warn ~keeper_name:t.meta.name "microvm_build_scan_failed: %s" detail
        | Ok scanned ->
       let rows = Keeper_sandbox_microvm.build_link_rows_of_scan scanned in
       List.iter
         (fun (row : Keeper_sandbox_microvm.build_link_row) ->
           match Keeper_sandbox_microvm.build_link_warning row.plan with
           | Some message -> Log.Keeper.warn ~keeper_name:t.meta.name "%s" message
           | None -> ())
         rows;
       let actions = Keeper_sandbox_microvm.build_link_actions rows in
       (* Already-correct links need their target too: a fresh boot recreates
          the build volume empty while the work volume keeps the links. *)
       (match Keeper_sandbox_microvm.build_link_targets rows with
        | [] -> prepared ~expected:Build_links_not_prepared
        | _ :: _ as targets ->
          if mark ~expected:Build_links_not_prepared Build_links_effect_unverified then (
          let mkdir, mkdir_input =
            Keeper_sandbox_microvm.build_target_mkdir_request ~container_name ~targets in
          (try match run_build_link_effect ?timeout_sec ~stdin_content:mkdir_input mkdir, actions with
           | Unix.WEXITED 0, [] -> prepared ~expected:Build_links_effect_unverified
           | Unix.WEXITED 0, _ :: _ ->
             (* This is a local check only: it cannot cancel an already sent
                guest operation or fence an externally replaced guest. *)
             let generation_retained =
               match microvm_work_root_entry container_name with
               | Some entry -> entry.generation == generation
                 && entry.build_links_state = Build_links_effect_unverified
               | None -> false in
             if not generation_retained then effect_unverified () else
             let apply, apply_input =
               Keeper_sandbox_microvm.build_link_apply_request_for
                 backend
                 ~container_name
                 ~keeper_work_root
                 ~uid:t.uid
                 ~gid:t.gid
                 ~actions
             in
             (match run_build_link_effect ?timeout_sec ~stdin_content:apply_input apply with
              | Unix.WEXITED 0 -> prepared ~expected:Build_links_effect_unverified
              | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status ->
                effect_failed "microvm_build_link_apply_failed" status)
           | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _ ->
             effect_failed "microvm_build_link_mkdir_failed" status
           with exn -> effect_unverified (); raise exn))))
     | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _, _) ->
       Log.Keeper.warn ~keeper_name:t.meta.name
         "microvm_build_scan_failed: %s; inspect guest find and readlink support"
         (Keeper_sandbox_exec_failure.status_label status)
     | Error ({ reason = Keeper_microvm_cli_output.Capture_limit_exceeded; _ } as error) ->
       Log.Keeper.warn ~keeper_name:t.meta.name
         "microvm_build_scan_failed: %s; limit %d bytes; reduce scanned checkouts before retrying"
         (Keeper_microvm_cli_output.error_message error)
         Common.max_process_capture_head_bytes
     | Error ({ reason =
                  ( Keeper_microvm_cli_output.Capture_directory_unavailable
                  | Keeper_microvm_cli_output.Capture_incomplete
                  | Keeper_microvm_cli_output.Capture_failed
                  | Keeper_microvm_cli_output.Capture_unreadable
                  | Keeper_microvm_cli_output.Capture_permissions_invalid
                  | Keeper_microvm_cli_output.Capture_length_mismatch
                  | Keeper_microvm_cli_output.Capture_cleanup_failed ); _ } as error) ->
       Log.Keeper.warn ~keeper_name:t.meta.name
         "microvm_build_scan_failed: %s"
         (Keeper_microvm_cli_output.error_message error))
;;

(* Which side of a guest start a failure belongs to. The Keeper's GitHub
   identity is at fault only when the start itself refused that identity or
   a direct refresh, snapshot or revision check failed; every other cause is
   the sandbox's. Callers branch on the constructor, never on the detail
   text. *)
type github_identity_preparation_error =
  | Sandbox_unavailable of string
  | Identity_unavailable of string

let github_identity_preparation_error_message = function
  | Sandbox_unavailable detail | Identity_unavailable detail -> detail
;;

(* Why a guest did not come up. A name the runtime refuses is not one of
   them: [Keeper_sandbox_container_name] builds only names every microVM
   runtime accepts. An arm that wraps what another step or the runtime's CLI
   said keeps that text whole in a field; the sentence an operator reads is
   written once, in [microvm_start_failure_message]. *)
type microvm_post_boot_check =
  | Runtime_does_not_list
  | Work_root_unusable

type microvm_start_failure =
  | Backend_unresolved of string
  | Runtime_context_unavailable
  | Guest_identity_store_unavailable of Keeper_microvm_github_identity.error
  | Guest_facts_refused of Keeper_microvm_boot_plan.refusal
  | Image_unresolved of Keeper_sandbox_image_resolver.error
  | Guest_state_unreadable of string
  | Guest_size_invalid of string
      (** Neither the keeper nor the workspace names a size that parses, so
          there is nothing to boot the guest with or compare a running one
          against. *)
  | Unadoptable_guest_not_removed of string
      (** A running guest that may not be adopted -- its snapshot died with
          an older server, or its image, size or proxy port is not what the
          keeper asks for now -- and would not go. *)
  | Previous_mode_guest_not_removed of { container_name : string; detail : string }
      (** Every network mode shares the Keeper's volumes. A previous mode
          must release them before any fresh boot can recreate or trim them. *)
  | Adopted_guest_volume_unverified of string
  | Guest_provisions_unavailable of string
  | Github_identity_invalid of string
  | Policy_network_unavailable of string
  | Network_unexpressible of string
  | Invalid_boot_plan of Keeper_microvm_boot_plan.invalid_plan list
  | Constraints_unexpressible of
      { backend : Keeper_microvm_backend.t
      ; refusals : Keeper_sandbox_microvm.constraint_refusal list
      }
  | Booted_guest_unusable of
      { check : microvm_post_boot_check
      ; container_name : string
      ; detail : string
      }
  | Booted_guest_state_unknown of
      { container_name : string
      ; detail : string
      }
      (** The boot argv exited 0 and the runtime could not then be asked
          about the guest. The guest is left running with its snapshot and
          boot record; the next start probes it again. *)
  | Boot_command_failed of
      { status : Unix.process_status
      ; output : string
      }
      (** The boot argv exited non-zero and no guest is running under the
          name, or its state could not be read. *)

let microvm_post_boot_check_label = function
  | Runtime_does_not_list -> "container ran but the runtime does not list it"
  | Work_root_unusable ->
    "guest cannot prove its work volume is mounted and its keeper root usable"
;;

let microvm_start_failure_message failure =
  let failed detail = "microvm_start_failed: " ^ detail in
  match failure with
  | Runtime_context_unavailable -> failed "microvm runtime filesystem or Eio execution is unavailable"
  | Guest_identity_store_unavailable error -> failed (Keeper_microvm_github_identity.error_message error)
  | Guest_facts_refused refusal ->
    failed (Keeper_microvm_boot_plan.refusal_message refusal)
  | Backend_unresolved detail
  | Guest_state_unreadable detail
  | Adopted_guest_volume_unverified detail
  | Guest_provisions_unavailable detail
  | Policy_network_unavailable detail
  | Network_unexpressible detail -> failed detail
  | Image_unresolved error -> failed (image_unresolved_message error)
  | Guest_size_invalid detail -> failed ("microvm_guest_size_invalid: " ^ detail)
  | Unadoptable_guest_not_removed detail ->
    failed ("a running guest that cannot be adopted was not removed: " ^ detail)
  | Previous_mode_guest_not_removed { container_name; detail } ->
    failed (Printf.sprintf "previous network-mode guest %s was not removed: %s"
      container_name detail)
  | Github_identity_invalid detail -> failed ("github_identity_invalid: " ^ detail)
  | Constraints_unexpressible { backend; refusals } ->
    failed (Keeper_sandbox_microvm.constraint_refusals_message backend refusals)
  | Invalid_boot_plan errors ->
    failed ("invalid boot plan: " ^ String.concat "; "
      (List.map Keeper_microvm_boot_plan.invalid_plan_message errors))
  | Booted_guest_unusable { check; container_name; detail } ->
    failed
      (Printf.sprintf
         "%s %s: %s"
         (microvm_post_boot_check_label check)
         container_name
         detail)
  | Booted_guest_state_unknown { container_name; detail } ->
    failed
      (Printf.sprintf
         "guest %s booted and was left running; its state could not be read: %s"
         container_name
         detail)
  | Boot_command_failed { status; output } ->
    failed
      (Printf.sprintf
         "boot %s: %s"
         (Keeper_sandbox_exec_failure.status_label status)
         (Keeper_sandbox_runtime.docker_failure_output_for_log output))
;;

(* Only a rejected GitHub identity is the Keeper's login at fault. Every
   constructor is named, so a new failure has to choose a side here. *)
let microvm_start_failure_cause failure =
  let detail = microvm_start_failure_message failure in
  match failure with
  | Github_identity_invalid _ -> Identity_unavailable detail
  | Backend_unresolved _
  | Runtime_context_unavailable
  (* [Guest_identity_store_unavailable] is named for what the store holds, the
     credential snapshot. It fails in the host's filesystem, registry, lock or
     lifecycle checks, which say nothing about whether the login is valid. *)
  | Guest_identity_store_unavailable _
  | Guest_facts_refused _
  | Image_unresolved _
  | Guest_state_unreadable _
  | Guest_size_invalid _
  | Unadoptable_guest_not_removed _
  | Previous_mode_guest_not_removed _
  | Adopted_guest_volume_unverified _
  | Guest_provisions_unavailable _
  | Policy_network_unavailable _
  | Network_unexpressible _
  | Invalid_boot_plan _
  | Constraints_unexpressible _
  | Booted_guest_unusable _
  | Booted_guest_state_unknown _
  | Boot_command_failed _ -> Sandbox_unavailable detail
;;

(* The same immutable request drives comparison and Boot argv. Volume names,
   mount sources and stable labels are projections here; provisioning and
   policy route discovery belong to the Boot execution. *)
let requested_apple_plan (t : t) ~image ~guest_size ~identity_host_dir ~environment
    ~config_mount ~stable_labels =
  let open Result.Syntax in
  let volume_name result = Result.map_error (fun detail -> Guest_provisions_unavailable detail) result in
  let* work_volume_name = volume_name (Keeper_sandbox_microvm.work_volume_name ~keeper_name:t.meta.name) in
  let* build_volume_name = volume_name (Keeper_sandbox_microvm.build_volume_name ~keeper_name:t.meta.name) in
  let module Plan = Keeper_microvm_boot_plan in
  let container_masc_dir = Keeper_sandbox_runtime_setup.container_masc_dir ~container_root:t.container_root in
  let identity_destination = Keeper_github_identity.container_config_dir
      ~container_masc_dir ~keeper_name:t.meta.name in
  let config_mount = match config_mount with
    | None -> []
    | Some (source, destination) -> [Plan.Host_dir {source; destination; read_only=true}] in
  let network = match t.network_mode with
    | Keeper_types_profile_sandbox.Network_none -> Plan.Network_none
    | Keeper_types_profile_sandbox.Network_inherit -> Plan.Network_inherit
    | Keeper_types_profile_sandbox.Network_policy ->
      Plan.Network_policy {name=Keeper_sandbox_microvm.policy_network_name ~keeper_name:t.meta.name} in
  Ok
    { Plan.image; guest_size; user=Printf.sprintf "%d:%d" t.uid t.gid
    ; working_directory=Keeper_sandbox_microvm.work_volume_guest_root
    ; command=["tail"; "-f"; "/dev/null"]
    ; mounts=config_mount
        @ [Plan.Host_dir {source=identity_host_dir; destination=identity_destination; read_only=true}
          ; Plan.Named_volume {name=work_volume_name; destination=Keeper_sandbox_microvm.work_volume_guest_root}
          ; Plan.Named_volume {name=build_volume_name; destination=Keeper_sandbox_microvm.build_volume_guest_root}
          ; Plan.Host_dir {source=microvm_shim_host_dir t; destination=Keeper_sandbox_microvm.shim_guest_dir; read_only=true}]
    ; isolation=Keeper_microvm_backend.all_guest_constraints
    ; network; environment
    ; labels=stable_labels @ [Keeper_sandbox_microvm.microvm_backend_label_key,
           Keeper_microvm_backend.to_string Keeper_microvm_backend.Apple_container]
    }

let start_process_bound_microvm_container ?timeout_sec (t : t) =
  (* The runtime is read once, before anything is spawned. A keeper whose
     TOML names none is refused here rather than booted on an assumed one,
     which is what pointed a boot and its cleanup at two CLIs (#32837). *)
  match microvm_backend_of t with
  | Error detail -> Error (Backend_unresolved detail)
  | Ok backend ->
  match t.image with
  | Error error -> Error (Image_unresolved error)
  | Ok image -> (
    (* Resolved before anything is probed or removed: a running guest is
       compared against this size, and a fresh one boots with it. *)
    match
      Env_config_sandbox.Runtime.microvm_guest_size
        ~memory:t.meta.microvm_memory
        ~cpus:t.meta.microvm_cpus
    with
    | Error detail -> Error (Guest_size_invalid detail)
    | Ok guest_size ->
    let container_name = keeper_vm_name t in
    let adopt snapshot =
      bind_github_identity_snapshot t (Process_identity snapshot);
      set_state t (Running { container_name });
      Ok container_name
    in
    let rec remove_previous_modes = function
      | [] -> Ok ()
      | mode :: rest when mode = t.network_mode -> remove_previous_modes rest
      | mode :: rest ->
        let previous =
          microvm_container_name ~config:t.config ~keeper_name:t.meta.name
            ~network_mode:mode
        in
        (match stop_and_delete_microvm_container ?timeout_sec ~backend previous with
         | Ok () -> remove_previous_modes rest
         | Error detail ->
           Error (Previous_mode_guest_not_removed { container_name = previous; detail }))
    in
    (* The guest is stopped and deleted only after the nameserver it will be
       booted with is known: see {!microvm_boot_nameserver}. *)
    let boot_after remove_guest =
      match
        Result.map_error
          (fun detail -> "microvm_guest_dns_unusable: " ^ detail)
          (microvm_boot_nameserver ~backend ~network_mode:t.network_mode)
      with
      | Error detail -> `Error (Network_unexpressible detail)
      | Ok nameserver ->
        (match remove_guest () with
         | Ok () ->
           (* All modes attach the same Keeper-scoped work/build volumes.
              Failed or unknown removal is not just a leaked guest: proceeding
              could recreate an attached build volume or trim a live work
              volume. Warm adoption does neither and needs no sibling cleanup. *)
           (match remove_previous_modes Keeper_types_profile_sandbox.all_network_modes with
            | Ok () -> `Boot nameserver
            | Error failure -> `Error failure)
         | Error detail -> `Error (Unadoptable_guest_not_removed detail))
    in
    let start_state =
      match
        probe_microvm_container_state
          ?timeout_sec
          ~backend
          container_name
      with
      | Ok Keeper_sandbox_runtime.Docker_container_running ->
        (match bind_registered_microvm_identity t container_name with
         | Some snapshot ->
           (match
              microvm_adoption
                ~booted:(microvm_boot container_name)
                ~image
                ~guest_size
                ~network_mode:t.network_mode
                ~bound_port:(bound_egress_proxy_port t)
            with
            | Adopt_running_guest -> `Adopt snapshot
            | Replace_running_guest reasons ->
              (* The guest is intact and its snapshot is ours, but it was not
                 booted with what the keeper asks for now: its one route
                 points at a port this process no longer holds, or it runs
                 another image or size. Adopting it keeps the keeper on the
                 old one with nothing said. Replace it. *)
              boot_after (fun () ->
                Log.Keeper.info
                  "microvm guest replaced instead of adopted keeper=%s name=%s: %s"
                  t.meta.name
                  container_name
                  (String.concat
                     "; "
                     (List.map microvm_replacement_reason_to_string reasons));
                stop_and_delete_microvm_container ?timeout_sec ~backend container_name))
         | None ->
           (* A guest from an older server process can still be running, but
              its temp snapshot capability died with that process. It is not
              safe to guess the mount or use credentials we cannot redact.
              Replace the guest with one whose snapshot this process owns. *)
           boot_after (fun () ->
             stop_and_delete_microvm_container ?timeout_sec ~backend container_name))
      | Error probe_error ->
        `Error (Guest_state_unreadable probe_error)
      | Ok Keeper_sandbox_runtime.Docker_container_stopped ->
        boot_after (fun () ->
          stop_and_delete_microvm_container ?timeout_sec ~backend container_name)
      | Ok Keeper_sandbox_runtime.Docker_container_absent ->
        boot_after (fun () -> Ok ())
    in
    match start_state with
    | `Adopt snapshot ->
      (* A running guest proves its process is up, not that its work volume
         is mounted: a guest that booted without the mount serves a writable
         rootfs directory at the same path, and every keeper write there
         evaporates on the next boot. Adopting on process state alone would
         hand turns to exactly that guest, so the mount invariant is checked
         here the same as on a fresh boot, and a guest that fails it is
         refused rather than adopted. The guest is left running for an
         operator to inspect; a later start probes again. A failed probe may
         recover without the guest being removed. *)
      (match
         ensure_microvm_work_volume_mounted ?timeout_sec t ~backend ~container_name
       with
       | Ok () -> adopt snapshot
       | Error detail -> Error (Adopted_guest_volume_unverified detail))
    | `Error error -> Error error
    | `Boot nameserver ->
      (* The current name and all previous modes are confirmed absent before
         reaching any volume operation. A record still held for this name
         describes one that stopped or vanished without passing through
         [stop_and_delete_microvm_container]. Dropped before the boot: only
         this boot's own success writes the name's record again. *)
      forget_microvm_boot container_name;
      let image_timeout =
        match timeout_sec with
        | Some sec -> sec
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()
      in
      (match
         Result.bind
           (Keeper_sandbox_microvm.image_present_for
              backend
              ~name:t.meta.sandbox_image
              ~image
              ~timeout_sec:image_timeout)
           (fun () -> microvm_guest_provisions t ~backend ~timeout_sec:image_timeout)
       with
       | Error detail -> Error (Guest_provisions_unavailable detail)
       | Ok provisions ->
         (* Reuse the snapshot a previous turn left mounted: the guest is
            keeper-lifetime, so its mounts must keep pointing at the same
            directory. Only a fresh boot builds a new one. *)
         let github_identity_result =
           match (Atomic.get t.github_identity_snapshots).current with
           | Some (Process_identity snapshot) -> Ok (snapshot, false)
           | Some (Guest_identity _) | None ->
             (match microvm_identity_snapshot container_name with
              | Some snapshot -> Ok (snapshot, false)
              | None ->
                (match
                   Keeper_github_identity.docker_args_for_tool
                     ~config:t.config
                     ~keeper_name:t.meta.name
                     ~container_masc_dir:
                       (Keeper_sandbox_runtime_setup.container_masc_dir
                          ~container_root:t.container_root)
                 with
                 | Error _ as error -> error
                 | Ok projection ->
                   let snapshot =
                     { args = projection.args
                     ; host_dir = projection.host_snapshot_dir
                     ; revision = projection.revision
                     ; cleanup = projection.cleanup
                     }
                   in
                   (match claim_microvm_identity_snapshot container_name snapshot with
                    | `Claimed -> Ok (snapshot, true)
                    | `Existing existing ->
                      snapshot.cleanup ();
                      Ok (existing, false))))
         in
         (match github_identity_result with
          | Error err ->
            Error (Github_identity_invalid err)
          | Ok (github_identity, github_identity_is_new) ->
         let release_unmounted_identity () =
           if github_identity_is_new then
             (* Snapshot cleanup removes the directory through Fs_compat,
                which can yield. Protect the registry take and that removal
                together before propagating a pre-boot cancellation. *)
             Eio.Cancel.protect (fun () ->
               release_registered_microvm_identity ~expected:github_identity container_name)
         in
         (* The network policy is spelled by the runtime, and one of the three
            cannot say every mode. Resolved before the argv so a boot refuses
            rather than handing msb Docker's flags, which it rejects at
            argument parsing with no statement of what the guest's network
            would have been. *)
         (match ensure_policy_network backend ~keeper_name:t.meta.name t.network_mode with
          | Error detail ->
            release_unmounted_identity ();
            Error (Policy_network_unavailable detail)
          | exception (Eio.Cancel.Cancelled _ as cancelled) ->
            release_unmounted_identity ();
            raise cancelled
          | Ok policy_gateway ->
         let policy_proxy =
           (* The port is read from the keeper's registry entry rather than
              carried in this state: the proxy is bound once per keeper lane
              and a guest boots per turn, so the two ends have different
              lifetimes and the entry is what both can see. *)
           match policy_gateway, bound_egress_proxy_port t with
           | Some gateway, Some port -> Some { Keeper_sandbox_microvm.gateway; port }
           (* Either half missing means the guest cannot be told its one
              route. [network_args_for] refuses on [None] rather than booting
              a guest that reaches nothing silently. *)
           | Some _, None | None, _ -> None
         in
         (match
            Keeper_sandbox_microvm.network_args_for
              backend
              ~dns:(Option.map Ipaddr.to_string nameserver)
              ~keeper_name:t.meta.name
              ~policy_proxy
              t.network_mode
          with
          | Error detail ->
            release_unmounted_identity ();
            Error (Network_unexpressible detail)
          | Ok network_args ->
         let argv_result =
           Keeper_sandbox_microvm.turn_start_argv_for
             backend
             ~container_name
             ~label_args:
               (Keeper_sandbox_runtime.docker_label_args
                  ~base_path:t.config.base_path
                  ~keeper_name:t.meta.name
                  ~container_kind:
                    Keeper_sandbox_microvm.keeper_vm_container_kind
                  ~network_label:
                    (Keeper_types_profile_sandbox.network_mode_to_string
                       t.network_mode)
                  ())
             ~uid:t.uid
             ~gid:t.gid
             ~guest_size
             ~network_args
             (* Config and the GitHub identity. Config has no cleanup, so it
                travels as-is. The identity does: the Docker lane runs that
                cleanup under [Eio_guard] at turn end, which would delete the
                credential out from under a guest that outlives the turn, so
                the guest holds its snapshot for its own lifetime instead
                ([keep] on adopt, released at teardown).

                The secret projection is still absent. It hands back the same
                turn-scoped cleanup and has no keeper-lifetime holder yet, so
                a microvm keeper reaches its connectors without it. *)
             ~mount_args:
               (Keeper_sandbox_runtime.docker_config_mount_args
                  ~base_path:t.config.base_path
                  ~container_root:t.container_root
                @ github_identity.args
                (* The working tree (RFC-0400): the keeper's checkouts live
                   on the work volume, a block device rather than the
                   virtiofs share that pinned one host vnode per file, and
                   the shim the remote lane drives is mounted read-only
                   beside its config. *)
                @ Keeper_sandbox_microvm.work_volume_mount_args
                    ~volume_name:provisions.work_volume_name
                (* Derived build output, on its own disposable volume
                   so it can be deleted and recreated without
                   touching the checkout above -- absent on backends whose
                   work volume already returns host disk on a guest
                   delete. *)
                @ (match provisions.build_volume_name with
                   | Some volume_name ->
                     Keeper_sandbox_microvm.build_volume_mount_args ~volume_name
                   | None -> [])
                @ Keeper_sandbox_microvm.shim_mount_args
                    ~host_dir:provisions.shim_host_dir)
             ~image
             (* Asked for by name, so a runtime with no flag for one of them
                refuses the boot instead of running a keeper on a weaker
                sandbox than the profile it declared. *)
             ~constraints:Keeper_microvm_backend.all_guest_constraints
           |> Result.map_error (fun refusals -> Constraints_unexpressible {backend; refusals})
         in
         (match argv_result with
          | Error failure ->
            release_unmounted_identity ();
            Error failure
          | Ok argv ->
         let booted =
           { policy_port =
               Option.map
                 (fun (proxy : Keeper_sandbox_microvm.policy_proxy) -> proxy.port)
                 policy_proxy
           ; image
           ; guest_size
           }
         in
         let st, out = run_argv_with_status ?timeout_sec argv in
         (* A guest that came up but that the runtime confirms is not
            there, or that cannot hold the keeper's root on its volume, is
            taken down again: the remote lane has nowhere to run in it, and
            leaving it would hand the next turn a guest that adopts cleanly
            and fails on every call. *)
         let take_down_after_boot ~check ~detail =
           let removed =
             match
               stop_and_delete_microvm_container
                 ?timeout_sec
                 ~backend
                 container_name
             with
             | Ok () -> true
             | Error _ -> false
           in
           if github_identity_is_new && removed
           then
             release_registered_microvm_identity
               ~expected:github_identity
               container_name;
           Error (Booted_guest_unusable { check; container_name; detail })
         in
         (match st with
          | Unix.WEXITED 0 ->
            (* Recorded as soon as the runtime says the guest booted, before
               anything below can fail. Every later failure either takes the
               guest down, which forgets the record with it, or leaves the
               guest running; a running guest this process booted with no
               record would be replaced on every start instead of adopted --
               including the one [microvm_remote_endpoint] exists to adopt,
               whose [mkdir] failed and whose take-down failed too. *)
            record_microvm_boot container_name booted;
            (* The same probe as every other step. Listed in any state, it is
               the guest this call booted; a stopped one fails the work root
               check below. Confirmed absent, it is taken down. Unknown, it is
               left running with its snapshot and record: taking down a guest
               nobody could ask about may delete one that is up. *)
            (match
               probe_microvm_container_state ?timeout_sec ~backend container_name
             with
             | Ok
                 ( Keeper_sandbox_runtime.Docker_container_running
                 | Keeper_sandbox_runtime.Docker_container_stopped ) ->
               (match
                  ensure_microvm_keeper_work_root
                    ?timeout_sec
                    t
                    ~backend
                    ~container_name
                with
                | Ok () ->
                  mark_microvm_work_root_ready container_name;
                  adopt github_identity
                | Error detail ->
                  take_down_after_boot
                    ~check:Work_root_unusable
                    ~detail)
             | Ok Keeper_sandbox_runtime.Docker_container_absent ->
               take_down_after_boot
                 ~check:Runtime_does_not_list
                 ~detail:"the runtime's listing does not name the guest"
             | Error detail -> Error (Booted_guest_state_unknown { container_name; detail }))
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
            (* Two turns of one keeper can race to boot the shared name;
               the loser's run fails on the name and the guest the winner
               booted is the one both wanted. *)
            (match
               probe_microvm_container_state
                 ?timeout_sec
                 ~backend
                 container_name
             with
             | Ok Keeper_sandbox_runtime.Docker_container_running ->
               (* No boot is recorded for this guest. [booted] is what this
                  call asked for, and the run that booted the guest may be
                  another one: an earlier start whose run timed out before
                  its guest came up, from a TOML that has changed since, or
                  a start in another server process. Nothing here tells those
                  apart from this call's own run failing while its guest came
                  up. The name's record was dropped before this boot, so the
                  next start finds none and replaces the guest rather than
                  adopting an image or size nobody can vouch for. *)
               (* The stable-name race adopted the snapshot claimed before
                  either launch. Both launch argv values therefore point at
                  the same immutable directory.

                  Running proves the winner's process is up, not that its
                  work volume is mounted -- the race loser must not reach a
                  guest the mount invariant has not verified, so it adopts
                  through the same probe as the plain adopt path. A failure
                  fails closed with the guest left running: it may be serving
                  the winner's turn off the shared snapshot, which is why the
                  registered identity is kept here as it is when the state
                  probe itself fails below. *)
               (match
                  ensure_microvm_work_volume_mounted
                    ?timeout_sec
                    t
                    ~backend
                    ~container_name
                with
                | Ok () -> adopt github_identity
                | Error detail -> Error (Adopted_guest_volume_unverified detail))
             | Ok Keeper_sandbox_runtime.Docker_container_stopped
             | Ok Keeper_sandbox_runtime.Docker_container_absent ->
               let removed =
                 match
                   stop_and_delete_microvm_container
                     ?timeout_sec
                     ~backend
                     container_name
                 with
                 | Ok () -> true
                 | Error _ -> false
               in
               if github_identity_is_new && removed
               then
                 release_registered_microvm_identity
                   ~expected:github_identity
                   container_name;
               Error (Boot_command_failed { status = st; output = out })
             | Error _ ->
               (* The guest state is unknown. Keep the registered snapshot:
                  deleting it could invalidate a mount on a guest that did
                  start even though the probe failed. Teardown owns recovery. *)
               Error (Boot_command_failed { status = st; output = out })))))))))
;;

let microvm_profile_check (meta : keeper_meta) =
  if meta.sandbox_profile = Keeper_types_profile_sandbox.Micro_vm then Ok ()
  else Error (Printf.sprintf
      "microvm_remote_endpoint_requires_microvm: keeper %s runs sandbox_profile=%s"
      meta.name (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile))

let build_microvm_endpoint
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~container_root
      ~uid
      ~gid
      ~container_name
      ~identity_environment
  =
  let open Result.Syntax in
  let* () = microvm_profile_check meta in
    let gh_config_dir =
      Keeper_github_identity.container_config_dir
        ~container_masc_dir:
          (Keeper_sandbox_runtime_setup.container_masc_dir
             ~container_root)
        ~keeper_name:meta.name
    in
    (* The exec prefix is the declaring runtime's, built here because this is
       where the runtime, the work root and the shim config path are all in
       hand. *)
    Result.bind (microvm_backend_of_meta meta) (fun backend ->
      Result.bind
        (Keeper_sandbox_microvm.shim_exec_prefix_for
           ~stdin:true
           backend
           ~container_name
           ~uid
           ~gid
           ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
           ~shim_config_path:Keeper_sandbox_microvm.shim_config_guest_path)
        (fun prefix ->
          Result.map
            (fun probe_prefix ->
              Keeper_sandbox_remote.of_container_exec
                ~base_path:config.base_path
                ~keeper_name:meta.name
                ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
                ~gh_config_dir
                ~injected_env:
                  (Keeper_sandbox_runtime.docker_config_env
                     ~base_path:config.base_path
                     ~container_root
                   @ identity_environment)
                ~env_allowlist:Keeper_sandbox_microvm.remote_env_allowlist
                ~connect_timeout_sec:Keeper_sandbox_microvm.remote_connect_timeout_sec
                ~max_concurrent_sessions:
                  Keeper_sandbox_microvm.remote_max_concurrent_sessions
                { prefix
                ; probe_prefix = Some probe_prefix
                ; container_name
                ; shim_path = Keeper_sandbox_microvm.shim_guest_path
                })
            (Keeper_sandbox_microvm.shim_exec_prefix_for
               ~stdin:false
               backend
               ~container_name
               ~uid
               ~gid
               ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
               ~shim_config_path:Keeper_sandbox_microvm.shim_config_guest_path)))
;;

type apple_guest_observation =
  | Apple_absent
  | Apple_stopped
  | Apple_running of Keeper_microvm_boot_plan.reading

let read_apple_guest ~timeout_sec ~container_name =
  let backend = Keeper_microvm_backend.Apple_container in
  let unanswered detail =
    match Keeper_microvm_guest_inventory.read ~backend ~guest_name:container_name ~timeout_sec with
    | Ok Keeper_microvm_guest_inventory.Absent -> Ok Apple_absent
    | Ok Keeper_microvm_guest_inventory.Present -> Error (Guest_state_unreadable detail)
    | Error error -> Error (Guest_state_unreadable (Keeper_microvm_guest_inventory.error_message error)) in
  match Keeper_microvm_cli_output.read ~timeout_sec
      ~argv:(Keeper_sandbox_microvm.inspect_argv_for backend ~container_name) with
  | Error error -> unanswered (Keeper_microvm_cli_output.error_message error)
  | Ok (Unix.WEXITED 0, stdout) ->
    (match Keeper_sandbox_microvm.apple_guest_facts ~container_name stdout with
     | Keeper_microvm_boot_plan.Unreadable detail ->
       Error (Guest_state_unreadable detail)
     | Keeper_microvm_boot_plan.Facts _ as reading ->
       match Keeper_sandbox_microvm.running_of_inspect_json_for backend stdout with
       | Ok false -> Ok Apple_stopped
       | Ok true -> Ok (Apple_running reading)
       | Error _ -> Error (Guest_state_unreadable "runtime inspect did not report a valid guest state"))
  | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _) ->
    unanswered "runtime inspect did not complete successfully"

(* OCI Entrypoint belongs to the actual image configuration, not the caller's
   requested command or a prefix guessed from the guest's init process. Keep
   this read-only observation separate from the stable requested-plan digest. *)
let read_apple_image_command ~timeout_sec ~(plan : Keeper_microvm_boot_plan.t) reading =
  match reading with
  | Keeper_microvm_boot_plan.Unreadable detail -> Error detail
  | Keeper_microvm_boot_plan.Facts facts ->
    match Keeper_microvm_cli_output.read ~timeout_sec
        ~argv:(Keeper_sandbox_microvm.image_inspect_argv_for Keeper_microvm_backend.Apple_container
          ~image:plan.image) with
    | Error error -> Error (Keeper_microvm_cli_output.error_message error)
    | Ok (Unix.WEXITED 0, raw) ->
      Keeper_microvm_image_command.of_apple_inspect ~reference:plan.image
        ~identity:facts.image_identity raw
      |> Result.map_error Keeper_microvm_image_command.error_message
    | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _) ->
      Error "image inspect did not complete successfully"

(* A guest's environment is observed data, never the expected route. Read
   the current policy network without creating or repairing it at adoption. *)
let apple_policy_environment ~timeout_sec (t : t) =
  let open Result.Syntax in
  match t.network_mode with
  | Keeper_types_profile_sandbox.Network_none | Keeper_types_profile_sandbox.Network_inherit -> Ok []
  | Keeper_types_profile_sandbox.Network_policy ->
    match bound_egress_proxy_port t with
    | None -> Ok []
    | Some port ->
      let* argv = Keeper_sandbox_microvm.policy_network_inspect_argv_for
          Keeper_microvm_backend.Apple_container ~keeper_name:t.meta.name
        |> Result.map_error (fun detail -> Policy_network_unavailable detail) in
      let* status, stdout = Keeper_microvm_cli_output.read ~timeout_sec ~argv
        |> Result.map_error (fun error -> Policy_network_unavailable
            (Keeper_microvm_cli_output.error_message error)) in
      match status with
      | Unix.WEXITED 0 ->
        let* gateway = Keeper_sandbox_microvm.policy_network_gateway ~inspect:stdout
          |> Result.map_error (fun detail -> Policy_network_unavailable detail) in
        Ok (Egress_proxy_decision.client_env ~proxy_url:(Printf.sprintf "http://%s:%d" gateway port))
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
        Error (Policy_network_unavailable "policy network inspect did not complete successfully")

let with_apple_lifecycle_scope ~keeper_name ~unavailable callback =
  match Fs_compat.execution_context (), Fs_compat.get_fs_opt () with
  | Fs_compat.Eio_fiber, Some fs ->
    Keeper_microvm_lifecycle.with_keeper_scope microvm_lifecycle ~keeper_name
      (fun scope -> callback ~fs ~scope)
  | Fs_compat.Non_eio, _ | Fs_compat.Eio_fiber, None -> Error unavailable

let prepare_apple_first_handoff ~timeout_sec (t : t) snapshot ~container_name =
  let open Result.Syntax in
  let backend = Keeper_microvm_backend.Apple_container in
  let* () = ensure_apple_volume_helpers_absent ~keeper_name:t.meta.name ~timeout_sec
    |> Result.map_error (fun detail -> Adopted_guest_volume_unverified detail) in
  let* () = Keeper_microvm_shim_readiness.verify ~base_path:t.config.base_path
      ~backend ~guest_name:container_name
    |> Result.map_error (fun error -> Guest_provisions_unavailable
        (Keeper_microvm_shim_readiness.error_message error)) in
  let* () = ensure_microvm_keeper_work_root ~timeout_sec t ~backend ~container_name
    |> Result.map_error (fun detail -> Adopted_guest_volume_unverified detail) in
  if not (microvm_work_root_ready container_name) then (
    let container_config_dir = Keeper_github_identity.container_config_dir
        ~container_masc_dir:(Keeper_sandbox_runtime_setup.container_masc_dir ~container_root:t.container_root)
        ~keeper_name:t.meta.name in
    let endpoint = build_microvm_endpoint ~config:t.config ~meta:t.meta
        ~container_root:t.container_root ~uid:t.uid ~gid:t.gid ~container_name
        ~identity_environment:(Keeper_microvm_github_identity.environment snapshot ~container_config_dir) in
    (match endpoint with
     | Error detail -> Log.Keeper.warn ~keeper_name:t.meta.name
         "first handoff build cleanup endpoint unavailable: %s" detail
     | Ok endpoint ->
       let receipt = ref (Keeper_sandbox_remote.Execution_unavailable Keeper_sandbox_remote.Request_not_sent) in
       let run = Keeper_sandbox_remote.runner ~timeout_sec
           ~on_receipt:(fun observation -> receipt := observation) endpoint in
       let script = Keeper_sandbox_microvm.first_handoff_build_cleanup_script
           ~keeper_work_root:(Keeper_sandbox_microvm.keeper_work_root ~keeper_name:t.meta.name) in
       let outcome = run ~on_stdout_chunk:None ~on_stderr_chunk:None
           ~stdin_content:None ~env:[||] ~cwd:None ~argv:["/bin/sh"; "-eu"; "-c"; script] in
       (match outcome, !receipt with
        | Masc_exec.Sandbox_target.Ran {status=Unix.WEXITED 0; _},
          Keeper_sandbox_remote.Execution_observed _ -> ()
        | Masc_exec.Sandbox_target.Transport_failed _, _
        | Masc_exec.Sandbox_target.Ran _, Keeper_sandbox_remote.Execution_unavailable _
        | Masc_exec.Sandbox_target.Ran {status=(Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _); _},
          Keeper_sandbox_remote.Execution_observed _ ->
          Log.Keeper.warn ~keeper_name:t.meta.name
            "first handoff build cleanup did not confirm success; link scan will preserve remaining real build directories"));
    mark_microvm_work_root_ready container_name);
  (match microvm_work_root_entry container_name with
   | Some { generation; build_links_state = Build_links_not_prepared; _ } ->
     ensure_microvm_build_links ~timeout_sec t ~container_name ~generation
   | Some { build_links_state = (Build_links_effect_unverified | Build_links_prepared); _ }
   | None -> ());
  Ok ()

let start_apple_microvm_container ~fs ~scope ~timeout_sec (t : t) =
  let open Result.Syntax in
  let module Store = Keeper_microvm_github_identity in
  let module Plan = Keeper_microvm_boot_plan in
  let backend = Keeper_microvm_backend.Apple_container in
  let* image = t.image |> Result.map_error (fun error -> Image_unresolved error) in
  let* guest_size = Env_config_sandbox.Runtime.microvm_guest_size
      ~memory:t.meta.microvm_memory ~cpus:t.meta.microvm_cpus
    |> Result.map_error (fun detail -> Guest_size_invalid detail) in
  let container_name = keeper_vm_name t in
  let* observation = read_apple_guest ~timeout_sec ~container_name in
  let* () = match observation with
    | Apple_running (Plan.Unreadable detail) -> Error (Guest_facts_refused (Plan.Guest_facts_unreadable detail))
    | Apple_running (Plan.Facts _) | Apple_absent | Apple_stopped -> Ok () in
  let stored = Store.load ~fs ~coordinator:microvm_lifecycle ~scope
      ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend ~network_mode:t.network_mode in
  let container_config_dir = Keeper_github_identity.container_config_dir
      ~container_masc_dir:(Keeper_sandbox_runtime_setup.container_masc_dir ~container_root:t.container_root)
      ~keeper_name:t.meta.name in
  let* identity_environment = match stored with
    | Ok (Some snapshot) -> Ok (Store.environment snapshot ~container_config_dir)
    | Ok None | Error _ ->
      Keeper_github_identity.capture_tool_identity ~config:t.config ~keeper_name:t.meta.name
      |> Result.map (fun captured -> Keeper_github_identity.captured_environment captured
          ~keeper_name:t.meta.name ~container_config_dir)
      |> Result.map_error (fun detail -> Github_identity_invalid detail) in
  (* Observe optional config and stable workspace labels at the edge once.
     Comparison and a possible Boot retain this exact immutable request. *)
  let config_mount = Keeper_sandbox_runtime_setup.config_mount
      ~base_path:t.config.base_path ~container_root:t.container_root in
  let stable_labels = Keeper_sandbox_runtime_setup.stable_labels
      ~base_path:t.config.base_path ~keeper_name:t.meta.name
      ~container_kind:Keeper_sandbox_microvm.keeper_vm_container_kind
      ~network_label:(Keeper_types_profile_sandbox.network_mode_to_string t.network_mode) in
  let identity_host_dir = Store.host_path ~base_path:t.config.base_path
      ~keeper_name:t.meta.name ~backend ~network_mode:t.network_mode in
  let* plan = requested_apple_plan t ~image ~guest_size ~identity_host_dir
      ~environment:identity_environment ~config_mount ~stable_labels in
  let* () = Plan.validate plan |> Result.map_error (fun errors -> Invalid_boot_plan errors) in
  let identity_reading = match stored with
    | Ok (Some _) -> Plan.Identity_readable
    | Ok None | Error _ -> Plan.Identity_unreadable in
  let adopt snapshot =
    let* () = prepare_apple_first_handoff ~timeout_sec t snapshot ~container_name in
    bind_github_identity_snapshot t (Guest_identity snapshot);
    set_state t (Running {container_name});
    Ok container_name in
  let decision = match observation with
    | Apple_absent | Apple_stopped -> Ok `Boot
    | Apple_running reading ->
      let* policy_environment = match reading with
        | Plan.Unreadable _ -> Ok []
        | Plan.Facts facts when facts.plan_label <> Some (Plan.digest plan) -> Ok []
        | Plan.Facts _ -> apple_policy_environment ~timeout_sec t in
      let image_command = read_apple_image_command ~timeout_sec ~plan reading in
      match Plan.assess ~plan ~policy_environment ~identity_reading ~image_command reading with
      | Plan.Refuse refusal -> Error (Guest_facts_refused refusal)
      | Plan.Replace _ -> Ok `Boot
      | Plan.Matches_plan -> Ok `Adopt in
  let* decision = decision in
  match decision with
  | `Adopt ->
    (match stored with
     | Ok (Some snapshot) -> adopt snapshot
     | Ok None -> Error (Github_identity_invalid "validated guest identity is missing")
     | Error error -> Error (Guest_identity_store_unavailable error))
  | `Boot ->
    (* Refuse before stopping or replacing any existing guest when a legacy
       helper is present or its owner is unknown. Provisioning reads again
       after teardown; neither read fences another process between them. *)
    let* () = ensure_apple_volume_helpers_absent ~keeper_name:t.meta.name ~timeout_sec
      |> Result.map_error (fun detail -> Guest_provisions_unavailable detail) in
    (* A stable name can now be absent after an external removal. Readiness
       belongs to the old guest and cannot authorize the new build volume. *)
    forget_microvm_work_root container_name;
    forget_microvm_boot container_name;
    Keeper_microvm_shim_readiness.forget ~backend ~guest_name:container_name;
    let* nameserver = microvm_boot_nameserver ~backend ~network_mode:t.network_mode
      |> Result.map_error (fun detail -> Network_unexpressible detail) in
    let* () = List.fold_left (fun previous network_mode ->
        let* () = previous in
        if network_mode = t.network_mode then Ok ()
        else
          let stale_name = microvm_container_name ~config:t.config ~keeper_name:t.meta.name ~network_mode in
          let* stale = read_apple_guest ~timeout_sec ~container_name:stale_name in
          let* () = match stale with
            | Apple_absent -> Ok ()
            | Apple_running (Plan.Unreadable detail) ->
              Error (Guest_facts_refused (Plan.Guest_facts_unreadable detail))
            | Apple_running (Plan.Facts _) | Apple_stopped ->
              stop_and_delete_microvm_container ~timeout_sec ~backend stale_name
              |> Result.map_error (fun detail -> Unadoptable_guest_not_removed detail) in
          Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle ~scope
            ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend ~network_mode ~timeout_sec
          |> Result.map (function
            | Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent -> ())
          |> Result.map_error (fun error -> Guest_identity_store_unavailable error))
        (Ok ()) Keeper_types_profile_sandbox.all_network_modes in
    let* () = match observation with
      | Apple_absent -> Ok ()
      | Apple_running _ | Apple_stopped ->
        stop_and_delete_microvm_container ~timeout_sec ~backend container_name
        |> Result.map_error (fun detail -> Unadoptable_guest_not_removed detail) in
    let* _removed = Store.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle ~scope
        ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend
        ~network_mode:t.network_mode ~timeout_sec
      |> Result.map_error (fun error -> Guest_identity_store_unavailable error) in
    let* captured = Keeper_github_identity.capture_tool_identity ~config:t.config ~keeper_name:t.meta.name
      |> Result.map_error (fun detail -> Github_identity_invalid detail) in
    let* snapshot = Store.publish_if_guest_absent ~fs ~coordinator:microvm_lifecycle ~scope
        ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend
        ~network_mode:t.network_mode ~timeout_sec captured
      |> Result.map_error (fun error -> Guest_identity_store_unavailable error) in
    let boot_environment = Store.environment snapshot ~container_config_dir in
    if boot_environment <> plan.environment then
      Error (Github_identity_invalid "identity wiring changed while preparing the guest; retry with a new request")
    else
      let* () = Keeper_sandbox_microvm.image_present_for backend ~name:t.meta.sandbox_image
          ~image ~timeout_sec |> Result.map_error (fun detail -> Guest_provisions_unavailable detail) in
      let* _provisions = microvm_guest_provisions t ~backend ~timeout_sec
        |> Result.map_error (fun detail -> Guest_provisions_unavailable detail) in
      let* gateway = ensure_policy_network backend ~keeper_name:t.meta.name t.network_mode
        |> Result.map_error (fun detail -> Policy_network_unavailable detail) in
      let policy_proxy = match gateway, bound_egress_proxy_port t with
        | Some gateway, Some port -> Some {Keeper_sandbox_microvm.gateway; port}
        | Some _, None | None, _ -> None in
      let* argv = Keeper_sandbox_microvm.apple_turn_start_argv ~container_name ~plan
          ~lifecycle_labels:(Keeper_sandbox_runtime_setup.lifecycle_labels ())
          ~dns:(Option.map Ipaddr.to_string nameserver) ~policy_proxy
        |> Result.map_error (function
          | Keeper_sandbox_microvm.Apple_invalid_boot_plan errors -> Invalid_boot_plan errors
          | Keeper_sandbox_microvm.Apple_network_unavailable detail -> Network_unexpressible detail
          | Keeper_sandbox_microvm.Apple_constraints_unexpressible refusals ->
            Constraints_unexpressible {backend; refusals}) in
      bind_github_identity_snapshot t (Guest_identity snapshot);
      let status, output = run_argv_with_status ~timeout_sec argv in
      let* postboot = read_apple_guest ~timeout_sec ~container_name in
      match postboot with
      | Apple_running reading ->
        let policy_environment = match policy_proxy with
          | None -> []
          | Some {gateway; port} -> Egress_proxy_decision.client_env
              ~proxy_url:(Printf.sprintf "http://%s:%d" gateway port) in
        let image_command = read_apple_image_command ~timeout_sec ~plan reading in
        (match Plan.assess ~plan ~policy_environment ~identity_reading:Plan.Identity_readable ~image_command reading with
         | Plan.Matches_plan -> adopt snapshot
         | Plan.Refuse refusal -> Error (Guest_facts_refused refusal)
         | Plan.Replace _ -> Error (Guest_facts_refused
             (Plan.Runtime_reports_other_than_asked [Plan.Plan_label])))
      | Apple_absent | Apple_stopped -> Error (Boot_command_failed {status; output})

let sweep_abandoned_microvm_guests
    ~base_path ~command_available ~timeout_sec ~is_pid_alive ~run_argv =
  let module Inventory = Keeper_microvm_guest_inventory in
  let module Declarations = Keeper_microvm_declared_guests in
  let backend = Keeper_microvm_backend.Apple_container in
  let outcomes, removed = with_microvm_inventory_lock (fun () ->
    let other = sweep_process_bound_microvm_guests ~base_path ~command_available
        ~timeout_sec ~is_pid_alive ~run_argv in
    if not (command_available (Keeper_microvm_backend.cli_name backend)) then other, []
    else
      let removed = ref [] in
      let failed = ref [] in
      let declarations = ref (Declarations.read ~base_path) in
      let inventory = Inventory.read_apple ~timeout_sec in
      (match inventory with
       | Error error ->
         failed := ["inventory", Inventory.error_message error]
       | Ok inventory ->
         (match !declarations with
          | Error error -> failed := ["declarations", Declarations.unavailable_message error]
          | Ok _ -> ());
         List.iter (fun row ->
           match Declarations.select ~base_path ~declarations:!declarations row with
           | Declarations.Preserve _ -> ()
           | Declarations.Delete candidate ->
             let current = match !declarations with
               | Error _ as error -> error
               | Ok observed -> Result.map (fun () -> observed) (Declarations.revalidate observed) in
             declarations := current;
             (match current with
              | Error error -> failed := (candidate.guest_name, Declarations.unavailable_message error) :: !failed
              | Ok _ ->
                (* Delete is an effect attempt. Only a new actual complete
                   inventory can establish the postcondition, regardless of
                   the command's status or capture availability. *)
                let deletion = Keeper_microvm_cli_output.read ~timeout_sec
                    ~argv:(Keeper_sandbox_microvm.delete_force_argv_for backend ~container_name:candidate.guest_name) in
                match Inventory.read ~backend ~guest_name:candidate.guest_name ~timeout_sec with
                | Ok Inventory.Absent ->
                  forget_microvm_work_root candidate.guest_name;
                  forget_microvm_boot candidate.guest_name;
                  Keeper_microvm_shim_readiness.forget ~backend ~guest_name:candidate.guest_name;
                  removed := candidate :: !removed
                | Ok Inventory.Present ->
                  let detail = match deletion with
                    | Error error -> Keeper_microvm_cli_output.error_message error
                    | Ok (status, _) -> "guest remains after deletion " ^ Keeper_sandbox_exec_failure.status_label status in
                  failed := (candidate.guest_name, detail) :: !failed
                | Error error -> failed := (candidate.guest_name, Inventory.error_message error) :: !failed))
           (Inventory.rows inventory));
      let removed = List.rev !removed in
      let outcome : Keeper_sandbox_microvm.sweep_outcome =
        {removed=List.map (fun (candidate : Declarations.candidate) -> candidate.guest_name) removed;
         failed=List.rev !failed} in
      (backend, outcome) :: other, removed) in
  (* Snapshot cleanup takes a fresh Keeper owner after inventory exclusion has
     ended. Reacquiring a Keeper inside that exclusion would deadlock. The store
     independently rereads actual absence; the earlier result is not a token. *)
  let cleanup_failures = List.concat_map (fun (candidate : Declarations.candidate) ->
    List.filter_map (fun network_mode ->
      let name = Keeper_sandbox_container_name.make
          (Keeper_sandbox_container_name.Micro_vm_persistent
             {base_path; keeper_name=candidate.keeper_name; network_mode})
        |> Keeper_sandbox_container_name.to_string in
      if not (String.equal name candidate.guest_name) then None
      else
        let result = with_apple_lifecycle_scope ~keeper_name:candidate.keeper_name
            ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
            (fun ~fs ~scope ->
              Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle
                ~scope ~base_path ~keeper_name:candidate.keeper_name ~backend ~network_mode ~timeout_sec
              |> Result.map_error Keeper_microvm_github_identity.error_message) in
        match result with
        | Ok (Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent) -> None
        | Error detail -> Some (candidate.guest_name, detail))
      Keeper_types_profile_sandbox.all_network_modes) removed in
  List.map (fun (runtime, (outcome : Keeper_sandbox_microvm.sweep_outcome)) ->
    if runtime = backend then runtime, {outcome with failed=outcome.failed @ cleanup_failures}
    else runtime, outcome) outcomes

let start_microvm_container ?timeout_sec t =
  let result = match microvm_backend_of t with
    | Error detail -> Error (Backend_unresolved detail)
    | Ok Keeper_microvm_backend.Apple_container ->
      let timeout_sec = match timeout_sec with
        | Some seconds -> seconds
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io () in
      with_apple_lifecycle_scope ~keeper_name:t.meta.name ~unavailable:Runtime_context_unavailable
        (fun ~fs ~scope -> start_apple_microvm_container ~fs ~scope ~timeout_sec t)
    | Ok (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
      with_microvm_lifecycle_lock ~keeper_name:t.meta.name ~operation:"start_adopt"
        (fun () -> start_process_bound_microvm_container ?timeout_sec t) in
  Result.map_error microvm_start_failure_cause result
;;

(* Shutdown finalization retains the typed backend through registry removal.
   A remote-SSH keeper owns no local container, while Docker and
   microVM names project to different runtimes and must not probe each other. *)
let teardown_keeper_sandbox_by_name
      ?timeout_sec
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(backend : Keeper_sandbox.backend)
      ?microvm_backend
      ()
  =
  let helper_timeout_sec =
    match timeout_sec with
    | Some seconds -> seconds
    | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()
  in
  let timeout_sec =
    Option.value
      timeout_sec
      ~default:
        (Env_config_sandbox.Shell_timeout.timeout_sec
           ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
           ())
  in
  match backend with
  | Keeper_sandbox.Remote_ssh -> Ok ()
  | Keeper_sandbox.Docker ->
    Keeper_sandbox_runtime.remove_persistent_containers
      ~keeper_name
      ~base_path:config.base_path
      ~timeout_sec
      ()
  | Keeper_sandbox.Micro_vm ->
    (* Teardown runs after the registry entry is gone, so there is no meta
       left to read the backend from. The caller passes the one the keeper
       declared; shutdown supplies it from the meta it still holds. Without
       it there is nothing to remove the guest with -- an assumed runtime
       would send `container delete --force` to a guest msb booted and
       report success while it kept running. *)
    (match microvm_backend with
     | None ->
       Error
         (Printf.sprintf
            "microvm_teardown_backend_unresolved: keeper %s's guest cannot be \
             removed without the runtime it was booted on; the caller passes it \
             from the keeper's meta"
            keeper_name)
     | Some microvm_backend ->
       (* Every mode's name, not the current one. The guest name carries the
          network mode so adopt cannot cross modes, and teardown runs after
          the registry entry is gone -- it does not know which mode the guest
          on disk was booted under. Removing only today's name would leave a
          guest from yesterday's mode running with nothing tracking it.

          A name with no guest behind it is not an error: [stop_and_delete]
          is idempotent for an absent guest, which is what makes sweeping the
          whole set cheap. *)
       let guests = List.map (fun network_mode ->
           network_mode, microvm_container_name ~config ~keeper_name ~network_mode)
           Keeper_types_profile_sandbox.all_network_modes in
       let perform release_identity =
         let helper_observation = match microvm_backend with
           | Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata -> Ok ()
           | Keeper_microvm_backend.Apple_container ->
             ensure_apple_volume_helpers_absent ~keeper_name ~timeout_sec:helper_timeout_sec in
         let guest_cleanup = List.fold_left (fun previous (network_mode, guest_name) ->
             let current = Result.bind
                 (stop_and_delete_microvm_container ~timeout_sec ~backend:microvm_backend guest_name)
                 (fun () -> release_identity ~network_mode ~guest_name) in
             match previous, current with
             | Ok (), result -> result
             | Error _, Ok () -> previous
             | Error _, Error detail ->
               Log.Keeper.warn "microvm teardown %s additional cleanup failed: %s" keeper_name detail;
               previous) (Ok ()) guests in
         match guest_cleanup, helper_observation with
         | (Error _ as error), Error helper_detail ->
           Log.Keeper.warn
             "microvm teardown %s: guest removal failed; helper observation also failed: %s"
             keeper_name helper_detail;
           error
         | (Error _ as error), Ok () -> error
         | Ok (), helper_observation -> helper_observation in
       match microvm_backend with
       | Keeper_microvm_backend.Apple_container ->
         with_apple_lifecycle_scope ~keeper_name
           ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
           (fun ~fs ~scope -> perform (fun ~network_mode ~guest_name:_ ->
             Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle
               ~scope ~base_path:config.base_path ~keeper_name ~backend:microvm_backend
               ~network_mode ~timeout_sec
             |> Result.map (function
               | Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent -> ())
             |> Result.map_error Keeper_microvm_github_identity.error_message))
       | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
         with_microvm_lifecycle_lock ~keeper_name ~operation:"teardown" (fun () ->
           perform (fun ~network_mode:_ ~guest_name ->
             release_registered_microvm_identity guest_name; Ok ())))
;;

(* Separate from the teardown because a paused keeper is torn down too and
   must come back to its work volume. Only dissolution calls this, after the
   teardown has removed the guest that held the volumes. *)
let remove_keeper_volumes_by_name
      ?timeout_sec
      ~(keeper_name : string)
      ~(backend : Keeper_sandbox.backend)
      ?microvm_backend
      ()
  =
  let _ = timeout_sec in
  match backend with
  | Keeper_sandbox.Docker | Keeper_sandbox.Remote_ssh -> Ok ()
  | Keeper_sandbox.Micro_vm ->
    (match microvm_backend with
     | None ->
       Error
         (Printf.sprintf
            "microvm_volume_removal_backend_unresolved: keeper %s's volumes \
             cannot be removed without the runtime that created them"
            keeper_name)
     | Some Keeper_microvm_backend.Apple_container ->
       (* Work and build names contain the Keeper name but not its workspace.
          A dormant Keeper in another workspace can still own these disks,
          even if no live guest currently mounts either one. *)
       Error
         (Printf.sprintf
            "microvm_volume_removal_owner_unverified: keeper %s's Apple volumes \
             may be shared by another workspace; automatic deletion was skipped"
            keeper_name)
     | Some
         ((Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata) as
          microvm_backend) ->
       (* Both create the work volume as a host directory, but no removal
          spelling is established for either. Name what is left instead of
          reporting a removal that did not happen. *)
       Error
         (Printf.sprintf
            "microvm_volume_removal_not_established: keeper %s's work volume \
             on %s, if present, was not removed; verify ownership across \
             workspaces before deleting it"
            keeper_name
            (Keeper_microvm_backend.to_string microvm_backend)))
;;

let teardown_keeper_sandbox
      ?timeout_sec
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ()
  =
  teardown_keeper_sandbox_by_name
    ?timeout_sec
    ~config
    ~keeper_name:meta.name
    ~backend:meta.sandbox_profile
    (* The meta is still here, so the runtime the guest was booted on travels
       with the removal. Without it a microsandbox guest would be sent
       [container delete --force] and survive its own teardown. *)
    ?microvm_backend:meta.microvm_backend
    ()
;;

let start_container ?timeout_sec (t : t) =
  if is_microvm t
  then start_microvm_container ?timeout_sec t
  else
  (* Only the two refusals of the GitHub identity below blame the Keeper's
     login; every other failure is the container's. *)
  let sandbox_failed detail = Error (Sandbox_unavailable detail) in
  match t.image with
  | Error error -> sandbox_failed (image_unresolved_message error)
  | Ok image ->
  let container_name = docker_container_name_for_image t ~image in
  let probe_state () =
    Keeper_sandbox_runtime.probe_container_state_optional
      ~container_name
      ?timeout_sec
      ()
  in
  let adopt_running () =
    (* The mount is the live config directory, so a login that happened while
       no turn was watching only needs the derived gitconfig rewritten; the
       env baked at creation keeps pointing at the same file. A malformed
       identity state is a typed error here exactly as it is at creation. *)
    match
      Keeper_github_identity.refresh_git_credential_config
        ~config:t.config
        ~keeper_name:t.meta.name
    with
    | Error err ->
      Error
        (Identity_unavailable
           ("docker_container_adopt_failed: github_identity_invalid: " ^ err))
    | Ok _has_git_wiring ->
      set_state t (Running { container_name });
      Ok container_name
  in
  (* Creation is the only path that needs the image, the runtime hardening
     args, and the projections; adoption amortises all of it. *)
  let create () =
    (
      match
        Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class_optional
          ~image
          ?timeout_sec
          ()
      with
      | Error failure ->
        sandbox_failed (Keeper_sandbox_runtime.image_preflight_start_error failure)
      | Ok () ->
        match
          Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime_optional
            ?timeout_sec ()
        with
        | Error detail -> sandbox_failed detail
        | Ok seccomp_args ->
        match Keeper_sandbox_runtime.docker_network_args t.network_mode with
        | Error msg -> sandbox_failed msg
        | Ok (network_args, network_label) ->
        (match
           Keeper_sandbox_runtime.docker_user_identity_mount_args
             ~host_root:t.host_root
             ~uid:t.uid
             ~gid:t.gid
         with
         | Error detail -> sandbox_failed detail
         | Ok identity_mounts ->
         (match
            Keeper_secret_projection.docker_args_for_keeper
              ~base_path:t.config.base_path
              ~keeper_name:t.meta.name
              ~container_name
              ()
          with
          | Error err ->
            sandbox_failed ("docker_container_start_failed: secret_projection: " ^ err)
          | Ok secret_projection ->
           (match
              Keeper_github_identity.docker_args_persistent
                ~config:t.config
                ~keeper_name:t.meta.name
                ~container_masc_dir:
                  (Keeper_sandbox_runtime_setup.container_masc_dir
                     ~container_root:t.container_root)
            with
            | Error err ->
              Eio_guard.protect
                ~finally:secret_projection.cleanup
                (fun () ->
                   Error
                     (Identity_unavailable
                        ("docker_container_start_failed: github_identity_invalid: "
                         ^ err)))
            | Ok github_identity_args ->
            Eio_guard.protect
              ~finally:secret_projection.cleanup
              (fun () ->
              (* No [--rm]: the container outlives the turn, and auto-remove
                 on stop would destroy state a later turn expects to adopt.
                 Removal is the keeper's teardown, not the daemon's. *)
              Keeper_sandbox_runtime_setup.refuse_real_daemon_under_test
                ~what:"start a persistent container";
              let argv =
                Keeper_sandbox_runtime.docker_command_argv ()
                @ [ "run"; "-d"; "--name"; container_name ]
                @ Keeper_sandbox_runtime.docker_run_pull_never_args ()
                @ Keeper_sandbox_runtime.docker_label_args
                    ~base_path:t.config.base_path
                    ~keeper_name:t.meta.name
                    ~container_kind:Keeper_sandbox_runtime.persistent_container_kind
                    ~network_label
                    ()
                @ [ "--user"; Printf.sprintf "%d:%d" t.uid t.gid ]
                @ Keeper_sandbox_runtime.docker_sandbox_env_args
                    ~base_path:t.config.base_path
                    ~container_root:t.container_root
                @ Keeper_sandbox_runtime.docker_nofile_args ()
                @ Env_config_sandbox.Hardening.read_only_rootfs_args ()
                @ [ "--tmpfs"
                  ; Env_config_sandbox.Hardening.tmpfs_mount ()
                  ; "--cap-drop=ALL"
                  ; "--security-opt"
                  ; "no-new-privileges"
                  ]
                @ seccomp_args
                @ [ "--pids-limit"
                  ; string_of_int (Env_config_sandbox.Hardening.pids_limit ())
                  ; "--memory"
                  ; Env_config_sandbox.Hardening.memory ()
                  ; "-v"
                  ; t.host_root ^ ":" ^ t.container_root ^ ":rw"
                  ; "--workdir"
                  ; t.container_root
                  ]
                @ Keeper_sandbox_runtime.docker_config_mount_args
                    ~base_path:t.config.base_path
                    ~container_root:t.container_root
                @ Keeper_sandbox_runtime.docker_workspace_state_mount_args
                    ~base_path:t.config.base_path
                    ~container_root:t.container_root
                @ secret_projection.docker_args
                @ github_identity_args
                @ identity_mounts
                @ network_args
                @ [ image; "tail"; "-f"; "/dev/null" ]
              in
              let st, out = run_argv_with_status ?timeout_sec argv in
              match st with
              | Unix.WEXITED 0 ->
                (* The same probe the start began with. Listed in any state,
                   it is the container this run made. *)
                (match probe_state () with
                 | Ok
                     ( Keeper_sandbox_runtime.Docker_container_running
                     | Keeper_sandbox_runtime.Docker_container_stopped ) ->
                   set_state t (Running { container_name });
                   Ok container_name
                 | Ok Keeper_sandbox_runtime.Docker_container_absent ->
                   (* The daemon does not list the container its run reported.
                      t.state stays Not_started, so the name is removed here,
                      best effort, rather than left for nothing to reclaim. *)
                   let rm_argv =
                     Keeper_sandbox_runtime.docker_remove_argv container_name
                   in
                   let _rm_st, _rm_out =
                     run_argv_with_status ?timeout_sec rm_argv
                   in
                   sandbox_failed
                     (Printf.sprintf
                        "docker_container_absent_after_run: docker run exited 0 \
                         and the daemon does not list %s"
                        container_name)
                 | Error probe_error ->
                   (* The daemon could not be asked. The container this run
                      made may be up, so it is not removed: the next start
                      probes the stable name again and adopts it. *)
                   sandbox_failed
                     (Printf.sprintf
                        "docker_container_state_unknown_after_run: %s"
                        (Exec_policy.truncate_for_log probe_error)))
              | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
                (match probe_state () with
                 | Ok Keeper_sandbox_runtime.Docker_container_running ->
                   (* Another turn or server of this keeper booted the shared
                      name between the absent probe and this run; the run's
                      name loss is the winner's, and this call adopts the
                      winner. *)
                   adopt_running ()
                 | ( Ok
                       ( Keeper_sandbox_runtime.Docker_container_stopped
                       | Keeper_sandbox_runtime.Docker_container_absent )
                   | Error _ ) as container_state ->
                   sandbox_failed
                     (Keeper_sandbox_exec_failure.docker_run_failure_message
                        ~prefix:"docker_container_start_failed"
                        ~base_path_hash:
                          (Keeper_sandbox_runtime.base_path_hash t.config.base_path)
                        ~keeper_name:t.meta.name
                        ~container_kind:
                          Keeper_sandbox_runtime.persistent_container_kind
                        ~network_label:(network_mode_to_string t.network_mode)
                        ~image
                        ~status:st
                        ~container_state
                        ~output:out
                        ())))))))
  in
  match probe_state () with
  | Ok Keeper_sandbox_runtime.Docker_container_running -> adopt_running ()
  | Error probe_error ->
    sandbox_failed
      (Printf.sprintf
         "docker_container_probe_failed: %s"
         (Exec_policy.truncate_for_log probe_error))
  | Ok Keeper_sandbox_runtime.Docker_container_stopped ->
    (* A stopped container keeps its filesystem layer: [docker start] resumes
       it instead of losing the installed state the persistence exists to
       keep. A start failure (image evicted from the daemon, mount source
       vanished) falls through to remove-and-recreate. *)
    let start_argv =
      Keeper_sandbox_runtime.docker_command_argv ()
      @ [ "start"; container_name ]
    in
    let start_st, _start_out =
      run_argv_with_status ?timeout_sec start_argv
    in
    if start_st = Unix.WEXITED 0
    then (
      match
        inspect_container_exists ?timeout_sec container_name
      with
      | Ok () -> adopt_running ()
      | Error inspect_out ->
        sandbox_failed
          (Printf.sprintf
             "docker_container_start_failed: restarted %s but inspect cannot \
              see it: %s"
             container_name
             (Exec_policy.truncate_for_log inspect_out)))
    else (
      let rm_argv =
        Keeper_sandbox_runtime.docker_remove_argv container_name
      in
      let _rm_st, _rm_out = run_argv_with_status ?timeout_sec rm_argv in
      create ())
  | Ok Keeper_sandbox_runtime.Docker_container_absent -> create ()
;;

let ensure_started_with_cause ?(validate_running = false) ?timeout_sec (t : t) =
  match get_state t with
  | Running { container_name } ->
    if not validate_running
    then Ok container_name
    else (
      (* Validation is asked for only by the Docker exec entrypoints, after
         [docker_exec_only] has refused a microvm runtime. *)
      match inspect_container_running ?timeout_sec container_name with
      | Ok () -> Ok container_name
      | Error _ ->
        set_state t Not_started;
        start_container ?timeout_sec t)
  | Not_started -> start_container ?timeout_sec t
;;

(* The exec entrypoints report every start failure as one message. Only the
   identity preparation reads which side failed. *)
let ensure_started ?validate_running ?timeout_sec (t : t) =
  Result.map_error github_identity_preparation_error_message
    (ensure_started_with_cause ?validate_running ?timeout_sec t)
;;

(* Endpoint admission reads the mounted identity and verifies the shared shim.
   It never starts a guest or prepares build output on behalf of attached reads. *)
let microvm_remote_endpoint_of_running_fields
      ~(config : Workspace.config) ~(meta : keeper_meta) ~network_mode ~container_root
      ~uid ~gid ~container_name =
  let open Result.Syntax in
  let* () = microvm_profile_check meta in
  let* backend = microvm_backend_of_meta meta in
  let container_config_dir = Keeper_github_identity.container_config_dir
      ~container_masc_dir:(Keeper_sandbox_runtime_setup.container_masc_dir ~container_root)
      ~keeper_name:meta.name in
  let build identity_environment =
    let* () = Keeper_microvm_shim_readiness.verify ~base_path:config.base_path
        ~backend ~guest_name:container_name
      |> Result.map_error Keeper_microvm_shim_readiness.error_message in
    build_microvm_endpoint ~config ~meta ~container_root ~uid ~gid ~container_name ~identity_environment in
  match backend with
  | Keeper_microvm_backend.Apple_container ->
    with_apple_lifecycle_scope ~keeper_name:meta.name
      ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
      (fun ~fs ~scope ->
        let* snapshot = Keeper_microvm_github_identity.load ~fs ~coordinator:microvm_lifecycle ~scope
            ~base_path:config.base_path ~keeper_name:meta.name ~backend ~network_mode
          |> Result.map_error Keeper_microvm_github_identity.error_message in
        match snapshot with
        | None -> Error "microvm mounted credential snapshot is missing"
        | Some snapshot -> build (Keeper_microvm_github_identity.environment snapshot ~container_config_dir))
  | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
    build (Keeper_github_identity.microvm_git_credential_env
      ~config ~keeper_name:meta.name ~container_config_dir)
;;

let microvm_remote_endpoint_of_running (t : t) ~container_name =
  microvm_remote_endpoint_of_running_fields
    ~config:t.config
    ~meta:t.meta
    ~network_mode:t.network_mode
    ~container_root:t.container_root
    ~uid:t.uid
    ~gid:t.gid
    ~container_name
;;

(* Apple preparation belongs to the canonical Keeper owner, including a
   retry after an incomplete first handoff. Attached readers never run it. *)
let microvm_remote_endpoint ?timeout_sec (t : t) =
  match ensure_started ?timeout_sec t with
  | Error _ as err -> err
  | Ok container_name ->
    let root =
      if microvm_work_root_ready container_name
      then Ok ()
      else
        Result.bind (microvm_backend_of t) (function
          | Keeper_microvm_backend.Apple_container ->
            start_microvm_container ?timeout_sec t
            |> Result.map (fun _ -> ())
            |> Result.map_error github_identity_preparation_error_message
          | (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) as backend ->
            match ensure_microvm_keeper_work_root ?timeout_sec t ~backend ~container_name with
            | Ok () ->
              mark_microvm_work_root_ready container_name;
              Ok ()
            | Error _ as err -> err)
    in
    (match root with
     | Error _ as err -> err
     | Ok () -> microvm_remote_endpoint_of_running t ~container_name)
;;

(* Reading a keeper's tree needs the guest, not the turn that happens to be
   using it. The guest name is a function of the keeper and the base path,
   and the guest is keeper-lifetime, so a caller holding no lifecycle
   authority can still name and reach one that is up. Endpoint admission
   validates the mounted identity under a short Keeper owner and verifies the
   shared shim. It never calls [ensure_started]. Booting on behalf of a reader
   would spend a VM start, write the identity snapshot and make the work
   root -- effects that belong to the keeper's own turn.

   No running-state probe either: a stopped guest fails the [container exec]
   on its own. The probe is [microvm_guest_absence_reason], which the caller
   runs only to name a failure it already has. *)
let microvm_attached_endpoint ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let container_name =
    microvm_container_name
      ~config
      ~keeper_name:meta.name
      ~network_mode:meta.network_mode
  in
  microvm_remote_endpoint_of_running_fields
    ~config
    ~meta
    ~network_mode:meta.network_mode
    ~container_root:(container_root_of_meta meta)
    ~uid:(Unix.getuid ())
    ~gid:(Unix.getgid ())
    ~container_name
;;

(* [Some reason] when the guest is not running, so a caller can replace a raw
   exec failure with the fact behind it; [None] when the guest is up or the
   probe itself could not answer, leaving the caller's own error in place. *)
let microvm_guest_absence_reason ?timeout_sec ~(config : Workspace.config)
      ~(meta : keeper_meta) () =
  if meta.sandbox_profile <> Keeper_types_profile_sandbox.Micro_vm
  then None
  else
    let container_name =
      microvm_container_name
        ~config
        ~keeper_name:meta.name
        ~network_mode:meta.network_mode
    in
    (* No recorded runtime means nothing here can state a fact about the
       guest, so the caller's own error stands rather than a probe run
       against a runtime the keeper never named. *)
    match meta.microvm_backend with
    | None -> None
    | Some backend ->
    match probe_microvm_container_state ?timeout_sec ~backend container_name with
    | Ok Keeper_sandbox_runtime.Docker_container_running -> None
    | Error _ -> None
    | Ok (Keeper_sandbox_runtime.Docker_container_stopped
         | Keeper_sandbox_runtime.Docker_container_absent) ->
      Some
        (Printf.sprintf
           "microvm_guest_not_running: keeper %s's guest %s is not running; a read \
            attaches to a running guest and never boots one"
           meta.name container_name)
;;

let is_microvm_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
  if meta.sandbox_profile <> Keeper_types_profile_sandbox.Micro_vm
  then false
  else
    let container_name =
      microvm_container_name
        ~config
        ~keeper_name:meta.name
        ~network_mode:meta.network_mode
    in
    microvm_work_root_ready container_name
;;

let forget_microvm_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let container_name =
    microvm_container_name
      ~config
      ~keeper_name:meta.name
      ~network_mode:meta.network_mode
  in
  forget_microvm_work_root container_name
;;

let retire_current_github_identity_snapshot t =
  update_github_identity_snapshots t (fun snapshots ->
    match snapshots.current with
    | None -> snapshots
    | Some current ->
      { current = None; retired = current :: snapshots.retired })
;;

let stop_container_for_github_identity_refresh ?timeout_sec t =
  if is_microvm t
  then (
    match microvm_backend_of t with
    | Error _ as error -> error
    | Ok Keeper_microvm_backend.Apple_container ->
      let backend = Keeper_microvm_backend.Apple_container in
      let timeout_sec = match timeout_sec with Some seconds -> seconds
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm () in
      with_apple_lifecycle_scope ~keeper_name:t.meta.name
        ~unavailable:(microvm_start_failure_message Runtime_context_unavailable)
        (fun ~fs ~scope ->
          Result.bind (ensure_apple_volume_helpers_absent ~keeper_name:t.meta.name ~timeout_sec)
            (fun () -> Result.bind
              (stop_and_delete_microvm_container ~timeout_sec ~backend (keeper_vm_name t))
              (fun () ->
              (* The guest is gone even if later snapshot cleanup cannot
                 settle. Do not retain Running authority for the next call. *)
              set_state t Not_started;
              forget_github_identity_snapshots t;
              Keeper_microvm_github_identity.remove_if_guest_absent ~fs ~coordinator:microvm_lifecycle
                ~scope ~base_path:t.config.base_path ~keeper_name:t.meta.name ~backend
                ~network_mode:t.network_mode ~timeout_sec
              |> Result.map (function
                | Keeper_microvm_github_identity.Removed | Keeper_microvm_github_identity.Already_absent -> ())
              |> Result.map_error Keeper_microvm_github_identity.error_message)))
    | Ok (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
    with_microvm_lifecycle_lock ~keeper_name:t.meta.name ~operation:"identity_refresh" (fun () ->
      let container_name = keeper_vm_name t in
      match
        Result.bind (microvm_backend_of t) (fun backend ->
          stop_and_delete_microvm_container ?timeout_sec ~backend container_name)
      with
      | Error _ as error -> error
      | Ok () ->
        release_registered_microvm_identity container_name;
        forget_github_identity_snapshots t;
        set_state t Not_started;
        Ok ()))
  else
    let retire () =
      set_state t Not_started;
      retire_current_github_identity_snapshot t;
      Ok ()
    in
    match get_state t with
    | Not_started -> retire ()
    | Running { container_name } ->
    let timeout_sec =
      Option.value
        timeout_sec
        ~default:
          (Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm ())
    in
    let argv =
      Keeper_sandbox_runtime.docker_remove_argv container_name
    in
    let status, output = run_argv_with_status ~timeout_sec argv in
      (match status with
       | Unix.WEXITED 0 -> retire ()
       | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
         (match
            Keeper_sandbox_runtime.probe_container_state_optional
              ~container_name
              ~timeout_sec
              ()
          with
          | Ok Keeper_sandbox_runtime.Docker_container_absent -> retire ()
          | Ok Keeper_sandbox_runtime.Docker_container_running
          | Ok Keeper_sandbox_runtime.Docker_container_stopped
          | Error _ ->
            Error
              (Printf.sprintf
                 "cannot refresh GitHub identity while turn container %s remains: status=%s output=%s"
                 container_name
                 (Keeper_sandbox_exec_failure.status_label status)
                 (Exec_policy.truncate_for_log output))))
;;

let prepare_github_identity_secret_files ?timeout_sec t =
  (* App-identity keepers get a fresh installation token before any lane
     consumes their hosts file; shared-identity keepers pass through
     untouched (RFC keeper-github-apps). A stale token whose mint fails is
     an error — projecting a credential known to be expired is worse. *)
  match
    Keeper_github_app_broker.ensure_fresh
      ~now:(Time_compat.now ())
      ~http_post:Keeper_github_app_broker.default_http_post
      ~config:t.config
      ~keeper_name:t.meta.name
  with
  | Error err -> Error (Identity_unavailable ("github_app_token_refresh_failed: " ^ err))
  | Ok
      ( Keeper_github_app_broker.No_app_identity
      | Keeper_github_app_broker.Fresh _
      | Keeper_github_app_broker.Refreshed _ ) ->
  if is_microvm t
  then (
    (match microvm_backend_of t with
     | Ok Keeper_microvm_backend.Apple_container | Error _ -> ()
     | Ok (Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox) ->
       ignore (bind_registered_microvm_identity t (keeper_vm_name t)));
    (* The guest's identity is its boot-time snapshot, keeper-lifetime by
       design: only a fresh boot mounts a new one, and a drift from the
       central revision is handled by dropping the handle so the next boot
       rebuilds it. *)
    let ensure_bound () =
      let snapshot_paths () =
        match (Atomic.get t.github_identity_snapshots).current with
        | Some _ -> Ok (github_identity_secret_files t)
        | None -> Error (Identity_unavailable "running container has no GitHub identity snapshot")
      in
      match ensure_started_with_cause ?timeout_sec t with
      | Error _ as error -> error
      | Ok _container_name ->
        (match snapshot_paths () with
         | Ok _ as result -> result
         | Error _ ->
           (* A runtime can retain [Running] across turns while its local
              handle was lost (for example after a failed adoption). Do not
              report a live guest as usable without the credential it was
              booted to mount: force the normal MicroVM start path to
              reconcile the stable guest and registry, which reboots when no
              safe snapshot exists. *)
           set_state t Not_started;
           (match start_container ?timeout_sec t with
            | Error _ as error -> error
            | Ok _ -> snapshot_paths ()))
    in
    match ensure_bound () with
    | Error _ as error -> error
    | Ok paths -> match
      Keeper_github_identity.current_tool_identity_revision
        ~config:t.config
        ~keeper_name:t.meta.name
    with
    | Error detail -> Error (Identity_unavailable detail)
    | Ok central_revision ->
      (match (Atomic.get t.github_identity_snapshots).current with
       | None -> Error (Identity_unavailable "running guest lost its validated identity binding")
       | Some snapshot when String.equal (identity_revision snapshot) central_revision ->
         Ok paths
       | Some _ ->
         (match stop_container_for_github_identity_refresh ?timeout_sec t with
          | Error detail -> Error (Sandbox_unavailable detail)
          | Ok () -> ensure_bound ())))
  else
    (* The persistent Docker container mounts the stable config directory
       read-only, so the token that must stay redacted is the stable
       hosts.yml and binding is [ensure_started] itself -- a central login
       reaches the running container through the mount, with the derived
       gitconfig refreshed at adoption. An unconfigured keeper exposes no
       credential file. *)
    match ensure_started_with_cause ?timeout_sec t with
    | Error _ as error -> error
    | Ok _container_name ->
      (match
         Keeper_github_identity.existing_config_dir
           ~config:t.config
           ~keeper_name:t.meta.name
       with
       | Error detail -> Error (Identity_unavailable detail)
       | Ok None -> Ok []
       | Ok (Some dir) -> Ok [ Filename.concat dir "hosts.yml" ])
;;

(* The argv assembly [run_exec_with_status_split_once] used to carry inline.
   Named because a second caller needs the same argv without the running: a
   command that must not block the turn is spawned rather than awaited, and it
   has to land inside the same container, as the same uid, under the same
   rewritten paths. Two constructions of that would be two boundaries. *)
let exec_argv ?stdin ?timeout_sec ~validate_cached_container (t : t) ~cwd ~command_argv =
  match
    Result.bind (docker_exec_only t) (fun () ->
      ensure_started ~validate_running:validate_cached_container ?timeout_sec t)
  with
  | Error _ as err -> err
  | Ok container_name ->
    let container_cwd = container_cwd_of_host t ~host_cwd:cwd in
    let command_argv =
      List.map
        (fun arg ->
           let rewritten =
             Keeper_sandbox_runtime.rewrite_host_root_to_container_root
               ~host_root:t.host_root
               ~container_root:t.container_root
               arg
           in
           if String.equal t.raw_host_root t.host_root
           then rewritten
           else
             Keeper_sandbox_runtime.rewrite_host_root_to_container_root
               ~host_root:t.raw_host_root
               ~container_root:t.container_root
               rewritten)
        command_argv
    in
    Ok
      (exec_prefix t ~container_cwd ~stdin:(Option.value stdin ~default:false)
       @ (container_name :: command_argv))
;;

let run_exec_with_status_split_once
      ?(validate_cached_container = false)
      ?(stdin_content : string option)
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match
    exec_argv
      ~stdin:(Option.is_some stdin_content)
      ?timeout_sec
      ~validate_cached_container
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok argv ->
    let run ?output_capture () =
      match stdin_content with
      | Some content ->
        run_argv_with_stdin_and_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ?output_capture
          ~stdin_content:content
          argv
      | None ->
        run_argv_with_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ?output_capture
          argv
    in
    let (st, stdout, stderr), files =
      match capture_dir with
      | None -> run (), None
      | Some capture_dir ->
        let result, files =
          Process_output_capture.with_capture ~capture_dir (fun output_capture ->
            run ~output_capture ())
        in
        result, Some files
    in
    Ok (st, stdout, stderr, files)
;;

let run_exec_with_optional_output_files
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  let has_output_callback =
    Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
  in
  match
    run_exec_with_status_split_once
      ~validate_cached_container:has_output_callback
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      ?capture_dir
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok (((Unix.WEXITED 126 | Unix.WEXITED 127) as status), stdout, stderr, _) as failed ->
    (match failed_exec_recovery ?timeout_sec t with
     | Preserve_failed_exec -> failed
     | Restart_failed_exec ->
       set_state t Not_started;
       (match
          run_exec_with_status_split_once
            ?stdin_content
            ?on_stdout_chunk
            ?on_stderr_chunk
            ?timeout_sec
            ?capture_dir
            t
            ~cwd
            ~command_argv
        with
        | Ok _ as ok -> ok
        | Error _ as err -> err)
     | Failed_exec_state_probe_error detail ->
       Error
         (failed_exec_state_probe_error
            ~status
            ~output:(output_for_status ~stdout ~stderr)
            detail))
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _, _) as other) ->
    Ok other
;;

let run_exec_with_status_split
      ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
      t ~cwd ~command_argv
  =
  run_exec_with_optional_output_files
    ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    t ~cwd ~command_argv
  |> Result.map (fun (status, stdout, stderr, _) -> status, stdout, stderr)
;;

let run_exec_with_output_files
      ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
      ~capture_dir t ~cwd ~command_argv
  =
  run_exec_with_optional_output_files
    ?stdin_content ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    ~capture_dir t ~cwd ~command_argv
;;

let run_exec_with_status
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match
    run_exec_with_status_split
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok (status, stdout, stderr) ->
    Ok (status, output_for_status ~stdout ~stderr)
;;

type exec_pipeline_stage = {
  command_argv : string list;
  cwd : string option;
}

let rewrite_command_argv (t : t) command_argv =
  List.map
    (fun arg ->
      let rewritten =
        Keeper_sandbox_runtime.rewrite_host_root_to_container_root
          ~host_root:t.host_root
          ~container_root:t.container_root
          arg
      in
      if String.equal t.raw_host_root t.host_root
      then rewritten
      else
        Keeper_sandbox_runtime.rewrite_host_root_to_container_root
          ~host_root:t.raw_host_root
          ~container_root:t.container_root
          rewritten)
    command_argv
;;

let docker_exec_pipeline_argv (t : t) ~container_name ~container_cwd command_argv =
  exec_prefix t ~container_cwd ~stdin:true
  @ (container_name :: rewrite_command_argv t command_argv)
;;

let run_exec_pipeline_with_status_once
      ?(validate_cached_container = false)
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
      (t : t)
      ~(cwd : string)
      ~(stages : exec_pipeline_stage list)
  =
  match
    Result.bind (docker_exec_only t) (fun () ->
      ensure_started ~validate_running:validate_cached_container ?timeout_sec t)
  with
  | Error _ as err -> err
  | Ok container_name ->
    let process_stages =
      List.map
        (fun { command_argv; cwd = stage_cwd } ->
          let cwd = Option.value stage_cwd ~default:cwd in
          let container_cwd = container_cwd_of_host t ~host_cwd:cwd in
          let argv = docker_exec_pipeline_argv t ~container_name ~container_cwd command_argv in
          Process_eio.plumbed_stage
            ~argv
            ~env:(Some (sandbox_environment ()))
            ~cwd:(Some (Config_dir_resolver.current_working_dir ())))
        stages
    in
    (* These stages carry no file redirect, so the runner's redirect error is
       out of reach here; it is passed on rather than folded into a status. *)
    run_argv_pipeline_with_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      process_stages
;;

let run_exec_pipeline_with_status ?on_stdout_chunk ?on_stderr_chunk ?timeout_sec
    t ~cwd ~stages =
  let has_output_callback =
    Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
  in
  match
    run_exec_pipeline_with_status_once
      ~validate_cached_container:has_output_callback
      ?timeout_sec
      t
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~cwd
      ~stages
  with
  | Error _ as err -> err
  | Ok (((Unix.WEXITED 126 | Unix.WEXITED 127) as status), stdout, stderr) as failed ->
    (match failed_exec_recovery ?timeout_sec t with
     | Preserve_failed_exec -> failed
     | Restart_failed_exec ->
       set_state t Not_started;
       (match
          run_exec_pipeline_with_status_once
            ?timeout_sec
            t
            ?on_stdout_chunk
            ?on_stderr_chunk
            ~cwd
            ~stages
        with
        | Ok _ as ok -> ok
        | Error _ as err -> err)
     | Failed_exec_state_probe_error detail ->
       Error
         (failed_exec_state_probe_error
            ~status
            ~output:(output_for_status ~stdout ~stderr)
            detail))
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) as other) ->
    Ok other
;;

let run_command_with_status
      ?(ok_exit_codes = [ 0 ])
      ~timeout_sec
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
      ~(max_bytes : int)
      ()
  =
  match command_argv with
  | [] -> Error "run_command_with_status: command_argv is empty"
  | head_program :: _ ->
    (match run_exec_with_status t ~timeout_sec ~cwd ~command_argv with
     | Error _ as err -> err
     | Ok (st, out) ->
       (match st with
        | Unix.WEXITED code when List.exists (fun ok_code -> ok_code = code) ok_exit_codes
          ->
          let body =
            if String.length out > max_bytes then String.sub out 0 max_bytes else out
          in
          Ok (st, body)
        | Unix.WSIGNALED _ | Unix.WSTOPPED _ | WEXITED _ -> Error (format_docker_exec_error ~head_program ~st ~out)))
;;

let run_bash_with_status ~timeout_sec (t : t) ~(cwd : string) ~(cmd : string) ()
  =
  let cmd =
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:t.host_root
      ~container_root:t.container_root
      cmd
  in
  let container_cwd = container_cwd_of_host t ~host_cwd:cwd in
  let docker_exec_argv ~container_name =
    exec_prefix t ~container_cwd ~stdin:true
    @ [ container_name; "bash"; "-l"; "-s" ]
  in
  match Result.bind (docker_exec_only t) (fun () -> ensure_started t ~timeout_sec) with
  | Error _ as err -> err
  | Ok container_name ->
    let argv = docker_exec_argv ~container_name in
    let st, out =
      run_argv_with_stdin_and_status
        ~stdin_content:cmd
        argv
    in
    (match st with
     | (Unix.WEXITED (126 | 127) as status) ->
       (match failed_exec_recovery t with
        | Preserve_failed_exec -> Ok (st, out)
        | Restart_failed_exec ->
        set_state t Not_started;
        (match ensure_started t ~timeout_sec with
         | Error _ as err -> err
         | Ok container_name ->
           let argv = docker_exec_argv ~container_name in
           Ok
             (run_argv_with_stdin_and_status
                ~stdin_content:cmd
                argv))
        | Failed_exec_state_probe_error detail ->
          Error (failed_exec_state_probe_error ~status ~output:out detail))
     | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Ok (st, out))
;;

let cleanup (t : t) =
  (* Both keeper-lifetime containers -- the microvm guest and the persistent
     Docker container -- outlive the turn: cleanup only drops the handle, so
     the next turn (of this server or a later one) adopts what is still
     running. Removal is the keeper's teardown at shutdown finalization, the
     one point that knows the keeper is gone for good rather than between
     turns. A stopped persistent container is collected by the stale sweep,
     which removes stopped containers of any kind. *)
  match get_state t with
  | Not_started -> ()
  | Running { container_name } ->
    set_state t Not_started;
    ignore container_name
;;

type build_cleanup_report = { cleaned : int; failed : int }

let build_cleanup_report_of_string stdout =
  try
    let open Yojson.Safe.Util in
    let report = Yojson.Safe.from_string stdout in
    match member "skip" report with
    | `String reason -> Error ("Keeper guest cleanup skipped: " ^ reason)
    | `Null ->
      let entries = member "entries" report |> to_list in
      let count action = List.fold_left (fun n entry ->
          if member "action" entry = `String action then n + 1 else n) 0 entries in
      Ok { cleaned = count "cleaned"; failed = count "clean failed" }
    | _ -> Error "invalid Keeper cleanup report"
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    Error "invalid Keeper cleanup report"

(* Called only while the Owner holds its exclusive maintenance slot. Attach to
   the recorded guest; never boot, stop, pause, or refresh its credentials. *)
let cleanup_attached_builds ~(config : Workspace.config) ~(meta : keeper_meta)
    ~retention_sec () =
  match meta.sandbox_profile, meta.microvm_backend with
  | Keeper_types_profile_sandbox.Micro_vm, Some Keeper_microvm_backend.Apple_container ->
    let backend = Keeper_microvm_backend.Apple_container in
    let container_name = microvm_container_name ~config ~keeper_name:meta.name
        ~network_mode:meta.network_mode in
    let timeout_sec = Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io () in
    (match probe_microvm_container_state ~timeout_sec ~backend container_name with
     | Ok Keeper_sandbox_runtime.Docker_container_running ->
       (match Embedded_config.read "scripts/keeper-build-cleanup.py" with
        | None -> Error "embedded Keeper cleanup payload missing"
        | Some stdin_content ->
          let root = Keeper_sandbox_microvm.keeper_work_root ~keeper_name:meta.name in
          (match microvm_attached_endpoint ~config ~meta () with
           | Error _ as error -> error
           | Ok endpoint ->
             let observation = ref (Keeper_sandbox_remote.Execution_unavailable
                                      Keeper_sandbox_remote.Request_not_sent) in
             let run = Keeper_sandbox_remote.runner ~timeout_sec
                 ~on_receipt:(fun receipt -> observation := receipt) endpoint in
             let outcome = run ~on_stdout_chunk:None ~on_stderr_chunk:None
                 ~stdin_content:(Some stdin_content) ~env:[||] ~cwd:None
                 ~argv:["python3"; "-"; "--guest-root"; root;
                        "--build-root"; Keeper_sandbox_microvm.build_volume_guest_root; "--idle-hours";
                        string_of_float (retention_sec /. Masc_time_constants.hour); "--apply"] in
             match outcome, !observation with
             | Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout; _ },
               Keeper_sandbox_remote.Execution_observed _ ->
               Result.map Option.some (build_cleanup_report_of_string stdout)
             | Masc_exec.Sandbox_target.Transport_failed { reason; _ }, _ ->
               Error ("Keeper guest cleanup transport failed: " ^ reason)
             | _, Keeper_sandbox_remote.Execution_unavailable _ ->
               Error "Keeper guest cleanup exit receipt missing"
             | Masc_exec.Sandbox_target.Ran
                 { status =
                     (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _)
                 ; _
                 },
               Keeper_sandbox_remote.Execution_observed _ ->
               Error "Keeper guest cleanup command failed"))
     | Ok (Keeper_sandbox_runtime.Docker_container_stopped
          | Keeper_sandbox_runtime.Docker_container_absent) -> Ok None
     | Error detail -> Error detail)
  | (Keeper_types_profile_sandbox.Micro_vm, Some (Keeper_microvm_backend.Microsandbox | Keeper_microvm_backend.Nerdctl_kata))
  | (Keeper_types_profile_sandbox.Micro_vm, None) | ((Docker | Remote_ssh), _) -> Ok None
