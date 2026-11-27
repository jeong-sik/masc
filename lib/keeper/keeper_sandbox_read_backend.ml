(** See .mli for contract.

    The current Docker invocation mirrors the hardened-Execute sandbox in
    [keeper_tool_command_runtime.ml] (read-only rootfs, no caps, no network) with the
    playground mounted read-only and the default read program reduced to a
    single [cat]. The argv assembly is duplicated rather than shared so a
    future surgical change to either path does not need to wade through the
    other's flags. *)

open Keeper_meta_contract
open Keeper_types_profile

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let host_playground_root ~config ~(meta : keeper_meta) =
  Keeper_sandbox.host_root_abs_of_meta ~config meta
  |> Keeper_alerting_path.normalize_path_for_check
  |> strip_trailing_slashes

let container_root ~(meta : keeper_meta) =
  Keeper_sandbox.container_root meta.name

(* A backend path and the backend-side root it was admitted under. The root
   is what the opened file is checked against where the file is opened
   (#35934): the host decides on a path's spelling, the backend's open
   follows its symlinks, and only the backend sees what that open reached. *)
type confined_path = { path : string; root : string }

let confined_path_of_host_impl ~read_authority ~(config : Workspace.config) ~(meta : keeper_meta) ~host_path
    : (confined_path, string) result =
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  | Endpoint_owned ->
    let open Result.Syntax in
    let* remote_workspace_root =
      (match read_authority with
       | None -> Keeper_sandbox_remote_lane.workspace_root ~config ~meta
       | Some authority -> Keeper_sandbox_remote_lane.with_read_authority_endpoint authority ~config ~meta
           (fun endpoint -> Ok (Keeper_sandbox_remote.workspace_root endpoint)))
    in
    let* lane = Keeper_sandbox_remote_lane.path_lane meta in
    (match
       Keeper_remote_path.host_to_remote ~lane ~base_path:config.base_path
         ~remote_workspace_root ~keeper:meta.name host_path
     with
     | Ok path ->
       Ok { path; root = Keeper_remote_path.normalize_remote remote_workspace_root }
     | Error refusal ->
       (* Only what the keeper's own tree refused may be a path under the
          endpoint's declared roots (#38593): the endpoint's own name, read as
          itself. A name in the tree always translates, however a declared
          root is spelled. *)
       let* declared =
         (match read_authority with
          | None -> Keeper_sandbox_remote_lane.declared_endpoint_match ~config ~meta host_path
          | Some authority -> Ok (Keeper_sandbox_remote_lane.read_authority_declared_match authority host_path))
       in
       (match declared with
        | Some { Exec_policy_paths.root; path } -> Ok { path; root }
        | None -> Error (Keeper_remote_path.jail_refusal_to_string refusal)))
  | Shared_mount ->
    let host_root = host_playground_root ~config ~meta in
    let host_norm =
      Keeper_alerting_path.normalize_path_for_check host_path
      |> strip_trailing_slashes
    in
    let croot = container_root ~meta in
    if host_norm = host_root then Ok { path = croot; root = croot }
    else if String.starts_with ~prefix:(host_root ^ "/") host_norm then
      let suffix =
        String.sub host_norm
          (String.length host_root + 1)
          (String.length host_norm - String.length host_root - 1)
      in
      Ok { path = Filename.concat croot suffix; root = croot }
    else
      Error
        (Printf.sprintf
           "container_path_of_host: %s is not inside playground %s"
           host_norm host_root)

let container_path_of_host_impl ~read_authority ~config ~meta ~host_path =
  Result.map (fun confined -> confined.path)
    (confined_path_of_host_impl ~read_authority ~config ~meta ~host_path)

let container_path_of_host ~config ~meta ~host_path =
  container_path_of_host_impl ~read_authority:None ~config ~meta ~host_path

let container_path_of_host_with_authority ~read_authority ~config ~meta ~host_path =
  container_path_of_host_impl ~read_authority:(Some read_authority) ~config ~meta ~host_path

let confined_path_of_host ~config ~meta ~host_path =
  confined_path_of_host_impl ~read_authority:None ~config ~meta ~host_path

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
    "--entrypoint"; "";
    image;
  ]
  @ command_argv

let container_name_of meta =
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Docker_read
       { keeper_name = meta.name
         (* DET-OK: pid and wall-clock ms make a one-shot name unique per run. *)
       ; pid = Unix.getpid ()
       ; started_ms = int_of_float (Unix.gettimeofday () *. 1000.0)
       })

(* A program that exits with an accepted code of 2 or more says why on stderr:
   rg exits 2 after an error and prints it there. The docker lane returns both
   streams in one string, so a Grep failure there carries rg's message. This
   lane returns the two apart, and an accepted exit used to keep stdout alone,
   so a Grep on a missing path came back as exit 2 with nothing else. The error
   text goes first so a cut at [max_bytes] keeps it. Exit 0 and exit 1 keep
   stdout alone: for rg they mean a match and no match, stdout holds the result
   lines, and a warning on stderr must not join them. *)
let error_text_then_stdout ~stderr ~stdout =
  if String.ends_with ~suffix:"\n" stderr
  then stderr ^ stdout
  else stderr ^ "\n" ^ stdout
;;

(* One runner, two ways of getting the endpoint. A turn hands in the lane's
   [endpoint], which may start the guest it owns; a caller with no turn hands
   in [attached_guest_endpoint], which cannot. Path translation and status
   handling are the same either way, so they live here once. *)
(* The read backend's translation of a [run_outcome] into a read result.
   [Transport_failed] is always an error -- this is what stops a down lane
   from reading as an empty [Ok] on the Grep lane, whose [ok_exit_codes]
   accepts exit 1. Exit 0 and 1 return stdout alone; an accepted exit of 2 or
   more returns stderr, then stdout. Pure and exported so the distinction is
   tested directly (test_keeper_sandbox_read_backend, the differential test). *)
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
         | None -> stdout
         | Some limit ->
           let text =
             if code <= 1 || String.equal stderr ""
             then stdout
             else error_text_then_stdout ~stderr ~stdout
           in
           if String.length text > limit then String.sub text 0 limit else text
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
  let open Result.Syntax in
  let host_root = host_playground_root ~config ~meta in
  let* endpoint = acquire_endpoint ~cwd:host_root in
  let* lane = Keeper_sandbox_remote_lane.path_lane meta in
  let* cwd =
    Keeper_remote_path.host_to_remote ~lane ~base_path:config.base_path
      ~remote_workspace_root:(Keeper_sandbox_remote.workspace_root endpoint)
      ~keeper:meta.name
      host_root
    |> Result.map_error Keeper_remote_path.jail_refusal_to_string
  in
  let stdout_mode = match max_bytes with None -> Keeper_sandbox_remote.Binary_bytes | Some _ -> Keeper_sandbox_remote.Text_capture in
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

let run_command_with_capture ?read_authority ?turn_sandbox_factory
    ?(ok_exit_codes = [ 0 ])
    ~config ~(meta : keeper_meta)
    ~(command_argv : string list) ~(max_bytes : int option)
    ~(timeout_sec : float) () : (Unix.process_status * string, string) result =
  if command_argv = [] then
    Error "run_command_with_status: command_argv is empty"
  else match read_authority with
  | Some authority ->
    Keeper_sandbox_remote_lane.with_read_authority_endpoint ~timeout_sec authority ~config ~meta (fun endpoint ->
      run_endpoint_command_with_status
        ~acquire_endpoint:(fun ~cwd:_ -> Ok endpoint)
        ~ok_exit_codes ~config ~meta ~command_argv ~max_bytes ~timeout_sec ())
  | None ->
    let cwd = host_playground_root ~config ~meta in
    match resolve_read_dispatch ~turn_sandbox_factory ~meta ~cwd with
    | Error _ as error -> error
    | Ok Remote_dispatch ->
      run_endpoint_command_with_status
        ~acquire_endpoint:(fun ~cwd ->
          Keeper_sandbox_remote_lane.endpoint ?turn_sandbox_factory
            ~access:Keeper_sandbox_remote.Read_only ~config ~meta ~cwd ())
        ~ok_exit_codes ~config ~meta ~command_argv ~max_bytes ~timeout_sec ()
    | Ok Attached_guest ->
      (* Apple endpoint admission observes guest ownership and state before
         returning; other backends rely on exec. After an error, a separate
         absence observation can replace it with a confirmed fact. *)
      (match
         run_endpoint_command_with_status
           ~acquire_endpoint:(fun ~cwd:_ ->
             Keeper_sandbox_remote_lane.attached_guest_endpoint ~timeout_sec
               ~access:Keeper_sandbox_remote.Read_only ~config ~meta ())
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
             | Unix.WEXITED code, _
               when code <> 0 && List.exists (fun ok -> ok = code) ok_exit_codes ->
               (* A caller-declared non-zero exit (e.g. a read sentinel) is a
                  classified outcome, not a capture fault; it carries no
                  payload. *)
               Ok (status, "")
             | Unix.WEXITED 0, Process_output_capture.Complete_file {path; byte_length} ->
               (match Fs_compat.load_owned_regular_file ~ownership_root:capture_dir path with
                | Ok (Some bytes) when String.length bytes = byte_length -> Ok (status, bytes)
                | Ok _ | Error _ -> Error "Frozen runtime binary capture is missing or changed")
             | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), Process_output_capture.Complete_file _)
             | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), Process_output_capture.Incomplete_file _)
             | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), Process_output_capture.Capture_failed _) ->
               Error "Frozen runtime binary command failed or did not produce complete stdout")
          | Ok (_, _, _, None) -> Error "Frozen runtime has no authoritative binary output capture"))
    | Ok Docker_fallback ->
      match
        Keeper_sandbox_image_resolver.for_keeper ~base_path:config.Workspace.base_path meta
      with
      | Error error -> Error (Keeper_turn_sandbox_runtime.image_unresolved_message error)
      | Ok pinned ->
        let image = pinned.Keeper_sandbox_image_catalog.reference in
        let head_program =
          match command_argv with prog :: _ -> prog | [] -> "?"
        in
        match Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present ~image ~timeout_sec with
        | Error err ->
          Error
            (Printf.sprintf "docker_%s_failed: image_not_found: %s" head_program err)
        | Ok () ->
        match Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec with
        | Error err -> Error err
        | Ok seccomp_args ->
          let host_root = host_playground_root ~config ~meta in
          let croot = container_root ~meta in
          let container_name =
            Keeper_sandbox_container_name.to_string (container_name_of meta)
          in
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
          let open Result.Syntax in
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
                       (String.length out) Agent_core_sha256.(digest_string out |> to_hex)))
           | Unix.WSIGNALED n ->
             Error
               (Printf.sprintf "docker_%s_signaled: signal=%d" head_program n)
           | Unix.WSTOPPED n ->
             Error
               (Printf.sprintf "docker_%s_stopped: signal=%d" head_program n))

let run_command_with_status ?read_authority ?turn_sandbox_factory ?(ok_exit_codes=[0])
    ~config ~meta ~command_argv ~max_bytes ~timeout_sec () =
  run_command_with_capture ?read_authority ?turn_sandbox_factory ~ok_exit_codes ~config ~meta
    ~command_argv ~max_bytes:(Some max_bytes) ~timeout_sec ()

let run_command ?read_authority ?turn_sandbox_factory ?(ok_exit_codes = [ 0 ]) ~config ~meta
    ~command_argv ~max_bytes ~timeout_sec () =
  match
    run_command_with_status ?read_authority ?turn_sandbox_factory
      ~ok_exit_codes ~config ~meta
      ~command_argv ~max_bytes ~timeout_sec ()
  with
  | Error _ as err -> err
  | Ok (_st, out) -> Ok out

type read_error =
  | Missing_file of string
  | Not_a_file of string
  | Read_failed of string
  | Read_refused of string

let read_error_to_string = function
  | Missing_file detail
  | Not_a_file detail
  | Read_failed detail
  | Read_refused detail -> detail

(* HIGH-RISK-UNREVIEWED: sandbox read containment (#35934). A human security
   review is needed before this is relied on.

   The host admits a path by its spelling ({!confined_path_of_host_impl}),
   but the file is opened inside the backend, whose open follows every
   symlink on the way. A link inside the tree that names a file outside it
   passed the host's check and was opened for real. So the decision is made
   on the object the open returned, where it was opened: the script opens
   the path once onto stdin, asks the kernel which file that descriptor is
   ([/proc/self/fd/0], a Linux guest -- every backend here is one), and
   refuses it unless it lies under the root. The reader then consumes that
   same descriptor. Nothing is opened twice, so there is no window between
   the check and the read for a link to be swapped in.

   The root the opened file is compared with is the root as configured (the
   container mount target, the endpoint's workspace or declared root), never
   one resolved in the backend at read time. A keeper that can write the
   root's parent could replace the root with a symlink to [/]; a root
   resolved per read would then admit every file. No lane resolves its root
   once when it is bound, so the configured spelling is the trusted value,
   and the script refuses with [Root_moved] unless the root still resolves
   to exactly that spelling. A root configured through a symlink is refused
   the same way: it has to name its resolved directory.

   The open is [command exec <]: a plain [exec <] that fails makes dash
   exit 2 before [|| exit] runs. After the open the descriptor must still be
   a regular file, so a FIFO or device swapped in after the [-f] test is
   refused instead of read. A FIFO swapped in between that test and the open
   blocks the open itself until the read timeout ends the run: sh has no
   non-blocking open.

   The script says why it read nothing with exit codes it chooses; the
   reader classifies by them, never by stderr. The root, the path and the
   numbers are positional arguments of [sh], never spliced into the script.
   [exec <] opens the file before the pipeline, whose status is its last
   command's, so an unreadable file still ends with its own exit. *)
type confined_open_refusal =
  | Path_missing
  | Not_a_regular_file
  | Open_failed
  | Outside_root
  | Opened_file_unresolved
  | Root_moved

let confined_open_exit = function
  | Path_missing -> 3
  | Not_a_regular_file -> 4
  | Open_failed -> 5
  | Outside_root -> 6
  | Opened_file_unresolved -> 7
  | Root_moved -> 8

let confined_open_refusals =
  [ Path_missing; Not_a_regular_file; Open_failed; Outside_root; Opened_file_unresolved; Root_moved ]

let confined_open_refusal_of_exit code =
  List.find_opt (fun refusal -> confined_open_exit refusal = code) confined_open_refusals

let confined_open_exits = List.map confined_open_exit confined_open_refusals

(* [$1] is the root as configured, [$2] the path. A root of [/] admits every
   file; any other root admits itself and what lies below it. [cd -P] and
   [pwd -P] are shell builtins, so resolving the root needs no program. *)
let confined_open_prelude =
  Printf.sprintf
    {|if [ ! -e "$2" ]; then exit %d; fi; if [ ! -f "$2" ]; then exit %d; fi; command exec < "$2" || exit %d; o=$(readlink /proc/self/fd/0) || exit %d; [ -f /proc/self/fd/0 ] || exit %d; r=$(cd -P -- "$1" && pwd -P) || exit %d; [ "$r" = "$1" ] || exit %d; case "$1" in /) ;; *) case "$o" in "$1"|"$1"/*) ;; *) exit %d;; esac;; esac; |}
    (confined_open_exit Path_missing)
    (confined_open_exit Not_a_regular_file)
    (confined_open_exit Open_failed)
    (confined_open_exit Opened_file_unresolved)
    (confined_open_exit Not_a_regular_file)
    (confined_open_exit Opened_file_unresolved)
    (confined_open_exit Root_moved)
    (confined_open_exit Outside_root)

type confined_read =
  | Line_window of { start_line : int; max_bytes : int }
  | Byte_prefix of { max_bytes : int }
  | Whole_file

(* A window that starts past line 1 streams from that line, so the byte bound
   applies to the window and not to the file's prefix. Bounding the prefix
   left every line after the first [max_bytes] unreachable to Read. *)
let confined_read_argv ~(confined : confined_path) read =
  let body, operands =
    match read with
    | Line_window { start_line; max_bytes } ->
      ( {|if [ "$3" -le 1 ]; then head -c "$4"; else tail -n +"$3" | head -c "$4"; fi|}
      , [ string_of_int start_line; string_of_int (max 0 max_bytes) ] )
    | Byte_prefix { max_bytes } ->
      ({|head -c "$3"|}, [ string_of_int (max 0 max_bytes) ])
    | Whole_file -> ({|exec cat|}, [])
  in
  [ "sh"; "-c"; confined_open_prelude ^ body; "sh"; confined.root; confined.path ]
  @ operands

let read_error_of_refusal ~profile_label ~host_path = function
  | Path_missing ->
    Missing_file
      (Printf.sprintf
         "%s_read_failed: path_not_found: %s (no file there; verify the path \
          before calling Read)"
         profile_label host_path)
  | Not_a_regular_file ->
    Not_a_file
      (Printf.sprintf
         "%s_read_failed: path_is_not_a_file: %s (Read requires a regular \
          file; to list a directory use Execute with ls, e.g. \
          argv=['ls','-la','%s'])"
         profile_label host_path host_path)
  | Open_failed ->
    Read_failed
      (Printf.sprintf "%s_read_failed: open_failed: %s" profile_label host_path)
  | Outside_root ->
    Read_refused
      (Printf.sprintf
         "%s_read_refused: path_resolves_outside_sandbox: %s (a symlink on the \
          way leads to a file outside the sandbox root)"
         profile_label host_path)
  | Opened_file_unresolved ->
    Read_failed
      (Printf.sprintf
         "%s_read_failed: opened_file_unresolved: %s (the backend could not \
          resolve the opened file or the sandbox root, so containment was \
          not proven)"
         profile_label host_path)
  | Root_moved ->
    Read_refused
      (Printf.sprintf
         "%s_read_refused: sandbox_root_moved: %s (the sandbox root no longer \
          resolves to the directory it was configured as; a configured root \
          must name its resolved directory)"
         profile_label host_path)

(* One run of a confined read, classified. [capture] picks text ([Some n])
   or exact bytes ([None]). *)
let run_confined_read ?read_authority ?turn_sandbox_factory ~config ~(meta : keeper_meta)
    ~host_path ~confined ~read ~capture ~timeout_sec () =
  let profile_label = Keeper_types_profile.sandbox_profile_to_string meta.sandbox_profile in
  match
    run_command_with_capture ?read_authority ?turn_sandbox_factory
      ~ok_exit_codes:(0 :: confined_open_exits)
      ~config ~meta
      ~command_argv:(confined_read_argv ~confined read)
      ~max_bytes:capture ~timeout_sec ()
  with
  | Error detail -> Error (Read_failed detail)
  | Ok (Unix.WEXITED 0, body) -> Ok body
  | Ok (Unix.WEXITED code, _) ->
    (match confined_open_refusal_of_exit code with
     | Some refusal -> Error (read_error_of_refusal ~profile_label ~host_path refusal)
     (* [ok_exit_codes] admits only 0 and the refusal exits. *)
     | None ->
       Error
         (Read_failed
            (Printf.sprintf "%s_read_failed: unexpected exit %d for %s"
               profile_label code host_path)))
  | Ok ((Unix.WSIGNALED _ | Unix.WSTOPPED _), _) ->
    Error
      (Read_failed
         (Printf.sprintf "%s_read_failed: unexpected status for %s"
            profile_label host_path))

let read_file ?read_authority ?turn_sandbox_factory ?(start_line = 1) ~config ~(meta : keeper_meta)
    ~host_path ~(max_bytes : int) ~(timeout_sec : float) () : (string, read_error) result =
  match confined_path_of_host_impl ~read_authority ~config ~meta ~host_path with
  | Error detail -> Error (Read_failed detail)
  | Ok confined ->
    let profile_label =
      Keeper_types_profile.sandbox_profile_to_string meta.sandbox_profile
    in
    let read () =
      (* [max_bytes] used to be spent on [cat]'s finished output: the child
         wrote the whole file and the drainer read every byte to EOF, and only
         then was the first [max_bytes] kept. Reads ask for 16 KiB
         ([Common.max_tool_result_wire_bytes]), so a Read of a large file paid
         a whole read and a whole pipe transfer to answer with a few pages.
         Retention was already capped -- Process_eio keeps head 8 MiB plus
         tail 256 KiB -- so what moves here is the production and the
         transfer, not the heap.

         [head -c] puts the limit on the producer. It also closes a trap that
         no caller has reached yet: asked for more than that head cap, the old
         path returned head, then "(truncated N bytes)", then tail, cut to
         [max_bytes] -- which is not a prefix of anything.

         Same shape, and same reason, as the bounded [od -N] chunk read in
         Keeper_browser_upload. *)
      run_confined_read ?read_authority ?turn_sandbox_factory ~config ~meta ~host_path
        ~confined ~read:(Line_window { start_line; max_bytes })
        ~capture:(Some max_bytes) ~timeout_sec ()
    in
    if
      Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile
      = Keeper_types_profile_sandbox.Endpoint_owned
    then read ()
    else
      (* A shared tree is also on this host, so a missing path is refused
         before a sandbox process is spent on it. *)
      match Unix.stat host_path with
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        Error
          (Not_a_file
             (Printf.sprintf
                "%s_read_failed: path_is_directory: %s (Read requires a file; to \
                 list a directory use Execute with ls, e.g. argv=['ls','-la','%s'])"
                profile_label host_path host_path))
      | { Unix.st_kind =
            ( Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
            | Unix.S_SOCK )
        ; _
        } -> read ()
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

let read_complete_file ?read_authority ?turn_sandbox_factory ~config ~(meta : keeper_meta) ~host_path ~timeout_sec () =
  match confined_path_of_host_impl ~read_authority ~config ~meta ~host_path with
  | Error _ as error -> error
  | Ok confined ->
    run_confined_read ?read_authority ?turn_sandbox_factory ~config ~meta ~host_path
      ~confined ~read:Whole_file ~capture:None ~timeout_sec ()
    |> Result.map_error read_error_to_string

let read_raw_prefix ?read_authority ?turn_sandbox_factory ~config ~(meta : keeper_meta)
    ~host_path ~max_bytes ~timeout_sec () =
  if max_bytes <= 0 then
    Error (Read_failed "Raw prefix byte limit must be positive")
  else
  (* Binary capture must retain exact bytes; limiting its text projection would
     corrupt media. Bound the producing command instead ([head -c]) and
     capture with [None] so remote stays on [Binary_bytes] and the runtimes
     stay on their output-file capture. There is no host [Unix.stat]
     pre-check: a docker host path may not exist on this host, and a
     directory already maps to [Not_a_file] via [! -f], so the refusal exits
     are the single classifier on every profile.

     The frozen Turn_runtime binary capture honours [ok_exit_codes], so the
     refusal exits classify there too. *)
  match confined_path_of_host_impl ~read_authority ~config ~meta ~host_path with
  | Error detail -> Error (Read_failed detail)
  | Ok confined ->
    run_confined_read ?read_authority ?turn_sandbox_factory ~config ~meta ~host_path
      ~confined ~read:(Byte_prefix { max_bytes }) ~capture:None ~timeout_sec ()
