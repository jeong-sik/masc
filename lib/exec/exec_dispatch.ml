(* P7: Pipeline-Native Dispatch
   Execute Shell_ir.t directly via Process_eio without going through
   /bin/bash. Simple commands use argv-based spawn. Redirect-free host
   pipelines use streaming process pipes; redirect-free sandboxed
   Guest/SSH pipelines stream through the injected pipeline runner.
   Unsupported shapes fall back to deterministic stdout->stdin chaining. *)

type dispatch_result = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
}

let ( let* ) = Result.bind

(* Naming the descriptors keeps their numbers out of the redirect fold. *)
let stdin_fd = 0
let stdout_fd = 1
let stderr_fd = 2

type redirect_target =
  | Capture_stdout
  | Capture_stderr
  | Drop

type redirect_plan = {
  stdout_target : redirect_target;
  stderr_target : redirect_target;
}

let default_redirect_plan =
  { stdout_target = Capture_stdout; stderr_target = Capture_stderr }

let redirect_target_of_fd plan = function
  | 1 -> Ok plan.stdout_target
  | 2 -> Ok plan.stderr_target
  | fd -> Error (Printf.sprintf "unsupported redirect fd: %d" fd)

let set_redirect_target plan fd target =
  match fd with
  | 1 -> Ok { plan with stdout_target = target }
  | 2 -> Ok { plan with stderr_target = target }
  | fd -> Error (Printf.sprintf "unsupported redirect fd: %d" fd)

(* Streams the child holds a file for. [Captured] / [Inherited] mean the
   stream stays on the capture path, so a command with no file redirect
   produces exactly the plumbing it did before. *)
type attachments = {
  stdin_from : Process_eio.input_origin;
  stdout_to : Process_eio.output_destination;
  stderr_to : Process_eio.output_destination;
}

let no_attachments =
  { stdin_from = Process_eio.Inherited
  ; stdout_to = Process_eio.Captured
  ; stderr_to = Process_eio.Captured
  }

(* [From_string] counts. It used to not, because nothing put one in
   [attachments] -- the only [From_string] was built further down from the
   [stdin_content] argument, inside the path this predicate selects. A literal
   redirect puts one here, and the path that discards attachments would drop
   it without a word. *)
let holds_a_source = function
  | Process_eio.Inherited -> false
  | Process_eio.From_string _ | Process_eio.Read_from _ -> true

let holds_a_sink = function
  | Process_eio.Captured -> false
  | Process_eio.Written_to _ -> true

let attaches_a_file { stdin_from; stdout_to; stderr_to } =
  holds_a_source stdin_from || holds_a_sink stdout_to || holds_a_sink stderr_to

(* A redirect target is written as the command sees it, so a relative one is
   resolved against the command's own cwd. This process's cwd is not that
   directory -- a command without one runs at the filesystem root -- so a
   relative target with no cwd names two different files depending on who
   resolves it, and is refused rather than resolved against a guess. *)
(* A target already resolved for this host is opened as given. One still in
   the command's namespace is only this filesystem when the command runs
   here; the caller checks that before opening. *)
let redirect_path ~cwd target =
  match target with
  | Redirect_scope.On_this_host { path; _ } -> Ok path
  | Redirect_scope.In_command_namespace scope ->
    let raw = Path_scope.raw scope in
    if not (Filename.is_relative raw)
    then Ok raw
    else (
      match cwd with
      | Some base -> Ok (Filename.concat base raw)
      | None ->
        Error
          (Printf.sprintf
             "relative redirect target %s needs the command to declare a cwd"
             raw))

(* A stream owns one direction, so each (descriptor, mode) pair is named
   rather than collapsed: a new mode has to be decided here, not absorbed. *)
let sink_of_mode ~path = function
  | Redirect_scope.Write -> Ok (Process_eio.Written_to { path; append = false })
  | Redirect_scope.Append -> Ok (Process_eio.Written_to { path; append = true })
  | Redirect_scope.Read ->
      Error (Printf.sprintf "an output stream cannot be opened for reading: %s" path)

let attach_file ~cwd attach ~fd ~target ~mode =
  let* path = redirect_path ~cwd target in
  if fd = stdin_fd
  then
    match mode with
    | Redirect_scope.Read -> Ok { attach with stdin_from = Process_eio.Read_from { path } }
    | Redirect_scope.Write | Redirect_scope.Append ->
        Error (Printf.sprintf "stdin cannot be opened for writing: %s" path)
  else if fd = stdout_fd
  then Result.map (fun sink -> { attach with stdout_to = sink }) (sink_of_mode ~path mode)
  else if fd = stderr_fd
  then Result.map (fun sink -> { attach with stderr_to = sink }) (sink_of_mode ~path mode)
  else
    Error
      (Printf.sprintf
         "unsupported redirect fd: %d (a command owns only %d, %d and %d)"
         fd
         stdin_fd
         stdout_fd
         stderr_fd)

(* A file redirect is carried out by this process, so the path has to name a
   file on this filesystem. Running on the host, the command's namespace is
   this one. Running in a container or on a remote host it is not, and only a
   layer that knows the mounts can translate; until it has, the target says
   so. *)
let target_is_openable_here ~(sandbox : Sandbox_target.t) target =
  match sandbox, target with
  | _, Redirect_scope.On_this_host _ -> true
  | Sandbox_target.Host, Redirect_scope.In_command_namespace _ -> true
  | ( Sandbox_target.Docker _
    | Sandbox_target.Micro_vm _
    | Sandbox_target.Ssh _
    | Sandbox_target.Delegated _ ),
    Redirect_scope.In_command_namespace _ ->
    false

(* A sandbox runner hands back what the container wrote as a string: this
   process never holds the container's pipe, so it cannot give the child a
   descriptor. The capture happens either way, so writing it out here costs
   nothing over returning it -- and the bytes stop travelling back to the
   caller, which is the point of redirecting them. *)
let deliver_capture destination text =
  match destination with
  | Process_eio.Captured -> Ok text
  | Process_eio.Written_to { path; append } ->
    (try
       let flags =
         [ Open_wronly; Open_creat; (if append then Open_append else Open_trunc) ]
       in
       let oc = open_out_gen flags 0o644 path in
       Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc text);
       Ok ""
     with
     | Sys_error message -> Error (Printf.sprintf "cannot write %s: %s" path message))

let unresolved_target_message ~sandbox target =
  let path = Path_scope.raw (Redirect_scope.target_as_written target) in
  match sandbox with
  | Sandbox_target.Ssh _ ->
    Printf.sprintf
      "remote_ssh_redirect_unavailable: remote file redirect %s has no remote \
       file-operation transport; refusing host fallback"
      path
  | Sandbox_target.Host | Docker _ | Micro_vm _ ->
    Printf.sprintf
      "a file redirect to %s is not carried out for a sandboxed stage: the path \
       names a file inside the sandbox and would be opened on this host"
      path
  | Sandbox_target.Delegated _ ->
    Printf.sprintf
      "a file redirect to %s is not carried out for a delegated stage: the \
       caller answers with text, not descriptors"
      path

let redirect_plan_of_redirects ~cwd redirects =
  let step (plan, attach) = function
    | Redirect_scope.Fd_to_fd { src; dst } ->
        let* target = redirect_target_of_fd plan dst in
        let* plan = set_redirect_target plan src target in
        Ok (plan, attach)
    | Redirect_scope.File { fd; target; mode } ->
      (* Discarding output needs no file: the capture model already has a
         value for "throw these bytes away". Discarding input does not, so
         it goes down the attachment path and opens the device. *)
      (match mode with
       | Redirect_scope.Write | Redirect_scope.Append
         when Path_scope.is_discard_sink (Redirect_scope.target_as_written target) ->
         let* plan = set_redirect_target plan fd Drop in
         Ok (plan, attach)
       | Redirect_scope.Write | Redirect_scope.Append | Redirect_scope.Read ->
         let* attach = attach_file ~cwd attach ~fd ~target ~mode in
         Ok (plan, attach))
    | Redirect_scope.Literal { bytes } ->
      (* Content with no file, and stdin is the only descriptor that can take
         it, which the type says rather than the run time. *)
      Ok (plan, { attach with stdin_from = Process_eio.From_string bytes })
  in
  List.fold_left
    (fun acc redirect -> Result.bind acc (fun state -> step state redirect))
    (Ok (default_redirect_plan, no_attachments))
    redirects

let add_redirected_output target text (stdout, stderr) =
  match target with
  | Capture_stdout -> stdout ^ text, stderr
  | Capture_stderr -> stdout, stderr ^ text
  | Drop -> stdout, stderr

let apply_redirect_plan plan result =
  (* Captured stdout/stderr are already split by the lower process layer, so
     fd-to-fd redirection is deterministic but cannot preserve temporal
     interleaving between the two original streams. *)
  let stdout, stderr =
    ("", "")
    |> add_redirected_output plan.stdout_target result.stdout
    |> add_redirected_output plan.stderr_target result.stderr
  in
  { result with stdout; stderr }

let unsupported_redirect_result message =
  { status = Unix.WEXITED 1; stdout = ""; stderr = message }

type output_emission =
  { stdout_emitted : bool ref
  ; stderr_emitted : bool ref
  }

let tracked_output_callback on_output_chunk =
  let emitted = { stdout_emitted = ref false; stderr_emitted = ref false } in
  match on_output_chunk with
  | None -> None, emitted
  | Some on_chunk ->
      let on_chunk = function
        | `Stdout chunk ->
            emitted.stdout_emitted := true;
            on_chunk (`Stdout chunk)
        | `Stderr chunk ->
            emitted.stderr_emitted := true;
            on_chunk (`Stderr chunk)
      in
      Some on_chunk, emitted

let emit_unseen_captured_output on_output_chunk emitted result =
  match on_output_chunk with
  | None -> result
  | Some on_chunk ->
      if (not !(emitted.stdout_emitted)) && result.stdout <> ""
      then on_chunk (`Stdout result.stdout);
      if (not !(emitted.stderr_emitted)) && result.stderr <> ""
      then on_chunk (`Stderr result.stderr);
      result

let emit_stdout_if_captured on_output_chunk stdout =
  match on_output_chunk with
  | None -> ()
  | Some on_chunk when stdout <> "" -> on_chunk (`Stdout stdout)
  | Some _ -> ()

let emit_pipeline_stage_result ?(emit_stdout = false) on_output_chunk result =
  match on_output_chunk with
  | None -> ()
  | Some on_chunk ->
      if emit_stdout && result.stdout <> "" then on_chunk (`Stdout result.stdout);
      if result.stderr <> "" then on_chunk (`Stderr result.stderr)

let status_is_success = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let status_is_timeout status =
  (* Process_eio decides what a timeout status is; this used to repeat its
     number (#28651). *)
  match Process_eio.exit_reason_of_status status with
  | Process_eio.Timed_out -> true
  | Process_eio.Completed _ | Process_eio.Signaled _ | Process_eio.Stopped _ ->
    false

let pipeline_status current stage_status =
  if status_is_success stage_status then current else stage_status

(* --- arg resolution --- *)

let rec resolve_arg = function
  | Shell_ir.Lit (s, _) -> s
  | Concat parts ->
      let buf = Buffer.create 64 in
      List.iter (fun a -> Buffer.add_string buf (resolve_arg a)) parts;
      Buffer.contents buf
  | Var (name, _) ->
      (match Sys.getenv_opt name with Some v -> v | None -> "")

let resolve_env env_bindings =
  List.map
    (fun (k, v) -> k ^ "=" ^ resolve_arg v)
    env_bindings
  |> Array.of_list

let env_key entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some idx -> String.sub entry 0 idx

let resolve_host_env ?base_host_env = function
  | [] -> base_host_env
  | env_bindings ->
      let overrides = resolve_env env_bindings |> Array.to_list in
      let override_keys = List.map env_key overrides in
      let base =
        match base_host_env with
        | Some env -> env
        | None -> Unix.environment ()
      in
      let inherited =
        base
        |> Array.to_list
        |> List.filter (fun entry ->
          not (List.mem (env_key entry) override_keys))
      in
      Some (Array.of_list (inherited @ overrides))

(* --- simple command execution --- *)

(* Dispatch a simple command via the IR-carried Sandbox_target.

   The [Host] case forks/execs through [Process_eio]; guest and [Ssh] cases
   are wired up by [lib/keeper] using a closure over its own runtime
   ([Keeper_turn_sandbox_runtime] for guests, the SSH lane runner for [Ssh]).
   Which one runs is decided by the keeper's [sandbox_profile] carried on the
   IR, not by this function. *)
let process_spec_of_simple (s : Shell_ir.simple) =
  let bin = Exec_program.to_string s.bin in
  let argv = bin :: List.map resolve_arg s.args in
  let env = resolve_env s.env in
  let cwd =
    match s.cwd with
    | None -> None
    | Some scope -> Some (Path_scope.raw scope)
  in
  (argv, env, cwd)

let dispatch_simple ?base_host_env ?timeout_sec ?stdin_content ?on_output_chunk
    (s : Shell_ir.simple) =
  let on_output_chunk, emitted = tracked_output_callback on_output_chunk in
  let argv, env, cwd = process_spec_of_simple s in
  let result =
    match redirect_plan_of_redirects ~cwd s.redirects with
    | Error message -> unsupported_redirect_result message
    | Ok (redirect_plan, attachments) when attaches_a_file attachments -> (
      match
        List.find_opt
          (function
            | Redirect_scope.Fd_to_fd _ | Redirect_scope.Literal _ -> false
            | Redirect_scope.File { target; _ } ->
              not (target_is_openable_here ~sandbox:s.sandbox target))
          s.redirects
      with
      | Some (Redirect_scope.File { target; _ }) ->
        unsupported_redirect_result
          (unresolved_target_message ~sandbox:s.sandbox target)
      | Some (Redirect_scope.Fd_to_fd _ | Redirect_scope.Literal _) | None ->
        (match s.sandbox with
         | Docker { runner; _ }
         | Micro_vm { runner; _ }
         | Ssh { runner; _ }
         | Delegated { caller = runner } ->
           (* stdin from a file is read here and handed to the runner as
              bytes, for the same reason: the runner takes a string. *)
           let stdin_for_runner =
             match attachments.stdin_from with
             | Process_eio.Read_from { path } ->
               (try
                  let ic = open_in_bin path in
                  Some
                    (Fun.protect
                       ~finally:(fun () -> close_in ic)
                       (fun () -> really_input_string ic (in_channel_length ic)))
                with Sys_error _ -> None)
             | Process_eio.From_string content -> Some content
             | Process_eio.Inherited -> stdin_content
           in
           (match
              runner
                ~on_stdout_chunk:None
                ~on_stderr_chunk:None
                ~stdin_content:stdin_for_runner
                ~argv
                ~env
                ~cwd
            with
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn ->
              { status = Unix.WEXITED 1; stdout = ""; stderr = Printexc.to_string exn }
            | Sandbox_target.Transport_failed { reason = _; stdout; stderr } ->
              (* The lane never delivered a command result; surface it the way
                 an exception is -- a failed status with the error already in
                 stderr -- so a boxed command is not read as a clean run. *)
              { status = Unix.WEXITED 1; stdout; stderr }
            | Sandbox_target.Ran { status; stdout; stderr } ->
              (match
                 ( deliver_capture attachments.stdout_to stdout
                 , deliver_capture attachments.stderr_to stderr )
               with
               | Error message, _ | _, Error message ->
                 unsupported_redirect_result message
               | Ok stdout, Ok stderr ->
                 apply_redirect_plan redirect_plan { status; stdout; stderr }))
         | Host ->
        let host_env = resolve_host_env ?base_host_env s.env in
        let stdin_from =
          (* A declared redirect wins over the caller's piped-in bytes: a
             pipeline stage that names its own input is not reading the
             previous stage. *)
          match attachments.stdin_from with
          | Process_eio.Read_from _ as declared -> declared
          | Process_eio.From_string _ as declared -> declared
          | Process_eio.Inherited ->
            (match stdin_content with
             | Some content -> Process_eio.From_string content
             | None -> Process_eio.Inherited)
        in
        (match
           Process_eio.run_argv_with_redirects
             ?timeout_sec
             ?env:host_env
             ?cwd
             ~stdin:stdin_from
             ~stdout:attachments.stdout_to
             ~stderr:attachments.stderr_to
             argv
         with
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | exception exn ->
           { status = Unix.WEXITED 1; stdout = ""; stderr = Printexc.to_string exn }
         | Error message -> unsupported_redirect_result message
         | Ok (status, stdout, stderr) ->
           apply_redirect_plan redirect_plan { status; stdout; stderr })))
    | Ok (redirect_plan, _) -> (
      let child_on_output_chunk =
        if s.redirects = [] then on_output_chunk else None
      in
      match s.sandbox with
      | Host ->
        let host_env = resolve_host_env ?base_host_env s.env in
        let run () =
          match stdin_content with
          | None ->
            (match child_on_output_chunk with
             | None ->
               Process_eio.run_argv_with_status_split
                 ?timeout_sec
                 ?env:host_env
                 ?cwd
                 argv
             | Some on_chunk ->
               Process_eio.run_argv_with_status_split_streaming
                 ?timeout_sec
                 ?env:host_env
                 ?cwd
                 ~on_stdout_chunk:(fun chunk -> on_chunk (`Stdout chunk))
                 ~on_stderr_chunk:(fun chunk -> on_chunk (`Stderr chunk))
                 argv)
          | Some stdin_content ->
            (match child_on_output_chunk with
             | None ->
               Process_eio.run_argv_with_stdin_and_status_split
                 ?timeout_sec
                 ?env:host_env
                 ?cwd
                 ~stdin_content
                 argv
             | Some on_chunk ->
               Process_eio.run_argv_with_stdin_and_status_split
                 ?timeout_sec
                 ?env:host_env
                 ?cwd
                 ~on_stdout_chunk:(fun chunk -> on_chunk (`Stdout chunk))
                 ~on_stderr_chunk:(fun chunk -> on_chunk (`Stderr chunk))
                 ~stdin_content
                 argv)
        in
        (match run () with
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | exception exn ->
             { status = Unix.WEXITED 1
             ; stdout = ""
             ; stderr = Printexc.to_string exn
             }
         | status, stdout, stderr ->
             apply_redirect_plan redirect_plan { status; stdout; stderr })
      | Docker { runner; _ }
      | Micro_vm { runner; _ }
      | Ssh { runner; _ }
      | Delegated { caller = runner } ->
        let on_stdout_chunk, on_stderr_chunk =
          match child_on_output_chunk with
          | None -> None, None
          | Some on_chunk ->
              ( Some (fun chunk -> on_chunk (`Stdout chunk))
              , Some (fun chunk -> on_chunk (`Stderr chunk)) )
        in
        (match
           runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd
         with
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | exception exn ->
             { status = Unix.WEXITED 1
             ; stdout = ""
             ; stderr = Printexc.to_string exn
             }
         | status, stdout, stderr ->
             apply_redirect_plan redirect_plan { status; stdout; stderr }))
  in
  emit_unseen_captured_output on_output_chunk emitted result

(* --- pipeline + entry point (mutually recursive) --- *)

let invalid_pipeline stderr = { status = Unix.WEXITED 1; stdout = ""; stderr }

(* A stage's own redirections travel with it, so a pipeline that names a file
   still runs on real process pipes. Dropping to the buffered chain instead
   would run each stage to completion in turn, which has no backpressure: a
   producer that only stops when its reader closes -- `yes | head -1` -- never
   stops at all. *)
let host_pipeline_specs ?base_host_env stages =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Simple simple :: rest ->
        (match simple.sandbox with
         | Host ->
             let argv, _env, cwd = process_spec_of_simple simple in
             (match redirect_plan_of_redirects ~cwd simple.redirects with
              | Error _ -> None
              | Ok (plan, attach) when plan = default_redirect_plan ->
                  let stage : Process_eio.pipeline_stage =
                    { argv
                    ; env = resolve_host_env ?base_host_env simple.env
                    ; cwd
                    ; stdin = attach.stdin_from
                    ; stdout = attach.stdout_to
                    ; stderr = attach.stderr_to
                    }
                  in
                  loop (stage :: acc) rest
              (* A capture-side plan -- a merge or a discard -- is applied to
                 captured text after the run, which a per-stage pipeline has no
                 place to do. Those stay on the existing path. *)
              | Ok _ -> None)
         (* A delegated stage is not a host process, so it cannot join a
            host process pipeline; it falls back to per-stage dispatch,
            where the caller answers for it. *)
         | Docker _ | Micro_vm _ | Ssh _ | Delegated _ -> None)
    (* A stage that is itself a pipeline or a sequence needs a subshell,
       which this dispatcher does not spawn. *)
    | (Shell_ir.Pipeline _ | Shell_ir.Sequence _) :: _ -> None
  in
  loop [] stages

(* The streaming pipeline runner is per sandbox target: every stage must
   carry the same target value and that target must inject a
   [pipeline_runner]. Guest and SSH stages collect identically. *)
let sandbox_pipeline_specs stages =
  let rec loop pipeline_runner sandbox_target acc = function
    | [] -> Option.map (fun runner -> runner, List.rev acc) pipeline_runner
    | Shell_ir.Simple simple :: rest ->
        let same_sandbox_target =
          match sandbox_target with
          | None -> true
          | Some first_target -> simple.sandbox == first_target
        in
        (match simple.sandbox with
         | Docker { pipeline_runner = Some runner; _ }
         | Micro_vm { pipeline_runner = Some runner; _ }
         | Ssh { pipeline_runner = Some runner; _ }
           when simple.redirects = [] && same_sandbox_target ->
             let argv, env, cwd = process_spec_of_simple simple in
             let stage : Sandbox_target.pipeline_stage = { argv; env; cwd } in
             let pipeline_runner = Option.value pipeline_runner ~default:runner in
             let sandbox_target =
               Option.value sandbox_target ~default:simple.sandbox
             in
             loop (Some pipeline_runner) (Some sandbox_target) (stage :: acc) rest
         | _ -> None)
        [@warning "-4"]
    (* A stage that is itself a pipeline or a sequence needs a subshell,
       which this dispatcher does not spawn. *)
    | (Shell_ir.Pipeline _ | Shell_ir.Sequence _) :: _ -> None
  in
  loop None None [] stages

(* TEL-OK: this lower-level Shell IR dispatcher is wrapped by Execute/keeper
   telemetry at the action boundary; it preserves output delivery but does not
   record action-level telemetry directly. *)
let rec dispatch_pipeline ?base_host_env ?timeout_sec ?stdin_content
    ?on_output_chunk stages =
  let on_output_chunk, emitted = tracked_output_callback on_output_chunk in
  let decomposed_stage_callback ~is_final (simple : Shell_ir.simple) on_output_chunk =
    match on_output_chunk with
    | None -> None
    | Some _ when simple.redirects <> [] -> None
    | Some on_chunk ->
        Some
          (function
          | `Stdout chunk ->
              if is_final then on_chunk (`Stdout chunk)
          | `Stderr chunk -> on_chunk (`Stderr chunk))
  in
  let result =
    match stages with
    | [] ->
        invalid_pipeline "empty pipeline not supported in native dispatch"
    | [ _ ] ->
        invalid_pipeline "single-stage pipeline not supported in native dispatch"
    | _ ->
        (match host_pipeline_specs ?base_host_env stages with
         | Some specs ->
             (match
                match on_output_chunk with
                | None ->
                    Process_eio.run_argv_pipeline_with_status_split
                      ?timeout_sec
                      specs
                | Some on_chunk ->
                    Process_eio.run_argv_pipeline_with_status_split
                      ?timeout_sec
                      ~on_stdout_chunk:(fun chunk -> on_chunk (`Stdout chunk))
                      ~on_stderr_chunk:(fun chunk -> on_chunk (`Stderr chunk))
                      specs
              with
              | Ok (status, stdout, stderr) -> { status; stdout; stderr }
              | Error message -> unsupported_redirect_result message)
         | None -> (
             match sandbox_pipeline_specs stages with
             | Some (runner, specs) ->
                 let on_stdout_chunk, on_stderr_chunk =
                   match on_output_chunk with
                   | None -> None, None
                   | Some on_chunk ->
                       ( Some (fun chunk -> on_chunk (`Stdout chunk))
                       , Some (fun chunk -> on_chunk (`Stderr chunk)) )
                 in
                 let status, stdout, stderr =
                   runner ~on_stdout_chunk ~on_stderr_chunk ~stages:specs
                 in
                 { status; stdout; stderr }
             | None ->
                 let rec chain ~prev_stdout ~status ~stderr = function
                   | [] -> { status; stdout = prev_stdout; stderr }
                   | Shell_ir.Simple s :: rest ->
                       let is_final = match rest with [] -> true | _ -> false in
                       let stage_on_output_chunk =
                         decomposed_stage_callback ~is_final s on_output_chunk
                       in
                       let stage_result =
                         dispatch_simple
                           ?base_host_env
                           ?timeout_sec
                           ?on_output_chunk:stage_on_output_chunk
                           ~stdin_content:prev_stdout
                           s
                       in
                       let stage_streamed =
                         Option.is_some stage_on_output_chunk
                       in
                       let status = pipeline_status status stage_result.status in
                       let stderr = stderr ^ stage_result.stderr in
                       if status_is_timeout stage_result.status
                       then (
                         (* OCaml binds [else] to the nearest [if]: without
                            the parentheses the [else] below attached to
                            [if not is_final], so a streamed final-stage
                            timeout re-emitted output that had already been
                            streamed live, and a non-streamed (redirected)
                            stage timeout emitted nothing. *)
                         let () =
                           if stage_streamed
                           then (
                             if not is_final
                             then
                               emit_stdout_if_captured
                                 on_output_chunk
                                 stage_result.stdout)
                           else
                             emit_pipeline_stage_result
                               ~emit_stdout:true
                               on_output_chunk
                               stage_result
                         in
                         { status; stdout = stage_result.stdout; stderr })
                       else (
                         let () =
                           if stage_streamed
                           then ()
                           else
                             emit_pipeline_stage_result
                               ~emit_stdout:is_final
                               on_output_chunk
                               stage_result
                         in
                         chain
                           ~prev_stdout:stage_result.stdout
                           ~status
                           ~stderr
                           rest)
                   | (Pipeline _ | Sequence _) :: _ ->
                       { status = Unix.WEXITED 1
                       ; stdout = ""
                       ; stderr =
                           stderr
                           ^ "a pipeline stage that is itself a pipeline or a \
                              sequence needs a subshell, which native dispatch \
                              does not spawn"
                       }
                 in
                 (match stages with
                  | [] | [ _ ] ->
                      invalid_pipeline "invalid pipeline arity in native dispatch"
                  | first :: rest -> (
                    match first with
                    | Shell_ir.Simple s ->
                        let first_on_output_chunk =
                          decomposed_stage_callback
                            ~is_final:false
                            s
                            on_output_chunk
                        in
                        let first_result =
                          dispatch_simple
                            ?base_host_env
                            ?timeout_sec
                            ?on_output_chunk:first_on_output_chunk
                            s
                        in
                        let first_streamed =
                          Option.is_some first_on_output_chunk
                        in
                        let status =
                          pipeline_status (Unix.WEXITED 0) first_result.status
                        in
                        if status_is_timeout first_result.status
                        then (
                          let () =
                            if first_streamed
                            then
                              emit_stdout_if_captured
                                on_output_chunk
                                first_result.stdout
                            else
                              emit_pipeline_stage_result
                                ~emit_stdout:true
                                on_output_chunk
                                first_result
                          in
                          { status
                          ; stdout = first_result.stdout
                          ; stderr = first_result.stderr
                          })
                        else (
                          let () =
                            if first_streamed
                            then ()
                            else
                              emit_pipeline_stage_result
                                on_output_chunk
                                first_result
                          in
                          chain
                            ~prev_stdout:first_result.stdout
                            ~status
                            ~stderr:first_result.stderr
                            rest)
                    | Pipeline _ | Sequence _ ->
                        invalid_pipeline
                          "a pipeline stage that is itself a pipeline or a \
                           sequence needs a subshell, which native dispatch \
                           does not spawn" ))))
  in
  emit_unseen_captured_output on_output_chunk emitted result

(* [a && b] runs b only when a exited zero, and [a || b] only when it did
   not, exactly as a shell reads them. Whatever ran last decides, so a run of
   connectors reads left to right without any precedence of its own. Output
   from every command that ran is concatenated in the order it ran. *)
and dispatch_sequence ?base_host_env ?timeout_sec ?on_output_chunk ~head ~tail () =
  let run ir = dispatch ?base_host_env ?timeout_sec ?on_output_chunk ir in
  let took_the_branch connector (status : Unix.process_status) =
    match connector, status with
    | Shell_ir.And_if, Unix.WEXITED 0 -> true
    | Shell_ir.And_if, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> false
    | Shell_ir.Or_if, Unix.WEXITED 0 -> false
    | Shell_ir.Or_if, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> true
    | Shell_ir.Seq, _ -> true
  in
  let rec step acc = function
    | [] -> acc
    | (connector, ir) :: rest ->
      if not (took_the_branch connector acc.status)
      then step acc rest
      else (
        let next = run ir in
        step
          { status = next.status
          ; stdout = acc.stdout ^ next.stdout
          ; stderr = acc.stderr ^ next.stderr
          }
          rest)
  in
  step (run head) tail

and dispatch ?base_host_env ?timeout_sec ?on_output_chunk (ir : Shell_ir.t) =
  match ir with
  | Shell_ir.Simple s ->
    dispatch_simple ?base_host_env ?timeout_sec ?on_output_chunk s
  | Pipeline stages ->
    dispatch_pipeline ?base_host_env ?timeout_sec ?on_output_chunk stages
  | Sequence { head; tail } ->
    dispatch_sequence ?base_host_env ?timeout_sec ?on_output_chunk ~head ~tail ()
