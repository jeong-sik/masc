open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type state =
  | Not_started
  | Running of { container_name : string }

type github_identity_snapshot =
  { args : string list
  ; host_dir : string
  ; revision : string
  ; cleanup : unit -> unit
  }

type github_identity_snapshots =
  { current : github_identity_snapshot option
  ; retired : github_identity_snapshot list
  }

let no_github_identity_snapshots = { current = None; retired = [] }

(* A microvm guest outlives the turn runtime that booted it. Its credential
   snapshot therefore cannot be owned by [t]: the next turn constructs a new
   [t] and adopts the same guest. Keep the one snapshot mounted by each guest
   under the stable guest name for the lifetime of this server process. *)
let microvm_identity_snapshots :
  (string * github_identity_snapshot) list Atomic.t
  =
  Atomic.make []
;;

(* Stable guest names make concurrent turn starts converge on one VM. Keep
   the name probe, snapshot claim, and VM start/stop in one Eio critical
   section so a losing starter cannot release a snapshot while the winner is
   still mounting it. VM execs do not take this lock. *)
let microvm_lifecycle_mutex = Eio.Mutex.create ()

let with_microvm_lifecycle_lock f =
  match Eio_context.get_root_switch_opt () with
  | None -> f ()
  | Some _ -> Eio.Mutex.use_rw ~protect:true microvm_lifecycle_mutex f
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
let microvm_work_roots_ready : string list Atomic.t = Atomic.make []

let microvm_work_root_ready container_name =
  List.exists (String.equal container_name) (Atomic.get microvm_work_roots_ready)
;;

let rec mark_microvm_work_root_ready container_name =
  let current = Atomic.get microvm_work_roots_ready in
  if List.exists (String.equal container_name) current
  then ()
  else if not (Atomic.compare_and_set microvm_work_roots_ready current (container_name :: current))
  then mark_microvm_work_root_ready container_name
;;

let rec forget_microvm_work_root container_name =
  let current = Atomic.get microvm_work_roots_ready in
  let updated = List.filter (fun name -> not (String.equal name container_name)) current in
  if not (Atomic.compare_and_set microvm_work_roots_ready current updated)
  then forget_microvm_work_root container_name
;;

(* The proxy port each policy guest was booted against.

   A [Network_policy] guest carries its one route in its environment, and the
   lane's listener takes an ephemeral port. The two have different lifetimes:
   the guest is keeper-lifetime, the port belongs to the lane fiber. When the
   lane rebinds -- its fiber died and respawned, or the lane restarted in
   place -- the port moves and the still-running guest keeps CONNECTing to a
   port nothing holds. Nothing refuses it: the guest's traffic fails at the
   socket, so a cut-off keeper looks idle.

   The guest's name cannot carry the port. A name is durable and a port is
   not, and pinning one to the other would boot a fresh VM on every rebind.
   So it is recorded here and compared at adopt, and a guest booted against a
   port this process no longer holds is replaced rather than adopted.

   Across a server restart the port is unknowable, but so is the identity
   snapshot: [bind_registered_microvm_identity] finds nothing and the guest
   is already replaced on that account. This table therefore only has to
   answer for guests booted by the process asking. *)
let microvm_policy_ports : (string * int) list Atomic.t = Atomic.make []

let microvm_policy_port container_name =
  Atomic.get microvm_policy_ports |> List.assoc_opt container_name
;;

let rec record_microvm_policy_port container_name port =
  let current = Atomic.get microvm_policy_ports in
  let updated = (container_name, port) :: List.remove_assoc container_name current in
  if not (Atomic.compare_and_set microvm_policy_ports current updated)
  then record_microvm_policy_port container_name port
;;

let rec forget_microvm_policy_port container_name =
  let current = Atomic.get microvm_policy_ports in
  let updated = List.remove_assoc container_name current in
  if not (Atomic.compare_and_set microvm_policy_ports current updated)
  then forget_microvm_policy_port container_name
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

type t =
  { config : Workspace.config
  ; meta : keeper_meta
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
  List.map (fun snapshot -> Filename.concat snapshot.host_dir "hosts.yml") snapshots
;;

let host_root t = t.host_root
let normalize_path path = Keeper_alerting_path.normalize_path_for_check_stripped path

let create
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?(network_mode = Network_none)
      ()
  =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  { config
  ; meta
  ; raw_host_root
  ; host_root = raw_host_root |> normalize_path
  ; container_root =
      Keeper_sandbox.container_root meta.name
      |> Keeper_alerting_path.strip_trailing_slashes
  ; uid = Unix.getuid ()
  ; gid = Unix.getgid ()
  ; network_mode
  ; state = Atomic.make Not_started
  ; github_identity_snapshots = Atomic.make no_github_identity_snapshots
  }
;;

(* One container per keeper, not per turn: the name is stable, an already
   running container is adopted instead of created (amortising the container
   start and the image preflight to once per keeper), and turn cleanup leaves
   it running. State accumulated inside the container between turns belongs
   to the same keeper. Teardown is [teardown_keeper_sandbox_by_name], which
   shutdown finalization runs after the registry unregister succeeds -- the
   one point that knows the keeper is gone for good rather than between
   turns.

   The network mode is part of the name because it is part of [docker run]:
   a keeper whose network config changed must not adopt a container wired to
   the old network. That orphan is collected by the keeper's teardown, which
   lists by label rather than by name. *)
let keeper_docker_container_name (t : t) =
  let net_suffix =
    match t.network_mode with
    | Network_none -> "none"
    | Network_inherit -> "inherit"
    (* The suffix keeps a container from being reused across a network
       change, so this mode needs its own even though a Docker keeper cannot
       reach it today: a name that collides is how a policy guest would
       silently adopt an inherit container. *)
    | Network_policy -> "policy"
  in
  Printf.sprintf
    "masc-keeper-docker-%s-%s-%s"
    (Workspace_utils.safe_filename t.meta.name)
    net_suffix
    (String.sub (Keeper_sandbox_runtime.base_path_hash t.config.base_path) 0 8)
;;

module For_testing = struct
  let create_minimal ~config ~meta ~state =
    { config
    ; meta
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

  let keeper_docker_container_name = keeper_docker_container_name
  let policy_route_holds = policy_route_holds
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
       | _, output ->
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
            | _, output ->
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
        | _, listing ->
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
      argv
  =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    let env = sandbox_environment () in
    let cwd = Config_dir_resolver.current_working_dir () in
    match on_stdout_chunk, on_stderr_chunk with
    | None, None ->
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

let run_argv_with_stdin_and_status_split
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~stdin_content
      argv
  =
  Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
    Process_eio.run_argv_with_stdin_and_status_split
      ?timeout_sec
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
let microvm_backend_of (t : t) =
  match t.meta.microvm_backend with
  | Some backend -> Ok backend
  | None ->
    Error
      (Printf.sprintf
         "microvm_backend_unresolved: keeper %s declares sandbox_profile=microvm \
          and no microvm_backend, so there is no runtime to boot it on. Next: \
          set microvm_backend in the keeper's TOML to one of: %s"
         t.meta.name
         (String.concat ", " Keeper_microvm_backend.valid_strings))
;;

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

(* [microvm_backend] names the runtime to ask, or [None] for the Docker
   daemon. Two probes of the same fact taking the backend differently is how
   one of them drifts back to a single runtime, so this reads it the way
   [inspect_container_running] already does. *)
let inspect_container_exists ?timeout_sec ~microvm_backend container_name =
  let inspect_argv =
    match microvm_backend with
    | Some backend -> Keeper_sandbox_microvm.inspect_argv_for backend ~container_name
    | None ->
      Keeper_sandbox_runtime.docker_command_argv ()
      @ [ "inspect"; "--format"; "{{.Id}}"; container_name ]
  in
  let inspect_st, inspect_out =
    run_argv_with_status ?timeout_sec inspect_argv
  in
  match inspect_st with
  | Unix.WEXITED 0 -> Ok ()
  | _ -> Error inspect_out
;;

(* [container] has no [--format] template; state comes back as JSON and a
   missing container as a non-zero exit, which maps to absent. *)
let probe_microvm_container_state ?timeout_sec ~backend container_name =
  let st, out =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.inspect_argv_for backend ~container_name)
  in
  match st with
  | Unix.WEXITED 0 ->
    (match Keeper_sandbox_microvm.running_of_inspect_json_for backend out with
     | Ok true -> Ok Keeper_sandbox_runtime.Docker_container_running
     | Ok false -> Ok Keeper_sandbox_runtime.Docker_container_stopped
     | Error _ as err -> err)
  | _ -> Ok Keeper_sandbox_runtime.Docker_container_absent
;;

let inspect_container_running ?timeout_sec ~microvm_backend container_name =
  match
    (match microvm_backend with
     | Some backend -> probe_microvm_container_state ?timeout_sec ~backend container_name
     | None ->
       Keeper_sandbox_runtime.probe_container_state_optional
         ~container_name ?timeout_sec ())
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

let failed_exec_recovery ?timeout_sec (t : t) =
  match get_state t with
  | Not_started -> Restart_failed_exec
  | Running { container_name } ->
    (match
       (if is_microvm t
        then
          Result.bind (microvm_backend_of t) (fun backend ->
            probe_microvm_container_state ?timeout_sec ~backend container_name)
        else
          Keeper_sandbox_runtime.probe_container_state_optional
            ~container_name
            ?timeout_sec
            ())
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

let resolve_image (t : t) =
  match t.meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_sandbox.Runtime.docker_image ()
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
  Printf.sprintf
    "masc-keeper-vm-%s-%s-%s"
    (Workspace_utils.safe_filename keeper_name)
    (Keeper_types_profile_sandbox.network_mode_to_string network_mode)
    (String.sub (Keeper_sandbox_runtime.base_path_hash config.base_path) 0 8)
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

module For_testing_microvm = struct
  let microvm_container_name = microvm_container_name

  let mark_microvm_guest_booted ~(config : Workspace.config) ~(meta : keeper_meta) () =
    let container_name =
      microvm_container_name
        ~config
        ~keeper_name:meta.name
        ~network_mode:meta.network_mode
    in
    mark_microvm_work_root_ready container_name
  ;;
end

let keeper_vm_name (t : t) =
  microvm_container_name
    ~config:t.config
    ~keeper_name:t.meta.name
    ~network_mode:t.network_mode
;;

let policy_route_still_holds (t : t) container_name =
  policy_route_holds
    ~network_mode:t.network_mode
    ~booted_port:(microvm_policy_port container_name)
    ~bound_port:(bound_egress_proxy_port t)
;;

let bind_registered_microvm_identity t container_name =
  match microvm_identity_snapshot container_name with
  | None -> None
  | Some snapshot ->
    bind_github_identity_snapshot t snapshot;
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
  match probe_microvm_container_state ?timeout_sec ~backend container_name with
  | Ok Keeper_sandbox_runtime.Docker_container_absent ->
    forget_microvm_work_root container_name;
    forget_microvm_policy_port container_name;
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

(** The work volume (RFC-0400): the keeper's working tree, on ext4, where a
    host descriptor is never pinned by a guest touching a file. Created if
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

let microvm_shim_host_dir (t : t) =
  Config_dir_resolver.microvm_shim_dir ~base_path:t.config.base_path
;;

(** The shim the guest runs is a static Linux binary the operator installs on
    the host ([scripts/remote-ssh/build-shim.sh --arch arm64]); the config
    beside it is written here on every boot, so a changed payload PATH
    reaches the guest without an operator step. A missing binary refuses the
    boot: a guest without a shim has no remote lane, and the routing that
    follows this change has no other channel into the guest. *)
let prepare_microvm_shim_dir (t : t) =
  let dir = microvm_shim_host_dir t in
  let binary = Filename.concat dir Keeper_sandbox_microvm.shim_binary_name in
  match Unix.access binary [ Unix.X_OK ] with
  | exception Unix.Unix_error (code, _, _) ->
    Error
      (Printf.sprintf
         "microvm_shim_missing: %s (%s); build it with scripts/remote-ssh/build-shim.sh --arch arm64 and install it there"
         binary
         (Unix.error_message code))
  | () ->
    (match
       Fs_compat.save_file_atomic
         (Filename.concat dir Keeper_sandbox_microvm.shim_config_name)
         (Keeper_sandbox_microvm.shim_config_content
            ~payload_path:(Env_config_sandbox.Runtime.microvm_payload_path ()))
     with
     | Ok () -> Ok dir
     | Error message -> Error ("microvm_shim_config_unwritable: " ^ message))
;;

type microvm_guest_provisions =
  { work_volume_name : string
  ; shim_host_dir : string
  }

(** Everything a guest boot mounts besides config and identity, established
    before [container run] so a boot never starts without one of them. *)
let microvm_guest_provisions (t : t) ~backend ~timeout_sec =
  match microvm_work_volume ~backend ~keeper_name:t.meta.name ~timeout_sec with
  | Error _ as err -> err
  | Ok work_volume_name ->
    (match prepare_microvm_shim_dir t with
     | Error _ as err -> err
     | Ok shim_host_dir -> Ok { work_volume_name; shim_host_dir })
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
    (match run_argv_with_status ?timeout_sec probe with
     | Unix.WEXITED 0, _ -> Ok ()
     | _, out ->
       let detail = Keeper_sandbox_runtime.docker_failure_output_for_log out in
       Error
         (Printf.sprintf
            "microvm_work_volume_not_mounted: %s is not a mountpoint in guest %s (volume %s)%s; remove the guest to force a fresh boot with the volume attached"
            Keeper_sandbox_microvm.work_volume_guest_root
            container_name
            volume_name
            (if String.equal (String.trim detail) "" then "" else ": " ^ detail)))
;;

(** The keeper's root on the work volume, made inside the guest once it is
    up. The volume outlives the guest, so this is a no-op after the first
    boot; it runs as root because the volume root is root-owned. The mount
    invariant runs first: existence and writability of the root prove nothing
    while {!Keeper_sandbox_microvm.work_volume_guest_root} itself may be a
    rootfs directory. *)
let ensure_microvm_keeper_work_root ?timeout_sec (t : t) ~backend ~container_name =
  match ensure_microvm_work_volume_mounted ?timeout_sec t ~backend ~container_name with
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
     | _, out ->
       Error
         (Printf.sprintf
            "microvm_keeper_work_root_not_writable: %s as %d:%d: %s"
            root
            t.uid
            t.gid
            (Keeper_sandbox_runtime.docker_failure_output_for_log out)))
  | _, out ->
    Error
      (Printf.sprintf
         "microvm_keeper_work_root_failed: %s: %s"
         root
         (Keeper_sandbox_runtime.docker_failure_output_for_log out))
;;

let start_microvm_container_unlocked ?timeout_sec (t : t) =
  (* The runtime is read once, before anything is spawned. A keeper whose
     TOML names none is refused here rather than booted on an assumed one,
     which is what pointed a boot and its cleanup at two CLIs (#32837). *)
  match microvm_backend_of t with
  | Error detail -> Error ("microvm_start_failed: " ^ detail)
  | Ok backend ->
  let image = resolve_image t in
  if String.trim image = ""
  then Error "keeper sandbox docker image is not configured"
  else (
    let container_name = keeper_vm_name t in
    let adopt snapshot =
      bind_github_identity_snapshot t snapshot;
      set_state t (Running { container_name });
      Ok container_name
    in
    (* A keeper that changed network mode has a guest under the previous
       mode's name: still running, on the wrong network, holding a snapshot
       mount. Nothing was removing it -- the all-modes sweep runs at keeper
       teardown, which is keeper removal, not a mode change -- so it stayed
       until the server stopped.

       Removing them before booting is idempotent for a name with no guest
       behind it, and a failure here is not fatal: the guest we are about to
       boot is the one that matters, and a stale sibling is a leak rather
       than a correctness problem. It is logged so the leak is visible. *)
    List.iter
      (fun mode ->
         if mode <> t.network_mode
         then (
           let stale =
             microvm_container_name ~config:t.config ~keeper_name:t.meta.name
               ~network_mode:mode
           in
           match stop_and_delete_microvm_container ?timeout_sec ~backend stale with
           | Ok () -> ()
           | Error detail ->
             Log.Keeper.warn
               "microvm stale-mode guest not removed keeper=%s name=%s: %s"
               t.meta.name
               stale
               detail))
      Keeper_types_profile_sandbox.all_network_modes;
    let start_state =
      match
        probe_microvm_container_state
          ?timeout_sec
          ~backend
          container_name
      with
      | Ok Keeper_sandbox_runtime.Docker_container_running ->
        (match bind_registered_microvm_identity t container_name with
         | Some snapshot when policy_route_still_holds t container_name ->
           `Adopt snapshot
         | Some _ ->
           (* Booted against a port this process no longer holds. The guest
              is intact and its snapshot is ours, but its one route is dead,
              so adopting it hands the keeper a network that fails at the
              socket with nothing said. Replace it. *)
           (match
              stop_and_delete_microvm_container ?timeout_sec ~backend container_name
            with
            | Ok () -> `Boot
            | Error error -> `Error error)
         | None ->
           (* A guest from an older server process can still be running, but
              its temp snapshot capability died with that process. It is not
              safe to guess the mount or use credentials we cannot redact.
              Replace the guest with one whose snapshot this process owns. *)
           (match
              stop_and_delete_microvm_container
                ?timeout_sec
                ~backend
                container_name
            with
            | Ok () -> `Boot
            | Error error -> `Error error))
      | Error probe_error ->
        `Error (Printf.sprintf "microvm_start_failed: %s" probe_error)
      | Ok Keeper_sandbox_runtime.Docker_container_stopped
      | Ok Keeper_sandbox_runtime.Docker_container_absent -> `Boot
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
         operator to inspect; the next start probes it again and fails the
         same way until it is removed. *)
      (match
         ensure_microvm_work_volume_mounted ?timeout_sec t ~backend ~container_name
       with
       | Ok () -> adopt snapshot
       | Error _ as err -> err)
    | `Error error -> Error error
    | `Boot ->
      (* A stopped guest survived [--rm] (host reboot mid-life); clear the
         name before booting. Absent makes this a no-op. *)
      let (_ : Unix.process_status * string) =
        run_argv_with_status
          ?timeout_sec
          (Keeper_sandbox_microvm.delete_force_argv_for backend ~container_name)
      in
      let image_timeout =
        match timeout_sec with
        | Some sec -> sec
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()
      in
      (match
         Result.bind
           (Keeper_sandbox_microvm.image_present_for
              backend
              ~image
              ~timeout_sec:image_timeout)
           (fun () -> microvm_guest_provisions t ~backend ~timeout_sec:image_timeout)
       with
       | Error _ as err -> err
       | Ok provisions ->
         let dns =
           match Env_config_sandbox.Runtime.microvm_dns () with
           | "" -> None
           | server -> Some server
         in
         (* Reuse the snapshot a previous turn left mounted: the guest is
            keeper-lifetime, so its mounts must keep pointing at the same
            directory. Only a fresh boot builds a new one. *)
         let github_identity_result =
           match (Atomic.get t.github_identity_snapshots).current with
           | Some snapshot -> Ok (snapshot, false)
           | None ->
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
            Error ("microvm_start_failed: github_identity_invalid: " ^ err)
          | Ok (github_identity, github_identity_is_new) ->
         (* The network policy is spelled by the runtime, and one of the three
            cannot say every mode. Resolved before the argv so a boot refuses
            rather than handing msb Docker's flags, which it rejects at
            argument parsing with no statement of what the guest's network
            would have been. *)
         (match ensure_policy_network backend ~keeper_name:t.meta.name t.network_mode with
          | Error detail -> Error ("microvm_start_failed: " ^ detail)
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
            Keeper_sandbox_microvm.network_args_for backend ~dns ~keeper_name:t.meta.name ~policy_proxy
              t.network_mode
          with
          | Error detail -> Error ("microvm_start_failed: " ^ detail)
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
             ~memory:
               (match Env_config_sandbox.Runtime.microvm_memory () with
                | "" -> Env_config_sandbox.Hardening.memory ()
                | sized -> sized)
             ~cpus:
               (match Env_config_sandbox.Runtime.microvm_cpus () with
                | "" -> None
                | count -> Some count)
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
                @ Keeper_sandbox_microvm.shim_mount_args
                    ~host_dir:provisions.shim_host_dir)
             ~image
             (* Asked for by name, so a runtime with no flag for one of them
                refuses the boot instead of running a keeper on a weaker
                sandbox than the profile it declared. *)
             ~constraints:Keeper_microvm_backend.all_guest_constraints
         in
         (match argv_result with
          | Error refusals ->
            Error
              ("microvm_start_failed: "
               ^ Keeper_sandbox_microvm.constraint_refusals_message backend refusals)
          | Ok argv ->
         let st, out = run_argv_with_status ?timeout_sec argv in
         (* A guest that came up but cannot be seen, or cannot hold the
            keeper's root on its volume, is taken down again: the remote
            lane has nowhere to run in it, and leaving it would hand the
            next turn a guest that adopts cleanly and fails on every call. *)
         let take_down_after_boot ~what ~detail =
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
           Error (Printf.sprintf "microvm_start_failed: %s %s: %s" what container_name detail)
         in
         (match st with
          | Unix.WEXITED 0 ->
            (match
               inspect_container_exists
                 ?timeout_sec
                 ~microvm_backend:(Some backend)
                 container_name
             with
             | Ok () ->
               (match
                  ensure_microvm_keeper_work_root
                    ?timeout_sec
                    t
                    ~backend
                    ~container_name
                with
                | Ok () ->
                  mark_microvm_work_root_ready container_name;
                  (* The port this guest's environment now names. Recorded
                     only on a boot that succeeded, so a failed start leaves
                     no claim on the name. The race-loser path below does not
                     record: that guest is the winner's, and the winner's
                     port is the one in it. *)
                  Option.iter
                    (fun (proxy : Keeper_sandbox_microvm.policy_proxy) ->
                       record_microvm_policy_port container_name proxy.port)
                    policy_proxy;
                  adopt github_identity
                | Error detail ->
                  take_down_after_boot
                    ~what:"guest cannot prove its work volume is mounted and its keeper root usable"
                    ~detail)
             | Error inspect_out ->
               take_down_after_boot
                 ~what:"container ran but inspect cannot see"
                 ~detail:inspect_out)
          | _ ->
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
                | Error _ as err -> err)
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
               Error
                 (Printf.sprintf
                    "microvm_start_failed: %s"
                    (Keeper_sandbox_runtime.docker_failure_output_for_log out))
             | Error _ ->
               (* The guest state is unknown. Keep the registered snapshot:
                  deleting it could invalidate a mount on a guest that did
                  start even though the probe failed. Teardown owns recovery. *)
               Error
                 (Printf.sprintf
                    "microvm_start_failed: %s"
                    (Keeper_sandbox_runtime.docker_failure_output_for_log out))))))))))
;;

let start_microvm_container ?timeout_sec t =
  with_microvm_lifecycle_lock (fun () ->
    start_microvm_container_unlocked ?timeout_sec t)
;;

(* Shutdown finalization retains the typed backend through registry removal.
   A Local or remote-SSH keeper owns no local container, while Docker and
   microVM names project to different runtimes and must not probe each other. *)
let teardown_keeper_sandbox_by_name
      ?timeout_sec
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(backend : Keeper_sandbox.backend)
      ?microvm_backend
      ()
  =
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
       let guest_names =
         List.map
           (fun network_mode ->
              microvm_container_name ~config ~keeper_name ~network_mode)
           Keeper_types_profile_sandbox.all_network_modes
       in
       with_microvm_lifecycle_lock (fun () ->
         List.fold_left
           (fun acc guest_name ->
              match acc with
              | Error _ as error -> error
              | Ok () ->
                (match
                   stop_and_delete_microvm_container
                     ~timeout_sec
                     ~backend:microvm_backend
                     guest_name
                 with
                 | Error _ as error -> error
                 | Ok () ->
                   release_registered_microvm_identity guest_name;
                   Ok ()))
           (Ok ())
           guest_names))
;;

let teardown_keeper_sandbox
      ?timeout_sec
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ()
  =
  let backend =
    match meta.sandbox_profile with
    | Docker -> Keeper_sandbox.Docker
    | Micro_vm -> Keeper_sandbox.Micro_vm
    | Remote_ssh -> Keeper_sandbox.Remote_ssh
  in
  teardown_keeper_sandbox_by_name
    ?timeout_sec
    ~config
    ~keeper_name:meta.name
    ~backend
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
  let container_name = keeper_docker_container_name t in
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
        ("docker_container_adopt_failed: github_identity_invalid: " ^ err)
    | Ok _has_git_wiring ->
      set_state t (Running { container_name });
      Ok container_name
  in
  (* Creation is the only path that needs the image, the runtime hardening
     args, and the projections; adoption amortises all of it. *)
  let create () =
    let image = resolve_image t in
    if String.trim image = ""
    then Error "keeper sandbox docker image is not configured"
    else (
      match
        Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class_optional
          ~image
          ?timeout_sec
          ()
      with
      | Error failure ->
        Error (Keeper_sandbox_runtime.image_preflight_start_error failure)
      | Ok () ->
        match
          Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime_optional
            ?timeout_sec ()
        with
        | Error _ as err -> err
        | Ok seccomp_args ->
        match Keeper_sandbox_runtime.docker_network_args t.network_mode with
        | Error msg -> Error msg
        | Ok (network_args, network_label) ->
        (match
           Keeper_sandbox_runtime.docker_user_identity_mount_args
             ~host_root:t.host_root
             ~uid:t.uid
             ~gid:t.gid
         with
         | Error _ as err -> err
         | Ok identity_mounts ->
         (match
            Keeper_secret_projection.docker_args_for_keeper
              ~base_path:t.config.base_path
              ~keeper_name:t.meta.name
              ~container_name
              ()
          with
          | Error err ->
            Error ("docker_container_start_failed: secret_projection: " ^ err)
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
                     ("docker_container_start_failed: github_identity_invalid: "
                      ^ err))
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
                (match
                   inspect_container_exists
                     ?timeout_sec
                     ~microvm_backend:None
                     container_name
                 with
                 | Ok () ->
                   set_state t (Running { container_name });
                   Ok container_name
                 | Error inspect_out ->
                   (* Inspect failed after a successful `docker run`. Without
                      an explicit cleanup the container would leak: t.state
                      stays Not_started, so nothing of ours removes it later --
                      the sweep only takes stopped containers. Best-effort
                      remove it before returning Error. *)
                   let rm_argv =
                     Keeper_sandbox_runtime.docker_remove_argv container_name
                   in
                   let _rm_st, _rm_out =
                     run_argv_with_status ?timeout_sec rm_argv
                   in
                   Error
                     (Printf.sprintf
                        "docker_container_inspect_failed (existence check): %s"
                        (Exec_policy.truncate_for_log inspect_out)))
              | _ ->
                (match probe_state () with
                 | Ok Keeper_sandbox_runtime.Docker_container_running ->
                   (* Another turn or server of this keeper booted the shared
                      name between the absent probe and this run; the run's
                      name loss is the winner's, and this call adopts the
                      winner. *)
                   adopt_running ()
                 | _ ->
                   let status_label =
                     match st with
                     | Unix.WEXITED code -> Printf.sprintf "exit=%d" code
                     | Unix.WSIGNALED signal ->
                       Printf.sprintf "signal=%d" signal
                     | Unix.WSTOPPED signal ->
                       Printf.sprintf "stopped=%d" signal
                   in
                   let base_path_hash =
                     Keeper_sandbox_runtime.base_path_hash t.config.base_path
                   in
                   let network_label = network_mode_to_string t.network_mode in
                   let mount_context =
                     Keeper_sandbox_runtime.docker_mount_failure_context_suffix
                       ~base_path_hash
                       ~keeper_name:t.meta.name
                       ~image
                       ~status_label
                       ~container_kind:
                         Keeper_sandbox_runtime.persistent_container_kind
                       ~network_label
                       out
                   in
                   Error
                     (Printf.sprintf
                        "docker_container_start_failed: %s%s"
                        (Keeper_sandbox_runtime.docker_failure_output_for_log out)
                        mount_context)))))))
  in
  match probe_state () with
  | Ok Keeper_sandbox_runtime.Docker_container_running -> adopt_running ()
  | Error probe_error ->
    Error
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
        inspect_container_exists ?timeout_sec ~microvm_backend:None container_name
      with
      | Ok () -> adopt_running ()
      | Error inspect_out ->
        Error
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

let ensure_started ?(validate_running = false) ?timeout_sec (t : t) =
  match get_state t with
  | Running { container_name } ->
    if not validate_running
    then Ok container_name
    else (
      (* A microvm keeper with no runtime recorded cannot be probed at all, so
         the validation is a refusal rather than a restart against a runtime
         nobody named. *)
      let probe =
        if is_microvm t
        then
          Result.bind (microvm_backend_of t) (fun backend ->
            inspect_container_running
              ?timeout_sec
              ~microvm_backend:(Some backend)
              container_name)
        else
          inspect_container_running ?timeout_sec ~microvm_backend:None container_name
      in
      match probe with
      | Ok () -> Ok container_name
      | Error _ ->
        set_state t Not_started;
        start_container ?timeout_sec t)
  | Not_started -> start_container ?timeout_sec t
;;

(** The guest as a remote endpoint (RFC-0400): [container exec] into the
    running guest delivers the framed request to the shim mounted at
    {!Keeper_sandbox_microvm.shim_guest_path}, the work volume is the remote
    root, the GitHub identity is the snapshot the guest already mounts, and
    the config env names the config mount the guest was booted with. Pure
    given a running guest, so the argv contract is testable. *)
let microvm_remote_endpoint_of_running (t : t) ~container_name =
  if not (is_microvm t)
  then
    Error
      (Printf.sprintf
         "microvm_remote_endpoint_requires_microvm: keeper %s runs sandbox_profile=%s"
         t.meta.name
         (Keeper_types_profile_sandbox.sandbox_profile_to_string t.meta.sandbox_profile))
  else
    let gh_config_dir =
      Keeper_github_identity.container_config_dir
        ~container_masc_dir:
          (Keeper_sandbox_runtime_setup.container_masc_dir
             ~container_root:t.container_root)
        ~keeper_name:t.meta.name
    in
    (* The exec prefix is the declaring runtime's, built here because this is
       where the runtime, the work root and the shim config path are all in
       hand. *)
    Result.bind (microvm_backend_of t) (fun backend ->
      Result.bind
        (Keeper_sandbox_microvm.shim_exec_prefix_for
           ~stdin:true
           backend
           ~container_name
           ~uid:t.uid
           ~gid:t.gid
           ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
           ~shim_config_path:Keeper_sandbox_microvm.shim_config_guest_path)
        (fun prefix ->
          Result.map
            (fun probe_prefix ->
              Keeper_sandbox_remote.of_container_exec
                ~base_path:t.config.base_path
                ~keeper_name:t.meta.name
                ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
                ~gh_config_dir
                ~injected_env:
                  (Keeper_sandbox_runtime.docker_config_env
                     ~base_path:t.config.base_path
                     ~container_root:t.container_root)
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
               ~uid:t.uid
               ~gid:t.gid
               ~remote_root:Keeper_sandbox_microvm.work_volume_guest_root
               ~shim_config_path:Keeper_sandbox_microvm.shim_config_guest_path)))
;;

(* The keeper's root on the volume is made at boot, so a guest this process
   booted is already an endpoint and no exec is spent per call. A guest this
   process adopted without having made the root (a boot whose [mkdir] failed
   and whose take-down failed too) gets it here, once. *)
let microvm_remote_endpoint ?timeout_sec (t : t) =
  match ensure_started ?timeout_sec t with
  | Error _ as err -> err
  | Ok container_name ->
    let root =
      if microvm_work_root_ready container_name
      then Ok ()
      else
        Result.bind (microvm_backend_of t) (fun backend ->
          match
            ensure_microvm_keeper_work_root ?timeout_sec t ~backend ~container_name
          with
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
   authority can still name and reach one that is up. [create] here computes
   paths and reads the process uid; it starts nothing, and this function
   deliberately never calls [ensure_started]. Booting on behalf of a reader
   would spend a VM start, write the identity snapshot and make the work
   root -- effects that belong to the keeper's own turn.

   No running-state probe either: a stopped guest fails the [container exec]
   on its own. The probe is [microvm_guest_absence_reason], which the caller
   runs only to name a failure it already has. *)
let microvm_attached_endpoint ~(config : Workspace.config) ~(meta : keeper_meta) () =
  let t = create ~config ~meta () in
  let container_name =
    microvm_container_name
      ~config
      ~keeper_name:meta.name
      ~network_mode:meta.network_mode
  in
  microvm_remote_endpoint_of_running t ~container_name
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
  then
    with_microvm_lifecycle_lock (fun () ->
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
        Ok ())
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
       | _ ->
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
  | Error err -> Error ("github_app_token_refresh_failed: " ^ err)
  | Ok
      ( Keeper_github_app_broker.No_app_identity
      | Keeper_github_app_broker.Fresh _
      | Keeper_github_app_broker.Refreshed _ ) ->
  if is_microvm t
  then (
    ignore (bind_registered_microvm_identity t (keeper_vm_name t));
    (* The guest's identity is its boot-time snapshot, keeper-lifetime by
       design: only a fresh boot mounts a new one, and a drift from the
       central revision is handled by dropping the handle so the next boot
       rebuilds it. *)
    let ensure_bound () =
      let snapshot_paths () =
        match (Atomic.get t.github_identity_snapshots).current with
        | Some _ -> Ok (github_identity_secret_files t)
        | None -> Error "running container has no GitHub identity snapshot"
      in
      match ensure_started ?timeout_sec t with
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
    match
      Keeper_github_identity.current_tool_identity_revision
        ~config:t.config
        ~keeper_name:t.meta.name
    with
    | Error _ as error -> error
    | Ok central_revision ->
      (match (Atomic.get t.github_identity_snapshots).current with
       | None -> ensure_bound ()
       | Some snapshot when String.equal snapshot.revision central_revision ->
         ensure_bound ()
       | Some _ ->
         (match stop_container_for_github_identity_refresh ?timeout_sec t with
          | Error _ as error -> error
          | Ok () -> ensure_bound ())))
  else
    (* The persistent Docker container mounts the stable config directory
       read-only, so the token that must stay redacted is the stable
       hosts.yml and binding is [ensure_started] itself -- a central login
       reaches the running container through the mount, with the derived
       gitconfig refreshed at adoption. An unconfigured keeper exposes no
       credential file. *)
    match ensure_started ?timeout_sec t with
    | Error _ as error -> error
    | Ok _container_name ->
      (match
         Keeper_github_identity.existing_config_dir
           ~config:t.config
           ~keeper_name:t.meta.name
       with
       | Error _ as error -> error
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
    let has_output_callback =
      Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
    in
    let st, stdout, stderr =
      match stdin_content, has_output_callback with
      | Some content, false ->
        run_argv_with_stdin_and_status_split
          ?timeout_sec
          ~stdin_content:content
          argv
      | None, false -> run_argv_with_status_split ?timeout_sec argv
      | Some content, true ->
        run_argv_with_stdin_and_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ~stdin_content:content
          argv
      | None, true ->
        run_argv_with_status_split
          ?timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          argv
    in
    Ok (st, stdout, stderr)
;;

let run_exec_with_status_split
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ?timeout_sec
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
      t
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok (((Unix.WEXITED 126 | Unix.WEXITED 127) as status), stdout, stderr) as failed ->
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
  | Ok other -> Ok other
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
  | Ok other -> Ok other
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
        | _ -> Error (format_docker_exec_error ~head_program ~st ~out)))
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
     | _ -> Ok (st, out))
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
