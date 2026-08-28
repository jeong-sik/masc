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

type t =
  { config : Workspace.config
  ; meta : keeper_meta
  ; turn_id : int
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

let release_github_identity_snapshot t =
  let snapshots = Atomic.exchange t.github_identity_snapshots no_github_identity_snapshots in
  Option.iter (fun snapshot -> snapshot.cleanup ()) snapshots.current;
  List.iter (fun snapshot -> snapshot.cleanup ()) snapshots.retired
;;

let github_identity_secret_files t =
  let snapshots = Atomic.get t.github_identity_snapshots in
  let snapshots =
    match snapshots.current with
    | None -> snapshots.retired
    | Some current -> current :: snapshots.retired
  in
  List.map (fun snapshot -> Filename.concat snapshot.host_dir "hosts.yml") snapshots
;;

module For_testing = struct
  let create_minimal ~config ~meta ~state =
    { config
    ; meta
    ; turn_id = 0
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
end

let turn_id t = t.turn_id
let host_root t = t.host_root
let normalize_path path = Keeper_alerting_path.normalize_path_for_check_stripped path

let create
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?(network_mode = Network_none)
      ~turn_id
      ()
  =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  { config
  ; meta
  ; turn_id
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

(* Monotonically increasing counter to disambiguate containers created
   within the same millisecond by the same process.  Without this, 64
   concurrent keepers starting simultaneously can produce duplicate
   container names, causing [docker run --name X] to fail with "name
   already in use". *)
let container_counter : int Atomic.t = Atomic.make 0

let container_name_of (t : t) =
  let net_suffix =
    match t.network_mode with
    | Network_none -> "none"
    | Network_inherit -> "inherit"
  in
  let seq = Atomic.fetch_and_add container_counter 1 in
  Printf.sprintf
    "masc-keeper-turn-%s-%s-%d-%d-%d"
    (Workspace_utils.safe_filename t.meta.name)
    net_suffix
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))
    seq
;;

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

(* Shared exec prefix: [<cli> exec [-i] --user u:g -w cwd [env...]].
   The microvm lane runs Apple's [container] and takes only the config
   env. Config is the one mount the guest is given (#31353), and the
   config env is what names it: the mount lands at the runtime base,
   outside the playground the guest runs in, so nothing finds it by
   walking up from the working directory. The workspace-state env stays
   out -- those mounts the guest really does not have, and an env
   pointing at absent paths is worse than none. *)
let exec_prefix (t : t) ~container_cwd ~stdin =
  let cli =
    if is_microvm t
    then Keeper_sandbox_microvm.command_argv ()
    else Keeper_sandbox_runtime.docker_command_argv ()
  in
  let env_args =
    Keeper_sandbox_runtime.sandbox_exec_env_args
      ~microvm:(is_microvm t)
      ~base_path:t.config.base_path
      ~container_root:t.container_root
  in
  cli
  @ [ "exec" ]
  @ (if stdin then [ "-i" ] else [])
  @ [ "--user"; Printf.sprintf "%d:%d" t.uid t.gid; "-w"; container_cwd ]
  @ env_args
;;

let inspect_container_exists ?timeout_sec ~microvm container_name =
  let inspect_argv =
    if microvm
    then Keeper_sandbox_microvm.inspect_argv ~container_name
    else
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
let probe_microvm_container_state ?timeout_sec container_name =
  let st, out =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.inspect_argv ~container_name)
  in
  match st with
  | Unix.WEXITED 0 ->
    (match Keeper_sandbox_microvm.running_of_inspect_json out with
     | Ok true -> Ok Keeper_sandbox_runtime.Docker_container_running
     | Ok false -> Ok Keeper_sandbox_runtime.Docker_container_stopped
     | Error _ as err -> err)
  | _ -> Ok Keeper_sandbox_runtime.Docker_container_absent
;;

let inspect_container_running ?timeout_sec ~microvm container_name =
  match
    (if microvm
     then probe_microvm_container_state ?timeout_sec container_name
     else
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
        then probe_microvm_container_state ?timeout_sec container_name
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

(* A microvm turn container mounts the playground and nothing else: no
   secret projection, no GitHub identity, no config or workspace-state
   mounts, no seccomp/pids/security-opt (container rejects those; the
   guest kernel is the boundary). Keepers needing the projections stay
   on Docker until the guest grows them. Stale-container reaping is the
   Docker sweep's; a leaked microvm guest is collected by hand until a
   sweep lands ([container list --format json] carries the same labels). *)
(* One guest per keeper, not per turn: the name is stable, an already
   running guest is adopted instead of booted (amortising the 1.3-2.4s VM
   start to once per keeper), and turn cleanup leaves it running. State
   accumulated inside the guest between turns belongs to the same keeper.
   Teardown is [teardown_keeper_vm], which shutdown finalization runs after
   the registry unregister succeeds -- the one point that knows the keeper is
   gone for good rather than between turns. *)
let keeper_vm_name (t : t) =
  Printf.sprintf
    "masc-keeper-vm-%s-%s"
    (Workspace_utils.safe_filename t.meta.name)
    (String.sub (Keeper_sandbox_runtime.base_path_hash t.config.base_path) 0 8)
;;

let start_microvm_container ?timeout_sec (t : t) =
  let image = resolve_image t in
  if String.trim image = ""
  then Error "keeper sandbox docker image is not configured"
  else (
    let container_name = keeper_vm_name t in
    (* [keep] is the identity the started guest has mounted, if this call
       built one. Recording it makes the runtime own the temp directory for
       the guest's lifetime; turn cleanup skips the release for microvm and
       the guest teardown does it. *)
    let adopt ?keep () =
      Option.iter
        (fun snapshot ->
           update_github_identity_snapshots t (fun snapshots ->
             { snapshots with current = Some snapshot }))
        keep;
      set_state t (Running { container_name });
      Ok container_name
    in
    match probe_microvm_container_state ?timeout_sec container_name with
    | Ok Keeper_sandbox_runtime.Docker_container_running -> adopt ()
    | Error probe_error ->
      Error (Printf.sprintf "microvm_start_failed: %s" probe_error)
    | Ok Keeper_sandbox_runtime.Docker_container_stopped
    | Ok Keeper_sandbox_runtime.Docker_container_absent ->
      (* A stopped guest survived [--rm] (host reboot mid-life); clear the
         name before booting. Absent makes this a no-op. *)
      let (_ : Unix.process_status * string) =
        run_argv_with_status
          ?timeout_sec
          (Keeper_sandbox_microvm.delete_force_argv ~container_name)
      in
      let image_timeout =
        match timeout_sec with
        | Some sec -> sec
        | None -> Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ()
      in
      (match
         Keeper_sandbox_microvm.image_present ~image ~timeout_sec:image_timeout
       with
       | Error _ as err -> err
       | Ok () ->
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
                Ok
                  ( { args = projection.args
                    ; host_dir = projection.host_snapshot_dir
                    ; revision = projection.revision
                    ; cleanup = projection.cleanup
                    }
                  , true ))
         in
         (match github_identity_result with
          | Error err ->
            Error ("microvm_start_failed: github_identity_invalid: " ^ err)
          | Ok (github_identity, github_identity_is_new) ->
         let argv =
           Keeper_sandbox_microvm.turn_start_argv
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
             ~host_root:t.host_root
             ~container_root:t.container_root
             ~network_args:
               (Keeper_sandbox_microvm.network_args ~dns t.network_mode)
             (* Config only, for now. The secret projection and the GitHub
                identity both hand back a [cleanup] that the Docker lane runs
                under [Eio_guard] at turn end; a keeper-lifetime guest outlives
                that scope, so wiring them here without moving cleanup to guest
                teardown would delete the credential files out from under a
                running guest. Config has no cleanup and is safe to pass now. *)
             ~mount_args:
               (Keeper_sandbox_runtime.docker_config_mount_args
                  ~base_path:t.config.base_path
                  ~container_root:t.container_root
                @ github_identity.args)
             ~image
         in
         let st, out = run_argv_with_status ?timeout_sec argv in
         (match st with
          | Unix.WEXITED 0 ->
            (match
               inspect_container_exists ?timeout_sec ~microvm:true container_name
             with
             | Ok () ->
               adopt ?keep:(if github_identity_is_new then Some github_identity else None) ()
             | Error inspect_out ->
               let (_ : Unix.process_status * string) =
                 run_argv_with_status
                   ?timeout_sec
                   (Keeper_sandbox_microvm.stop_argv ~container_name)
               in
               if github_identity_is_new then github_identity.cleanup ();
               Error
                 (Printf.sprintf
                    "microvm_start_failed: container ran but inspect cannot \
                     see %s: %s"
                    container_name
                    inspect_out))
          | _ ->
            (* Two turns of one keeper can race to boot the shared name;
               the loser's run fails on the name and the guest the winner
               booted is the one both wanted. *)
            (match
               probe_microvm_container_state ?timeout_sec container_name
             with
             | Ok Keeper_sandbox_runtime.Docker_container_running ->
               (* The winner's guest already has its own identity mounted;
                  this call's snapshot was never used, so drop it rather
                  than leak the temp directory. *)
               if github_identity_is_new then github_identity.cleanup ();
               adopt ()
             | Ok _ | Error _ ->
               if github_identity_is_new then github_identity.cleanup ();
               Error
                 (Printf.sprintf
                    "microvm_start_failed: %s"
                    (Keeper_sandbox_runtime.docker_failure_output_for_log out)))))))
;;

(* Takes the name rather than the meta: shutdown finalization holds
   [operation.keeper_name] and no meta by the time the registry entry is
   gone, and the guest name is derived from the name alone. *)
let teardown_keeper_vm_by_name
      ?timeout_sec
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ()
  =
  let container_name =
    Printf.sprintf
      "masc-keeper-vm-%s-%s"
      (Workspace_utils.safe_filename keeper_name)
      (String.sub (Keeper_sandbox_runtime.base_path_hash config.base_path) 0 8)
  in
  let stop_st, stop_out =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.stop_argv ~container_name)
  in
  let (_ : Unix.process_status * string) =
    run_argv_with_status
      ?timeout_sec
      (Keeper_sandbox_microvm.delete_force_argv ~container_name)
  in
  match stop_st with
  | Unix.WEXITED 0 -> Ok ()
  | _ ->
    (* A missing guest is a successful teardown; anything else surfaces. *)
    (match probe_microvm_container_state ?timeout_sec container_name with
     | Ok Keeper_sandbox_runtime.Docker_container_absent -> Ok ()
     | Ok _ | Error _ ->
       Error
         (Printf.sprintf
            "microvm_teardown_failed: %s"
            (Keeper_sandbox_runtime.docker_failure_output_for_log stop_out)))
;;

let teardown_keeper_vm ?timeout_sec ~(config : Workspace.config) ~(meta : keeper_meta) () =
  teardown_keeper_vm_by_name ?timeout_sec ~config ~keeper_name:meta.name ()
;;

let start_container ?timeout_sec (t : t) =
  if is_microvm t
  then start_microvm_container ?timeout_sec t
  else
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
      let container_name = container_name_of t in
      let network_args, network_label =
        Keeper_sandbox_runtime.docker_network_args t.network_mode
      in
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
        | Error err -> Error ("docker_container_start_failed: secret_projection: " ^ err)
        | Ok secret_projection ->
         let github_identity_result =
           match (Atomic.get t.github_identity_snapshots).current with
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
               Ok
                 ( { args = projection.args
                   ; host_dir = projection.host_snapshot_dir
                   ; revision = projection.revision
                   ; cleanup = projection.cleanup
                   }
                 , true ))
         in
         (match github_identity_result with
          | Error err ->
            Eio_guard.protect
              ~finally:secret_projection.cleanup
              (fun () ->
                 Error
                   ("docker_container_start_failed: github_identity_invalid: "
                    ^ err))
          | Ok (github_identity, github_identity_is_new) ->
         let keep_github_identity_snapshot = ref false in
         Eio_guard.protect
           ~finally:(fun () ->
             Fun.protect
               ~finally:secret_projection.cleanup
               (fun () ->
                 if github_identity_is_new && not !keep_github_identity_snapshot
                 then github_identity.cleanup ()))
           (fun () ->
         (* Collect what an earlier turn left running before adding to it. A
            turn container is removed by turn-end teardown; when that does not
            run, nothing else takes it while this process lives, so they
            accumulate one per turn (#30590). This never targets the current
            turn's own containers, so it is safe here even though one turn can
            hold several.

            A failed reap is reported and does not block the turn: refusing to
            start a turn because a previous container could not be removed
            would turn a resource leak into a stopped keeper. *)
         let reaped =
           Keeper_sandbox_runtime.reap_prior_turn_containers
             ~base_path:t.config.base_path
             ~keeper_name:t.meta.name
             ~turn_id:t.turn_id
             ~timeout_sec:
               (Env_config_sandbox.Shell_timeout.timeout_sec
                  ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
                  ())
             ()
         in
         if reaped.removed > 0 || reaped.errors <> []
         then
           Log.Keeper.info
             "%s: reaped %d container(s) left by earlier turns (scanned=%d, \
              absent=%d)%s"
             t.meta.name
             reaped.removed
             reaped.scanned
             reaped.already_absent
             (match reaped.errors with
              | [] -> ""
              | errors -> "; errors: " ^ String.concat "; " errors);
         let argv =
           Keeper_sandbox_runtime.docker_command_argv ()
           @ [ "run"; "-d"; "--rm"; "--name"; container_name ]
           @ Keeper_sandbox_runtime.docker_run_pull_never_args ()
           @ Keeper_sandbox_runtime.docker_label_args
               ~base_path:t.config.base_path
               ~keeper_name:t.meta.name
               ~container_kind:Keeper_sandbox_runtime.turn_container_kind
               ~network_label
               ~turn_id:t.turn_id
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
           @ github_identity.args
           @ identity_mounts
           @ network_args
           @ [ image; "tail"; "-f"; "/dev/null" ]
         in
         let st, out = run_argv_with_status ?timeout_sec argv in
         (match st with
         | Unix.WEXITED 0 ->
            (match
               inspect_container_exists
                 ?timeout_sec
                 ~microvm:false
                 container_name
             with
             | Ok () ->
               if github_identity_is_new
               then
                 update_github_identity_snapshots t (fun snapshots ->
                   { snapshots with current = Some github_identity });
               keep_github_identity_snapshot := true;
               set_state t (Running { container_name });
               Ok container_name
             | Error inspect_out ->
               (* Inspect failed after a successful `docker run`. Without an
                  explicit cleanup the container would leak: t.state stays
                  Not_started, so [cleanup] would skip `docker rm`. Best-effort
                  remove the just-started container before returning Error. *)
               let rm_argv =
                 Keeper_sandbox_runtime.docker_command_argv ()
                 @ [ "rm"; "-f"; container_name ]
               in
               let _rm_st, _rm_out =
                 run_argv_with_status ?timeout_sec rm_argv
               in
               Error
                 (Printf.sprintf
                    "docker_container_inspect_failed (existence check): %s"
                    (Exec_policy.truncate_for_log inspect_out)))
          | _ ->
            let status_label =
              match st with
              | Unix.WEXITED code -> Printf.sprintf "exit=%d" code
              | Unix.WSIGNALED signal -> Printf.sprintf "signal=%d" signal
              | Unix.WSTOPPED signal -> Printf.sprintf "stopped=%d" signal
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
                ~container_kind:"turn"
                ~network_label
                out
            in
            Error
              (Printf.sprintf
                 "docker_container_start_failed: %s%s"
                 (Keeper_sandbox_runtime.docker_failure_output_for_log out)
                 mount_context)))))))
;;

let ensure_started ?(validate_running = false) ?timeout_sec (t : t) =
  match get_state t with
  | Running { container_name } ->
    if not validate_running
    then Ok container_name
    else (
      match
        inspect_container_running ?timeout_sec ~microvm:(is_microvm t) container_name
      with
      | Ok () -> Ok container_name
      | Error _ ->
        set_state t Not_started;
        start_container ?timeout_sec t)
  | Not_started -> start_container ?timeout_sec t
;;

let retire_current_github_identity_snapshot t =
  update_github_identity_snapshots t (fun snapshots ->
    match snapshots.current with
    | None -> snapshots
    | Some current ->
      { current = None; retired = current :: snapshots.retired })
;;

let stop_container_for_github_identity_refresh ?timeout_sec t =
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
      Keeper_sandbox_runtime.docker_command_argv () @ [ "rm"; "-f"; container_name ]
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
  let ensure_bound () =
    match ensure_started ?timeout_sec t with
    | Error _ as error -> error
    | Ok _container_name ->
      (match (Atomic.get t.github_identity_snapshots).current with
       | None -> Error "running container has no GitHub identity snapshot"
       | Some _ -> Ok (github_identity_secret_files t))
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
        | Ok () -> ensure_bound ()))
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
  match ensure_started ~validate_running:validate_cached_container ?timeout_sec t with
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
    let argv =
      exec_prefix t ~container_cwd ~stdin:(Option.is_some stdin_content)
      @ (container_name :: command_argv)
    in
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
  match ensure_started ~validate_running:validate_cached_container ?timeout_sec t with
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

let run_command ?(ok_exit_codes = [ 0 ]) ~timeout_sec t ~cwd ~command_argv ~max_bytes () =
  match
    run_command_with_status ~ok_exit_codes ~timeout_sec t ~cwd ~command_argv ~max_bytes ()
  with
  | Ok (_st, out) -> Ok out
  | Error _ as err -> err
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
  match ensure_started t ~timeout_sec with
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

(* Release the identity a keeper-lifetime guest was holding. Turn cleanup
   skips it -- the guest outlives the turn and has the directory mounted --
   so this is the release path, called once the guest is gone. *)
let release_microvm_identity (t : t) = release_github_identity_snapshot t

let cleanup (t : t) =
  Fun.protect
    ~finally:(fun () ->
      (* The snapshot is a temp directory the guest has mounted, and its
         cleanup deletes it. A docker turn container dies with the turn, so
         releasing here is right for it. A microvm guest is keeper-lifetime
         and outlives this scope: releasing would pull the credential files
         out from under a running guest, which is why the identity was left
         unwired when the guest lane landed (#31353). The guest's own
         teardown releases it instead. *)
      if not (is_microvm t) then release_github_identity_snapshot t)
    (fun () ->
  match get_state t with
  | Not_started -> ()
  | Running { container_name } ->
    set_state t Not_started;
    let rm_timeout =
      Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm ()
    in
    (* A microvm guest is keeper-lifetime: turn cleanup only drops the
       handle. [teardown_keeper_vm] is the remove path. *)
    if is_microvm t
    then ignore container_name
    else
    let rm_argv =
      Keeper_sandbox_runtime.docker_command_argv () @ [ "rm"; "-f"; container_name ]
    in
    let status_label st =
      match st with
      | Unix.WEXITED n -> Printf.sprintf "exited(%d)" n
      | Unix.WSIGNALED n -> Printf.sprintf "signaled(%d)" n
      | Unix.WSTOPPED n -> Printf.sprintf "stopped(%d)" n
    in
    let still_exists () =
      (* Use `docker ps -a` so a stopped-but-still-existing container is not
         silently reported as "gone". Without `-a`, only running containers
         appear and a failed `rm -f` would look successful.

         If `docker ps` itself fails (daemon down, permission denied, etc.),
         we treat the existence question as "unknown" and conservatively
         report false (i.e. no further escalation). The post-rm log path
         already records the rm failure; double-logging an unknown-existence
         WARN would be noisier than useful. *)
      let check_argv =
        Keeper_sandbox_runtime.docker_command_argv ()
        @ [ "ps"; "-a"; "-q"; "--filter"; "name=" ^ container_name ]
      in
      let check_st, check_out =
        run_argv_with_status ~timeout_sec:rm_timeout check_argv
      in
      match check_st with
      | Unix.WEXITED 0 -> String.trim check_out <> ""
      | _ ->
        Log.Keeper.debug
          "%s: docker ps -a probe failed for %s (status=%s, out=%s); treating existence \
           as unknown"
          t.meta.name
          container_name
          (status_label check_st)
          (Exec_policy.truncate_for_log check_out);
        false
    in
    let st, out =
      run_argv_with_status ~timeout_sec:rm_timeout rm_argv
    in
    (* First attempt succeeded and container is gone — done. *)
    (match st with
     | Unix.WEXITED 0 when not (still_exists ()) -> ()
     | _ ->
       (* First attempt failed or container still exists.
          Retry once — transient daemon issues can resolve within seconds,
          and a single retry catches the common "docker rm raced with
          container exit" case without unbounded retries. *)
       let final_st, final_out =
         match st with
         | Unix.WEXITED 0 ->
           (* rm reported success but container still exists — unlikely
              but re-probe after a brief yield for daemon state to
              settle. *)
           st, out
         | _ ->
           Log.Keeper.info
             "%s: docker rm -f %s failed (status=%s), retrying once"
             t.meta.name
             container_name
             (status_label st);
           run_argv_with_status ~timeout_sec:rm_timeout rm_argv
       in
       let exists_after_final = still_exists () in
       (match final_st with
        | Unix.WEXITED 0 when not exists_after_final -> ()
        | _ ->
          if exists_after_final
          then (
            Log.Keeper.warn
              "%s: docker rm -f %s failed after retry and container still exists \
               (status=%s, out=%s)"
              t.meta.name
              container_name
              (status_label final_st)
              (Exec_policy.truncate_for_log final_out);
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string TurnCleanupFailures)
              ~labels:[ "keeper", t.meta.name; "site", "docker_rm" ]
              ())
          else
            Log.Keeper.info
              "%s: docker rm -f %s reported failure but container is gone"
              t.meta.name
              container_name)))
;;
