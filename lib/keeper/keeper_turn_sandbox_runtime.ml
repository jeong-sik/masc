open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let turn_container_kind =
  Keeper_types_profile_sandbox.sandbox_container_kind_to_string
    Keeper_types_profile_sandbox.Sandbox_turn
;;

type state =
  | Not_started
  | Running of { container_name : string }

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
  }

let get_state t = Atomic.get t.state
let set_state t state = Atomic.set t.state state

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
    | Network_host -> "host"
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

let repos_in_playground host_root =
  let repos_dir = Filename.concat host_root "repos" in
  if not (Sys.file_exists repos_dir && Sys.is_directory repos_dir)
  then []
  else (
    try
      Sys.readdir repos_dir
      |> Array.to_list
      |> List.filter (fun name ->
        let p = Filename.concat repos_dir name in
        try Sys.is_directory p && Sys.file_exists (Filename.concat p ".git") with
        | Sys_error _ -> false)
      |> List.sort compare
    with
    | Sys_error _ -> [])

let rec skip_worktree_prefix = function
  | ".worktrees" :: _branch :: rest -> rest
  | "./.worktrees" :: _branch :: rest -> rest
  | other -> other

let find_repo_segment_and_suffix ~repos ~host_cwd =
  let segments = String.split_on_char '/' host_cwd in
  let rec find_suffix = function
    | [] -> None
    | head :: tail ->
      if List.mem head repos then
        let effective_tail = skip_worktree_prefix tail in
        Some (head, String.concat "/" effective_tail)
      else
        find_suffix tail
  in
  find_suffix segments

let container_cwd_of_host (t : t) ~host_cwd =
  match container_path_of_host t ~host_path:host_cwd with
  | Ok container_cwd -> container_cwd
  | Error _ ->
    match Keeper_cwd_response.profile_independent_cwd
            ~container_root:t.container_root ~host_cwd with
    | Some cwd -> cwd
    | None ->
      let repos = repos_in_playground t.host_root in
      (match find_repo_segment_and_suffix ~repos ~host_cwd with
       | Some (repo_name, suffix) ->
         let logical_path =
           Filename.concat (Filename.concat "repos" repo_name) suffix
         in
         Filename.concat t.container_root logical_path
       | None -> t.container_root)
;;

let host_cwd_of_container (t : t) ~container_cwd =
  let container_root_norm = normalize_path t.container_root in
  let container_cwd_norm = normalize_path container_cwd in
  if container_cwd_norm = container_root_norm
  then Ok t.host_root
  else if String.starts_with ~prefix:(container_root_norm ^ "/") container_cwd_norm
  then (
    let suffix =
      String.sub
        container_cwd_norm
        (String.length container_root_norm + 1)
        (String.length container_cwd_norm - String.length container_root_norm - 1)
    in
    Ok (Filename.concat t.host_root suffix))
  else
    Error
      (Printf.sprintf
         "host_path_of_container: %s is not inside container root %s"
         container_cwd_norm
         t.container_root)
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

let container_missing_error out =
  String_util.contains_substring_ci out "no such container"
  || String_util.contains_substring_ci out "is not running"
;;

let image_preflight_start_error (failure : Keeper_sandbox_runtime.classified_error) =
  Keeper_sandbox_runtime.docker_image_preflight_failure_message
    ~prefix:"docker_container_start_failed"
    failure
;;

let max_eintr_retries = 8

let run_argv_with_status_retry_eintr ?timeout_sec argv =
  Docker_spawn_throttle.with_slot (fun () ->
    let rec loop attempts_left =
      let st, out =
        Masc_exec.Exec_gate.run_argv_with_status
          ?timeout_sec
          ~actor:`System_sandbox
          ~raw_source:(String.concat " " argv)
          ~summary:"keeper turn sandbox command"
          ~env:
            (Env_keeper_scrub.filter_control_plane_environment_c_messages
               (Unix.environment ()))
          ~cwd:(Config_dir_resolver.current_working_dir ())
          argv
      in
      match st with
      | Unix.WEXITED 127
        when attempts_left > 0
             && String_util.contains_substring_ci out "interrupted system call" ->
        loop (attempts_left - 1)
      | _ -> st, out
    in
    loop max_eintr_retries)
;;

let output_for_status ~(stdout : string) ~(stderr : string) =
  match stdout, stderr with
  | "", err -> err
  | out, "" -> out
  | out, err -> out ^ "\n" ^ err
;;

let retryable_eintr_status ~attempts_left st ~stdout ~stderr =
  match st with
  | Unix.WEXITED 127
    when attempts_left > 0
         && String_util.contains_substring_ci
              (output_for_status ~stdout ~stderr)
              "interrupted system call" ->
    true
  | _ -> false
;;

type chunk = [ `Stdout of string | `Stderr of string ]

type guard_state = {
  held_chunks : chunk list;
  saw_retry_marker : bool;
  pass_through : bool;
  visible_flushed : bool;
  marker_scan_tail : string;
  release_scheduled : bool;
  prefix_release_deferrals : int;
  closed : bool;
}

type action =
  | Emit of chunk
  | Schedule_release

type retry_stream_guard = {
  on_stdout_chunk : (string -> unit) option;
  on_stderr_chunk : (string -> unit) option;
  state : guard_state Atomic.t;
}

let retry_eintr_marker = "interrupted system call"
let retry_stream_guard_release_delay_sec = 0.2
let retry_stream_guard_prefix_deferral_limit = 1
let retry_eintr_marker_lower = String.lowercase_ascii retry_eintr_marker

let initial_guard_state = {
  held_chunks = [];
  saw_retry_marker = false;
  pass_through = false;
  visible_flushed = false;
  marker_scan_tail = "";
  release_scheduled = false;
  prefix_release_deferrals = 0;
  closed = false;
}

let retry_marker_tail text =
  let max_len = max 0 (String.length retry_eintr_marker - 1) in
  let len = String.length text in
  if len <= max_len then text else String.sub text (len - max_len) max_len
;;

let retry_marker_prefix_pending tail =
  let tail = String.lowercase_ascii tail in
  let marker_len = String.length retry_eintr_marker_lower in
  let min_prefix_len = min 4 (marker_len - 1) in
  let max_len = min (String.length tail) (marker_len - 1) in
  let rec loop len =
    if len < min_prefix_len
    then false
    else
      let suffix = String.sub tail (String.length tail - len) len in
      let prefix = String.sub retry_eintr_marker_lower 0 len in
      String.equal suffix prefix || loop (len - 1)
  in
  loop max_len
;;

let update_retry_marker_scan state chunk =
  let scan_text = state.marker_scan_tail ^ chunk in
  let saw_marker = String_util.contains_substring_ci scan_text retry_eintr_marker in
  { state with
    saw_retry_marker = state.saw_retry_marker || saw_marker;
    marker_scan_tail = retry_marker_tail scan_text
  }
;;

let invoke_guard_output_callback f chunk =
  try
    f chunk;
    ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Misc.warn
      "[Keeper_turn_sandbox_runtime] output chunk callback error, continuing: %s"
      (Printexc.to_string exn)
;;

let chunk_has_visible_callback ~on_stdout_chunk ~on_stderr_chunk = function
  | `Stdout _ -> Option.is_some on_stdout_chunk
  | `Stderr _ -> Option.is_some on_stderr_chunk
;;

let emit_guard_chunk guard = function
  | `Stdout chunk ->
    (match guard.on_stdout_chunk with
     | None -> ()
     | Some f -> invoke_guard_output_callback f chunk)
  | `Stderr chunk ->
    (match guard.on_stderr_chunk with
     | None -> ()
     | Some f -> invoke_guard_output_callback f chunk)
;;

let perform_action guard = function
  | Emit chunk -> emit_guard_chunk guard chunk
  | Schedule_release -> ()
;;

let transition ~on_stdout_chunk ~on_stderr_chunk state chunk =
  let text =
    match chunk with
    | `Stdout s -> s
    | `Stderr s -> s
  in
  let state = update_retry_marker_scan state text in
  if
    state.pass_through
    && not state.saw_retry_marker
    && not (retry_marker_prefix_pending state.marker_scan_tail)
  then
    let visible_flushed =
      state.visible_flushed
      || chunk_has_visible_callback ~on_stdout_chunk ~on_stderr_chunk chunk
    in
    { state with visible_flushed }, [ Emit chunk ]
  else
    let held_chunks = chunk :: state.held_chunks in
    let should_schedule =
      (not state.release_scheduled)
      && not state.closed
      && not state.saw_retry_marker
    in
    let state =
      { state with
        held_chunks;
        release_scheduled = state.release_scheduled || should_schedule
      }
    in
    let actions = if should_schedule then [ Schedule_release ] else [] in
    state, actions
;;

let release_transition ~on_stdout_chunk ~on_stderr_chunk state =
  if state.closed || state.saw_retry_marker
  then { state with release_scheduled = false }, []
  else if
    retry_marker_prefix_pending state.marker_scan_tail
    && state.prefix_release_deferrals < retry_stream_guard_prefix_deferral_limit
  then
    ( { state with
        prefix_release_deferrals = state.prefix_release_deferrals + 1;
        release_scheduled = true }
    , [] )
  else
    let chunks = List.rev state.held_chunks in
    let visible_flushed =
      state.visible_flushed
      || List.exists (chunk_has_visible_callback ~on_stdout_chunk ~on_stderr_chunk) chunks
    in
    let state =
      { state with
        pass_through = true;
        prefix_release_deferrals = 0;
        held_chunks = [];
        visible_flushed;
        release_scheduled = false
      }
    in
    let actions = List.map (fun chunk -> Emit chunk) chunks in
    state, actions
;;

let close_transition ~on_stdout_chunk ~on_stderr_chunk ~retryable state =
  let state = { state with closed = true; release_scheduled = false } in
  if retryable
  then { state with held_chunks = [] }, []
  else
    let chunks = List.rev state.held_chunks in
    let visible_flushed =
      state.visible_flushed
      || List.exists (chunk_has_visible_callback ~on_stdout_chunk ~on_stderr_chunk) chunks
    in
    { state with held_chunks = []; visible_flushed }, List.map (fun chunk -> Emit chunk) chunks
;;

(* Docker EINTR retry output arrives as a short burst. Release ordinary held
   prefixes after a small Eio sleep so sparse successful commands still stream
   without invoking user callbacks from an unmanaged systhread. *)
let rec schedule_guard_release guard =
  match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
  | Some sw, Some clock ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock retry_stream_guard_release_delay_sec;
      let rec apply () =
        let old_state = Atomic.get guard.state in
        let new_state, actions =
          release_transition
            ~on_stdout_chunk:guard.on_stdout_chunk
            ~on_stderr_chunk:guard.on_stderr_chunk
            old_state
        in
        if Atomic.compare_and_set guard.state old_state new_state
        then actions
        else apply ()
      in
      let actions = apply () in
      List.iter (perform_action guard) actions;
      if List.memq Schedule_release actions then schedule_guard_release guard)
  | _ ->
    (* Without Eio context there is no safe live timer surface for user
       callbacks. Held chunks are emitted when the attempt completes. *)
    ()
;;

let guard_attempt_callback guard chunk =
  let rec apply () =
    let old_state = Atomic.get guard.state in
    let new_state, actions =
      transition
        ~on_stdout_chunk:guard.on_stdout_chunk
        ~on_stderr_chunk:guard.on_stderr_chunk
        old_state
        chunk
    in
    if Atomic.compare_and_set guard.state old_state new_state
    then actions
    else apply ()
  in
  let actions = apply () in
  List.iter (perform_action guard) actions;
  if List.memq Schedule_release actions then schedule_guard_release guard
;;

let run_split_retry_eintr_with_live_callbacks
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~run_attempt
      ()
  =
  let rec loop attempts_left =
    let guard =
      { on_stdout_chunk
      ; on_stderr_chunk
      ; state = Atomic.make initial_guard_state
      }
    in
    let has_output_callback =
      Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
    in
    let attempt_on_stdout_chunk =
      if has_output_callback
      then Some (fun chunk -> guard_attempt_callback guard (`Stdout chunk))
      else None
    in
    let attempt_on_stderr_chunk =
      if has_output_callback
      then Some (fun chunk -> guard_attempt_callback guard (`Stderr chunk))
      else None
    in
    let st, stdout, stderr =
      run_attempt
        ?on_stdout_chunk:attempt_on_stdout_chunk
        ?on_stderr_chunk:attempt_on_stderr_chunk
        ()
    in
    let retryable = retryable_eintr_status ~attempts_left st ~stdout ~stderr in
    let actions =
      let rec apply () =
        let old_state = Atomic.get guard.state in
        let new_state, actions =
          close_transition
            ~on_stdout_chunk:guard.on_stdout_chunk
            ~on_stderr_chunk:guard.on_stderr_chunk
            ~retryable
            old_state
        in
        if Atomic.compare_and_set guard.state old_state new_state
        then actions
        else apply ()
      in
      apply ()
    in
    if retryable
    then loop (attempts_left - 1)
    else (
      List.iter (perform_action guard) actions;
      st, stdout, stderr)
  in
  loop max_eintr_retries
;;

let run_argv_with_status_split_retry_eintr
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      argv
  =
  Docker_spawn_throttle.with_slot (fun () ->
    run_split_retry_eintr_with_live_callbacks
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~run_attempt:(fun ?on_stdout_chunk ?on_stderr_chunk () ->
        let raw_source = String.concat " " argv in
        let env =
          Env_keeper_scrub.filter_control_plane_environment_c_messages
            (Unix.environment ())
        in
        let cwd = Config_dir_resolver.current_working_dir () in
        match on_stdout_chunk, on_stderr_chunk with
        | None, None ->
          Masc_exec.Exec_gate.run_argv_with_status_split
            ?timeout_sec
            ~actor:`System_sandbox
            ~raw_source
            ~summary:"keeper turn sandbox command"
            ~env
            ~cwd
            argv
        | _ ->
          (* DET-OK: absent stream callbacks mean the caller requested capture only. *)
          let on_stdout_chunk =
            Option.value on_stdout_chunk ~default:(fun _ -> ())
          in
          (* DET-OK: stderr callback absence has the same capture-only meaning. *)
          let on_stderr_chunk =
            Option.value on_stderr_chunk ~default:(fun _ -> ())
          in
          Masc_exec.Exec_gate.run_argv_with_status_split_streaming
            ?timeout_sec
            ~actor:`System_sandbox
            ~raw_source
            ~summary:"keeper turn sandbox command streaming"
            ~env
            ~cwd
            ~on_stdout_chunk
            ~on_stderr_chunk
            argv)
      ())
;;

let run_argv_with_stdin_and_status_retry_eintr ?timeout_sec ~stdin_content argv =
  Docker_spawn_throttle.with_slot (fun () ->
    let rec loop attempts_left =
      let st, out =
        Masc_exec.Exec_gate.run_argv_with_stdin_and_status
          ?timeout_sec
          ~actor:`System_sandbox
          ~raw_source:(String.concat " " argv)
          ~summary:"keeper turn sandbox stdin command"
          ~env:
            (Env_keeper_scrub.filter_control_plane_environment_c_messages
               (Unix.environment ()))
          ~cwd:(Config_dir_resolver.current_working_dir ())
          ~stdin_content
          argv
      in
      match st with
      | Unix.WEXITED 127
        when attempts_left > 0
             && String_util.contains_substring_ci out "interrupted system call" ->
        loop (attempts_left - 1)
      | _ -> st, out
    in
    loop max_eintr_retries)
;;

let run_argv_with_stdin_and_status_split_retry_eintr
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~stdin_content
      argv
  =
  Docker_spawn_throttle.with_slot (fun () ->
    run_split_retry_eintr_with_live_callbacks
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~run_attempt:(fun ?on_stdout_chunk ?on_stderr_chunk () ->
        let raw_source = String.concat " " argv in
        let env =
          Env_keeper_scrub.filter_control_plane_environment_c_messages
            (Unix.environment ())
        in
        let cwd = Config_dir_resolver.current_working_dir () in
        Masc_exec.Exec_gate.run_argv_with_stdin_and_status_split
          ?timeout_sec
          ~actor:`System_sandbox
          ~raw_source
          ~summary:"keeper turn sandbox stdin command"
          ~env
          ~cwd
          ?on_stdout_chunk
          ?on_stderr_chunk
          ~stdin_content
          argv)
      ())
;;

let run_argv_pipeline_with_status_split_retry_eintr
      ?timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      stages
  =
  Docker_spawn_throttle.with_slot (fun () ->
    run_split_retry_eintr_with_live_callbacks
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~run_attempt:(fun ?on_stdout_chunk ?on_stderr_chunk () ->
        let raw_source =
          stages
          |> List.map (fun stage -> String.concat " " stage.Process_eio.argv)
          |> String.concat " | "
        in
        Masc_exec.Exec_gate.run_argv_pipeline_with_status_split
          ?timeout_sec
          ~actor:`System_sandbox
          ~raw_source
          ~summary:"keeper turn sandbox pipeline command"
          ?on_stdout_chunk
          ?on_stderr_chunk
          stages)
      ())
;;

let container_inspect_timeout_sec () =
  Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm ()
;;

let inspect_container_exists ~timeout_sec container_name =
  let inspect_argv =
    Keeper_sandbox_runtime.docker_command_argv ()
    @ [ "inspect"; "--format"; "{{.Id}}"; container_name ]
  in
  let inspect_st, inspect_out =
    run_argv_with_status_retry_eintr ~timeout_sec inspect_argv
  in
  match inspect_st with
  | Unix.WEXITED 0 -> Ok ()
  | _ -> Error inspect_out
;;

let inspect_container_running ~timeout_sec container_name =
  let inspect_argv =
    Keeper_sandbox_runtime.docker_command_argv ()
    @ [ "inspect"; "--format"; "{{.State.Running}}"; container_name ]
  in
  let inspect_st, inspect_out =
    run_argv_with_status_retry_eintr ~timeout_sec inspect_argv
  in
  match inspect_st, String.trim inspect_out with
  | Unix.WEXITED 0, "true" -> Ok ()
  | Unix.WEXITED 0, state ->
    Error
      (Printf.sprintf
         "docker_container_not_running: %s"
         (if state = "" then "<empty>" else state))
  | _ -> Error inspect_out
;;

let start_container (t : t) ~timeout_sec =
  let image =
    match t.meta.sandbox_image with
    | Some img when String.trim img <> "" -> img
    | _ -> Env_config_sandbox.Runtime.docker_image ()
  in
  if String.trim image = ""
  then Error "keeper sandbox docker image is not configured"
  else (
    match
      Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class
        ~image
        ~timeout_sec
    with
    | Error failure -> Error (image_preflight_start_error failure)
    | Ok () ->
      let _cleanup =
        Keeper_sandbox_runtime.maybe_cleanup_stale_containers
          ~base_path:t.config.base_path

          ()
      in
      match Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime ~timeout_sec with
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
         let argv =
           Keeper_sandbox_runtime.docker_command_argv ()
           @ [ "run"; "-d"; "--rm"; "--name"; container_name ]
           @ Keeper_sandbox_runtime.docker_run_pull_never_args ()
           @ Keeper_sandbox_runtime.docker_label_args
               ~base_path:t.config.base_path
               ~keeper_name:t.meta.name
               ~container_kind:turn_container_kind
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
           @ identity_mounts
           @ network_args
           @ [ image; "tail"; "-f"; "/dev/null" ]
         in
         let st, out =
           Eio_guard.protect
             ~finally:secret_projection.cleanup
             (fun () -> run_argv_with_status_retry_eintr argv)
         in
         (match st with
         | Unix.WEXITED 0 ->
            (match
               inspect_container_exists
                 ~timeout_sec:(container_inspect_timeout_sec ())
                 container_name
             with
             | Ok () ->
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
                 run_argv_with_status_retry_eintr
                   ~timeout_sec:(container_inspect_timeout_sec ())
                   rm_argv
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
                ~container_kind:turn_container_kind
                ~network_label
                out
            in
            Error
              (Printf.sprintf
                 "docker_container_start_failed: %s%s"
                 (Keeper_sandbox_runtime.docker_failure_output_for_log out)
                 mount_context)))))
;;

let ensure_started ?(validate_running = false) (t : t) ~timeout_sec =
  match get_state t with
  | Running { container_name } ->
    if not validate_running
    then Ok container_name
    else (
      match
        inspect_container_running
          ~timeout_sec:(container_inspect_timeout_sec ())
          container_name
      with
      | Ok () -> Ok container_name
      | Error _ ->
        set_state t Not_started;
        start_container t ~timeout_sec)
  | Not_started -> start_container t ~timeout_sec
;;

let run_exec_with_status_split_once
      ?(validate_cached_container = false)
      ?(stdin_content : string option)
      ?on_stdout_chunk
      ?on_stderr_chunk
      (t : t)
      ~timeout_sec
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match ensure_started ~validate_running:validate_cached_container t ~timeout_sec with
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
      Keeper_sandbox_runtime.docker_command_argv ()
      @ [ "exec"; "--user"; Printf.sprintf "%d:%d" t.uid t.gid; "-w"; container_cwd ]
      @ Keeper_sandbox_runtime.docker_sandbox_env_args
          ~base_path:t.config.base_path
          ~container_root:t.container_root
      @ (match stdin_content with
         | Some _ -> [ "-i" ]
         | None -> [])
      @ (container_name :: command_argv)
    in
    let has_output_callback =
      Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
    in
    let st, stdout, stderr =
      match stdin_content, has_output_callback with
      | Some content, false ->
        run_argv_with_stdin_and_status_split_retry_eintr
          ~timeout_sec
          ~stdin_content:content
          argv
      | None, false -> run_argv_with_status_split_retry_eintr ~timeout_sec argv
      | Some content, true ->
        run_argv_with_stdin_and_status_split_retry_eintr
          ~timeout_sec
          ?on_stdout_chunk
          ?on_stderr_chunk
          ~stdin_content:content
          argv
      | None, true ->
        run_argv_with_status_split_retry_eintr
          ~timeout_sec
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
      ~timeout_sec
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
      t
      ~timeout_sec
      ~cwd
      ~command_argv
  with
  | Error _ as err -> err
  | Ok ((Unix.WEXITED 126 | Unix.WEXITED 127), stdout, stderr)
    when container_missing_error (output_for_status ~stdout ~stderr) ->
    set_state t Not_started;
    (match
       run_exec_with_status_split_once
         ?stdin_content
         ?on_stdout_chunk
         ?on_stderr_chunk
         t
         ~timeout_sec
         ~cwd
         ~command_argv
     with
     | Ok _ as ok -> ok
     | Error _ as err -> err)
  | Ok other -> Ok other
;;

let run_exec_with_status
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~timeout_sec
      (t : t)
      ~(cwd : string)
      ~(command_argv : string list)
  =
  match
    run_exec_with_status_split
      ?stdin_content
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~timeout_sec
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
  Keeper_sandbox_runtime.docker_command_argv ()
  @ [ "exec"; "-i"; "--user"; Printf.sprintf "%d:%d" t.uid t.gid; "-w"; container_cwd ]
  @ Keeper_sandbox_runtime.docker_sandbox_env_args
      ~base_path:t.config.base_path
      ~container_root:t.container_root
  @ (container_name :: rewrite_command_argv t command_argv)
;;

let run_exec_pipeline_with_status_once
      ?(validate_cached_container = false)
      ?on_stdout_chunk
      ?on_stderr_chunk
      (t : t)
      ~timeout_sec
      ~(cwd : string)
      ~(stages : exec_pipeline_stage list)
  =
  match ensure_started ~validate_running:validate_cached_container t ~timeout_sec with
  | Error _ as err -> err
  | Ok container_name ->
    let process_stages =
      List.map
        (fun { command_argv; cwd = stage_cwd } ->
          let cwd = Option.value stage_cwd ~default:cwd in
          let container_cwd = container_cwd_of_host t ~host_cwd:cwd in
          let argv = docker_exec_pipeline_argv t ~container_name ~container_cwd command_argv in
          { Process_eio.argv
          ; env =
              Some
                (Env_keeper_scrub.filter_control_plane_environment_c_messages
                   (Unix.environment ()))
          ; cwd = Some (Config_dir_resolver.current_working_dir ())
          })
        stages
    in
    Ok
      (run_argv_pipeline_with_status_split_retry_eintr
         ~timeout_sec
         ?on_stdout_chunk
         ?on_stderr_chunk
         process_stages)
;;

let run_exec_pipeline_with_status ?on_stdout_chunk ?on_stderr_chunk ~timeout_sec t ~cwd ~stages =
  let has_output_callback =
    Option.is_some on_stdout_chunk || Option.is_some on_stderr_chunk
  in
  match
    run_exec_pipeline_with_status_once
      ~validate_cached_container:has_output_callback
      t
      ~timeout_sec
      ?on_stdout_chunk
      ?on_stderr_chunk
      ~cwd
      ~stages
  with
  | Error _ as err -> err
  | Ok ((Unix.WEXITED 126 | Unix.WEXITED 127), stdout, stderr)
    when container_missing_error (output_for_status ~stdout ~stderr) ->
    set_state t Not_started;
    (match
       run_exec_pipeline_with_status_once
         t
         ~timeout_sec
         ?on_stdout_chunk
         ?on_stderr_chunk
         ~cwd
         ~stages
     with
     | Ok _ as ok -> ok
     | Error _ as err -> err)
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
    Keeper_sandbox_runtime.docker_command_argv ()
    @
    [ "exec"
    ; "-i"
    ; "--user"
    ; Printf.sprintf "%d:%d" t.uid t.gid
    ; "-w"
    ; container_cwd
    ]
    @ Keeper_sandbox_runtime.docker_sandbox_env_args
        ~base_path:t.config.base_path
        ~container_root:t.container_root
    @ [ container_name; "bash"; "-l"; "-s" ]
  in
  match ensure_started t ~timeout_sec with
  | Error _ as err -> err
  | Ok container_name ->
    let argv = docker_exec_argv ~container_name in
    let st, out =
      run_argv_with_stdin_and_status_retry_eintr
        ~stdin_content:cmd
        argv
    in
    if container_missing_error out
    then (
      match st with
      | Unix.WEXITED (126 | 127) ->
        set_state t Not_started;
        (match ensure_started t ~timeout_sec with
         | Error _ as err -> err
         | Ok container_name ->
           let argv = docker_exec_argv ~container_name in
           Ok
             (run_argv_with_stdin_and_status_retry_eintr
                ~stdin_content:cmd
                argv))
      | _ -> Ok (st, out))
    else Ok (st, out)
;;

let write_file_common
      ~timeout_sec:_
      (t : t)
      ~(host_path : string)
      ~(content : string)
      ~(append : bool)
      ()
  =
  match container_path_of_host t ~host_path with
  | Error _ as err -> err
  | Ok _container_path ->
    let host_path = normalize_path host_path in
    (try
       Fs_compat.mkdir_p (Filename.dirname host_path);
       if append
       then Fs_compat.append_file host_path content
       else Fs_compat.save_file host_path content;
       Ok ()
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | Sys_error msg -> Error msg
     | Unix.Unix_error (err, fn, arg) ->
       Error
         (Printf.sprintf
            "%s%s%s"
            (Unix.error_message err)
            (if String.equal fn "" then "" else ": " ^ fn)
            (if String.equal arg "" then "" else " " ^ arg)))
;;

let overwrite_file ~timeout_sec t ~host_path ~content () =
  write_file_common ~timeout_sec t ~host_path ~content ~append:false ()
;;

let append_file ~timeout_sec t ~host_path ~content () =
  write_file_common ~timeout_sec t ~host_path ~content ~append:true ()
;;

let cleanup (t : t) =
  match get_state t with
  | Not_started -> ()
  | Running { container_name } ->
    set_state t Not_started;
    let rm_timeout =
      Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Cleanup_rm ()
    in
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
        run_argv_with_status_retry_eintr ~timeout_sec:rm_timeout check_argv
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
      run_argv_with_status_retry_eintr ~timeout_sec:rm_timeout rm_argv
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
           run_argv_with_status_retry_eintr ~timeout_sec:rm_timeout rm_argv
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
              container_name))
;;
