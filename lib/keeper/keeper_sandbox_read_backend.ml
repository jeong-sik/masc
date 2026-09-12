(** See .mli for contract.

    The current Docker invocation mirrors the hardened-Execute sandbox in
    [keeper_tool_command_runtime.ml] (read-only rootfs, no caps, no network) with the
    playground mounted read-only and the default read program reduced to a
    single [cat]. The argv assembly is duplicated rather than shared so a
    future surgical change to either path does not need to wade through the
    other's flags. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* Constant since the host profile was removed: every profile a keeper may
   declare is hardened, so this answers [true] for all of them. The match is
   kept exhaustive rather than collapsed to [fun _ -> true] so a profile added
   later has to state its own answer. The host-read branch that callers still
   carry behind [should_route_read] is now unreachable and is removed
   separately. *)
let is_hardened = function
  | Docker -> true
  (* A per-container VM is at least as hardened as a container, so reads
     route through the guest the same way. *)
  | Micro_vm -> true
  | Remote_ssh -> true

let should_route_read ~(meta : keeper_meta) : bool =
  is_hardened meta.sandbox_profile

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let host_playground_root ~config ~(meta : keeper_meta) =
  Keeper_sandbox.host_root_abs_of_meta ~config meta
  |> Keeper_alerting_path.normalize_path_for_check
  |> strip_trailing_slashes

let container_root ~(meta : keeper_meta) =
  Keeper_sandbox.container_root meta.name

let container_path_of_host ~(config : Workspace.config) ~(meta : keeper_meta) ~host_path
    : (string, string) result =
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  | Endpoint_owned ->
    let ( let* ) = Result.bind in
    let* remote_root = Keeper_sandbox_remote_lane.remote_root ~config ~meta in
    Keeper_remote_path.host_to_remote ~base_path:config.base_path
      ~remote_root ~keeper:meta.name host_path
  | Shared_mount ->
    let host_root = host_playground_root ~config ~meta in
    let host_norm =
      Keeper_alerting_path.normalize_path_for_check host_path
      |> strip_trailing_slashes
    in
    let croot = container_root ~meta in
    if host_norm = host_root then Ok croot
    else if String.starts_with ~prefix:(host_root ^ "/") host_norm then
      let suffix =
        String.sub host_norm
          (String.length host_root + 1)
          (String.length host_norm - String.length host_root - 1)
      in
      Ok (Filename.concat croot suffix)
    else
      Error
        (Printf.sprintf
           "container_path_of_host: %s is not inside playground %s"
           host_norm host_root)

(* Argv prefix kept private — distinct from keeper_tool_command_runtime's bash
   argv to avoid coupling the two surfaces. The trailing
   [program ; arg1 ; ... ] is appended by the caller via
   [build_docker_argv ~command_argv]. *)
let build_docker_argv ~image ~container_name ~base_path ~host_root ~croot
    ~uid ~gid ~seccomp_args ~secret_args ~command_argv =
  Keeper_sandbox_runtime.docker_command_argv ()
  @ [
      "run";
      "--rm";
      "--name";
      container_name;
      "-i";
      "--user";
      Printf.sprintf "%d:%d" uid gid;
    ]
  @ Keeper_sandbox_runtime.docker_run_pull_never_args ()
  @ Keeper_sandbox_runtime.docker_sandbox_env_args
      ~base_path
      ~container_root:croot
  @ Keeper_sandbox_runtime.docker_nofile_args ()
  @ Env_config_sandbox.Hardening.read_only_rootfs_args ()
  @ [ "--tmpfs"
    ; Env_config_sandbox.Hardening.tmpfs_mount ()
    ; "--cap-drop=ALL"
    ; "--security-opt"
    ; "no-new-privileges"
  ]
  @ seccomp_args
  @ [
    "--pids-limit";
    string_of_int (Env_config_sandbox.Hardening.pids_limit ());
    "--memory"; Env_config_sandbox.Hardening.memory ();
    "-v"; host_root ^ ":" ^ croot ^ ":ro";
    "--workdir"; croot;
    "--network"; "none";
  ]
  @ Keeper_sandbox_runtime.docker_config_mount_args
      ~base_path
      ~container_root:croot
  @ Keeper_sandbox_runtime.docker_workspace_state_mount_args
      ~base_path
      ~container_root:croot
  @ secret_args
  @ [
    image;
  ]
  @ command_argv

let container_name_of meta =
  Printf.sprintf "masc-keeper-read-%s-%d-%d"
    (Workspace_utils.safe_filename meta.name)
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000.0))

(* One runner, two ways of getting the endpoint. A turn hands in the lane's
   [endpoint], which may start the guest it owns; a caller with no turn hands
   in [attached_guest_endpoint], which cannot. Path translation and status
   handling are the same either way, so they live here once. *)
(* The read backend's translation of a [run_outcome] into a read result.
   [Transport_failed] is always an error -- this is what stops a down lane
   from reading as an empty [Ok] on the Grep lane, whose [ok_exit_codes]
   accepts exit 1. Pure and exported so the distinction is tested directly
   (test_keeper_sandbox_read_backend, the differential test). *)
let classify_read_outcome_with_limit ~lane ~endpoint_name ~ok_exit_codes ~max_bytes outcome =
  match (outcome : Masc_exec.Sandbox_target.run_outcome) with
  | Transport_failed { reason; stderr; _ } ->
    Error
      (Printf.sprintf
         "%s_read_transport_failed: endpoint=%s reason=%s stderr=%s"
         lane endpoint_name reason (Exec_policy.truncate_for_log stderr))
  | Ran { status; stdout; stderr; output_files = _ } ->
    (match status with
     | Unix.WEXITED code
       when List.exists (fun allowed -> allowed = code) ok_exit_codes ->
       let output =
         match max_bytes with
         | Some limit when String.length stdout > limit -> String.sub stdout 0 limit
         | Some _ | None -> stdout
       in
       Ok (status, output)
     | Unix.WEXITED code ->
       Error
         (Printf.sprintf
            "%s_read_failed: endpoint=%s exit=%d stderr=%s"
            lane endpoint_name code (Exec_policy.truncate_for_log stderr))
     | Unix.WSIGNALED signal ->
       Error
         (Printf.sprintf
            "%s_read_signaled: endpoint=%s signal=%d stderr=%s"
            lane endpoint_name signal (Exec_policy.truncate_for_log stderr))
     | Unix.WSTOPPED signal ->
       Error
         (Printf.sprintf
            "%s_read_stopped: endpoint=%s signal=%d"
            lane endpoint_name signal))
;;

let classify_read_outcome ~lane ~endpoint_name ~ok_exit_codes ~max_bytes outcome =
  classify_read_outcome_with_limit ~lane ~endpoint_name ~ok_exit_codes ~max_bytes:(Some max_bytes) outcome
;;

let run_endpoint_command_with_status
    ~acquire_endpoint
    ?(ok_exit_codes = [ 0 ])
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~command_argv
    ~max_bytes
    ~timeout_sec
    ()
  =
  let ( let* ) = Result.bind in
  let host_root = host_playground_root ~config ~meta in
  let* endpoint = acquire_endpoint ~cwd:host_root in
  let* cwd =
    Keeper_remote_path.host_to_remote ~base_path:config.base_path
      ~remote_root:(Keeper_sandbox_remote.remote_root endpoint) ~keeper:meta.name
      host_root
  in
  let stdout_mode = match max_bytes with None -> Keeper_sandbox_remote.Binary_bytes | Some _ -> Keeper_sandbox_remote.Text_paths in
  let runner = Keeper_sandbox_remote.runner ~stdout_mode ~timeout_sec endpoint in
  let outcome =
    runner ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:None
      ~argv:command_argv ~env:[||] ~cwd:(Some cwd)
  in
  let lane =
    Keeper_sandbox_remote.lane_prefix (Keeper_sandbox_remote.transport endpoint)
  in
  let endpoint_name = Keeper_sandbox_remote.name endpoint in
  classify_read_outcome_with_limit ~lane ~endpoint_name ~ok_exit_codes ~max_bytes outcome
;;

type read_dispatch =
  | Turn_runtime of Keeper_sandbox_factory.runtime_binding
  | Remote_dispatch
  | Attached_guest
      (** The guest reached without a turn: named by the keeper and the base
          path, never started by this read. *)
  | Docker_fallback

let binding_profile (binding : Keeper_sandbox_factory.runtime_binding) =
  match binding.guest_profile with
  | Docker_guest -> Docker
  | Micro_vm_guest -> Micro_vm
;;

let profile_contract_mismatch ~expected ~actual =
  Printf.sprintf
    "sandbox profile contract mismatch: caller expected %s but the turn factory froze %s"
    (sandbox_profile_to_string expected)
    (sandbox_profile_to_string actual)
;;

(* TEL-OK: pure fail-closed route selection. The selected backend performs and
   reports the read effect in [run_command_with_status] below. *)
let resolve_read_dispatch ~turn_sandbox_factory ~(meta : keeper_meta) ~cwd =
  let contract_holds actual =
    if actual = meta.sandbox_profile
    then Ok ()
    else Error (profile_contract_mismatch ~expected:meta.sandbox_profile ~actual)
  in
  let resolved = Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd in
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  (* The tree is on the endpoint: whatever runtime the factory holds is the
     way to reach it (a guest), never a place to read from directly. *)
  | Endpoint_owned ->
    (match resolved with
     | Runtime binding ->
       Result.map (fun () -> Remote_dispatch) (contract_holds (binding_profile binding))
     | Remote_ssh_profile ->
       Result.map (fun () -> Remote_dispatch) (contract_holds Remote_ssh)
     (* Holding no factory means holding no lifecycle authority over the
        guest, and reaching a running guest needs none: its name comes from
        the keeper and the base path, and it outlives the turn that booted
        it. Refusing here reported a reachable tree as unreachable. *)
     | No_factory ->
       (match meta.sandbox_profile with
        | Remote_ssh -> Ok Remote_dispatch
        | Micro_vm -> Ok Attached_guest
        | Docker ->
          Error "docker_has_no_remote_lane: a docker keeper's tree is a shared mount"))
  | Shared_mount ->
    (match resolved with
     | Runtime binding ->
       Result.map (fun () -> Turn_runtime binding) (contract_holds (binding_profile binding))
     | Remote_ssh_profile ->
       Error (profile_contract_mismatch ~expected:meta.sandbox_profile ~actual:Remote_ssh)
     | No_factory ->
       (match meta.sandbox_profile with
        | Docker -> Ok Docker_fallback
        (* Unreachable while [tree_location_of_profile Micro_vm] is
           [Endpoint_owned]; kept so a profile whose tree moves to a shared
           mount has to state its own answer rather than inherit Docker's. *)
        | Micro_vm ->
          Error
            "microvm_read_refuses_docker_substitution: a microVM keeper's tree is not reachable through a Docker container"
        | Remote_ssh -> Ok Remote_dispatch))
;;

let run_command_with_capture ?turn_sandbox_factory
    ?(ok_exit_codes = [ 0 ])
    ~config ~(meta : keeper_meta)
    ~(command_argv : string list) ~(max_bytes : int option)
    ~(timeout_sec : float) () : (Unix.process_status * string, string) result =
  if command_argv = [] then
    Error "run_command_with_status: command_argv is empty"
  else
    let cwd = host_playground_root ~config ~meta in
    match resolve_read_dispatch ~turn_sandbox_factory ~meta ~cwd with
    | Error _ as error -> error
    | Ok Remote_dispatch ->
      run_endpoint_command_with_status
        ~acquire_endpoint:(fun ~cwd ->
          Keeper_sandbox_remote_lane.endpoint ?turn_sandbox_factory ~config ~meta ~cwd ())
        ~ok_exit_codes ~config ~meta ~command_argv ~max_bytes ~timeout_sec ()
    | Ok Attached_guest ->
      (* The guest is not probed before the call: a stopped one fails the exec
         on its own, and probing first would spend a second subprocess on
         every read. The probe runs here instead, only to replace an exec
         failure with the fact behind it. *)
      (match
         run_endpoint_command_with_status
           ~acquire_endpoint:(fun ~cwd:_ ->
             Keeper_sandbox_remote_lane.attached_guest_endpoint ~config ~meta ())
           ~ok_exit_codes ~config ~meta ~command_argv ~max_bytes ~timeout_sec ()
       with
       | Ok _ as ok -> ok
       | Error message ->
         (match
            Keeper_turn_sandbox_runtime.microvm_guest_absence_reason
              ~timeout_sec ~config ~meta ()
          with
          | Some reason -> Error reason
          | None -> Error message))
    | Ok (Turn_runtime { runtime; _ }) ->
      (match max_bytes with
       | Some max_bytes -> Keeper_turn_sandbox_runtime.run_command_with_status
           ~ok_exit_codes runtime ~timeout_sec ~cwd ~command_argv ~max_bytes ()
       | None ->
         let capture_dir = Keeper_execute_output_files.capture_directory ~base_path:config.base_path in
         (match Keeper_turn_sandbox_runtime.run_exec_with_output_files
             ~capture_dir ~timeout_sec runtime ~cwd ~command_argv with
          | Error detail -> Error detail
          | Ok (status, _, _, Some files) ->
            (match status, files.stdout with
             | Unix.WEXITED 0, Process_output_capture.Complete_file {path; byte_length} ->
               (match Fs_compat.load_owned_regular_file ~ownership_root:capture_dir path with
                | Ok (Some bytes) when String.length bytes = byte_length -> Ok (status, bytes)
                | Ok _ | Error _ -> Error "Frozen runtime binary capture is missing or changed")
             | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ ->
               Error "Frozen runtime binary command failed or did not produce complete stdout")
          | Ok (_, _, _, None) -> Error "Frozen runtime has no authoritative binary output capture"))
    | Ok Docker_fallback ->
      let image =
        (Env_config_sandbox.Runtime.resolve_image meta.sandbox_image).tag
      in
      if String.trim image = "" then
        Error "keeper sandbox docker image is not configured"
      else
        let head_program =
          match command_argv with prog :: _ -> prog | [] -> "?"
        in
        match Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present ~image ~timeout_sec with
        | Error err ->
          let typed = Keeper_sandbox_error.Image_not_found { image } in
          Error
            (Printf.sprintf
               "docker_%s_failed: %s: %s"
               head_program
               (Keeper_sandbox_error.to_string typed)
               err)
        | Ok () ->
        match Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec with
        | Error err -> Error err
        | Ok seccomp_args ->
          let host_root = host_playground_root ~config ~meta in
          let croot = container_root ~meta in
          let container_name = container_name_of meta in
          let uid = Unix.getuid () in
          let gid = Unix.getgid () in
          match
            Keeper_secret_projection.docker_args_for_keeper
              ~base_path:config.base_path
              ~keeper_name:meta.name
              ~container_name
              ()
          with
          | Error err -> Error ("docker_read_failed: secret_projection: " ^ err)
          | Ok secret_projection ->
          let argv =
            build_docker_argv
              ~image
              ~container_name
              ~base_path:config.base_path
              ~host_root
              ~croot
              ~uid
              ~gid
              ~seccomp_args
              ~secret_args:secret_projection.docker_args
              ~command_argv
          in
          let captured =
            Eio_guard.protect
              ~finally:secret_projection.cleanup
              (fun () ->
                 Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
                   match max_bytes with
                   | Some _ -> Ok (Process_eio.run_argv_with_status
                       ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
                       ~cwd:(Config_dir_resolver.current_working_dir ()) ~timeout_sec argv)
                   | None ->
                     let capture_dir = Keeper_execute_output_files.capture_directory ~base_path:config.base_path in
                     let ((status, _, _), files) = Process_output_capture.with_capture ~capture_dir
                         (fun output_capture -> Process_eio.run_argv_with_status_split_streaming
                           ~output_capture ~on_stdout_chunk:(fun _ -> ()) ~on_stderr_chunk:(fun _ -> ())
                           ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
                           ~cwd:(Config_dir_resolver.current_working_dir ()) ~timeout_sec argv) in
                     match files.stdout with
                     | Process_output_capture.Complete_file {path; byte_length} ->
                       (match Fs_compat.load_owned_regular_file ~ownership_root:capture_dir path with
                        | Ok (Some bytes) when String.length bytes = byte_length ->
                          Unix.unlink path;
                          (match files.stderr with
                           | Process_output_capture.Complete_file {path; _} -> Unix.unlink path
                           | Process_output_capture.Incomplete_file _ | Process_output_capture.Capture_failed _ -> ());
                          Ok (status, bytes)
                        | Ok _ -> Error "Complete binary capture changed or disappeared"
                        | Error _ -> Error "Complete binary capture could not be read with ownership")
                     | Process_output_capture.Incomplete_file _ -> Error "Binary stdout did not reach authoritative EOF"
                     | Process_output_capture.Capture_failed {message; _} -> Error message))
          in
          let ( let* ) = Result.bind in
          let* st, out = captured in
          (match st with
           | Unix.WEXITED code
             when List.exists (fun ok_code -> ok_code = code) ok_exit_codes ->
             let body =
               match max_bytes with
               | Some limit when String.length out > limit -> String.sub out 0 limit
               | Some _ | None -> out
             in
             Ok (st, body)
           | Unix.WEXITED code ->
             Error
               (Printf.sprintf
                  "docker_%s_failed: exit=%d output=%s"
                  head_program code
                  (match max_bytes with
                   | Some _ -> Exec_policy.truncate_for_log out
                   | None -> Printf.sprintf "binary_bytes=%d sha256=%s"
                       (String.length out) Digestif.SHA256.(digest_string out |> to_hex)))
           | Unix.WSIGNALED n ->
             Error
               (Printf.sprintf "docker_%s_signaled: signal=%d" head_program n)
           | Unix.WSTOPPED n ->
             Error
               (Printf.sprintf "docker_%s_stopped: signal=%d" head_program n))

let run_command_with_status ?turn_sandbox_factory ?(ok_exit_codes=[0])
    ~config ~meta ~command_argv ~max_bytes ~timeout_sec () =
  run_command_with_capture ?turn_sandbox_factory ~ok_exit_codes ~config ~meta
    ~command_argv ~max_bytes:(Some max_bytes) ~timeout_sec ()

let run_command ?turn_sandbox_factory ?(ok_exit_codes = [ 0 ]) ~config ~meta
    ~command_argv ~max_bytes ~timeout_sec () =
  match
    run_command_with_status ?turn_sandbox_factory
      ~ok_exit_codes ~config ~meta
      ~command_argv ~max_bytes ~timeout_sec ()
  with
  | Error _ as err -> err
  | Ok (_st, out) -> Ok out

type read_error =
  | Missing_file of string
  | Not_a_file of string
  | Read_failed of string

let read_error_to_string = function
  | Missing_file detail | Not_a_file detail | Read_failed detail -> detail

let read_file ?turn_sandbox_factory ~config ~(meta : keeper_meta) ~host_path
    ~(max_bytes : int) ~(timeout_sec : float) () : (string, read_error) result =
  match container_path_of_host ~config ~meta ~host_path with
  | Error detail -> Error (Read_failed detail)
  | Ok backend_path ->
    let read () =
      run_command ?turn_sandbox_factory ~config ~meta
        ~command_argv:[ "cat"; backend_path ] ~max_bytes ~timeout_sec ()
      |> Result.map_error (fun detail -> Read_failed detail)
    in
    if
      Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile
      = Keeper_types_profile_sandbox.Endpoint_owned
    then read ()
    else
      let profile_label =
        Keeper_types_profile.sandbox_profile_to_string meta.sandbox_profile
      in
      (* Only shared trees can be classified from host filesystem evidence.
         Transport and access failures must not become missing-file advice. *)
      match Unix.stat host_path with
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        Error
          (Not_a_file
             (Printf.sprintf
                "%s_read_failed: path_is_directory: %s (Read requires a file; to \
                 list a directory use Execute with ls, e.g. argv=['ls','-la','%s'])"
                profile_label host_path host_path))
      | _ -> read ()
      | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        Error
          (Missing_file
             (Printf.sprintf
                "%s_read_failed: path_not_found: %s (host path does not exist; \
                 verify the relative path under your playground before calling Read)"
                profile_label host_path))
      | exception Unix.Unix_error (error, operation, argument) ->
        Error
          (Read_failed
             (Printf.sprintf "%s_read_failed: %s(%s): %s" profile_label
                operation argument (Unix.error_message error)))

let read_complete_file ?turn_sandbox_factory ~config ~(meta : keeper_meta) ~host_path ~timeout_sec () =
  let ( let* ) = Result.bind in
  let* path = container_path_of_host ~config ~meta ~host_path in
  let* _, bytes = run_command_with_capture ?turn_sandbox_factory ~config ~meta
      ~command_argv:["cat"; path] ~max_bytes:None ~timeout_sec () in
  Ok bytes

let read_raw_prefix ?turn_sandbox_factory ~config ~(meta : keeper_meta)
    ~host_path ~max_bytes ~timeout_sec () =
  let ( let* ) = Result.bind in
  if max_bytes <= 0 then Error "Raw prefix byte limit must be positive" else
  let* path = container_path_of_host ~config ~meta ~host_path in
  (* Binary capture must retain exact bytes; limiting its text projection would
     corrupt media. Bound the producing command instead, including endpoint
     reads where the host cannot stat the source. *)
  let* _, bytes = run_command_with_capture ?turn_sandbox_factory ~config ~meta
      ~command_argv:["head"; "-c"; string_of_int max_bytes; path]
      ~max_bytes:None ~timeout_sec () in
  Ok bytes
