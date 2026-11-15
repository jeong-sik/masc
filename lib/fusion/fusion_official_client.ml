(* Execution path for fusion panelists on official-client runtimes. See the
   .mli for why this exists. *)

let runtime_execution ~runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> None
  | Some runtime -> Some runtime.Runtime_instance.execution
;;

let is_official_client ~runtime_id =
  match runtime_execution ~runtime_id with
  | None -> false
  | Some execution ->
    (match Runtime_execution.checkpoint_owner execution with
     | Runtime_execution.Official_client -> true
     | Runtime_execution.Masc_agent_core -> false)
;;

(* Attribution matters here: a panel outcome carries the failure back to the
   operator, and "provider error" without a runtime sends them to the wrong
   place. Every message names the runtime it came from. *)
let provider_error ~runtime_id detail : Fusion_types.panel_failure =
  Fusion_types.Provider_error (Printf.sprintf "%s: %s" runtime_id detail)
;;

(* Naming the absent handle is the point: the server publishes both together but
   other entry points publish them separately, so "the Eio runtime is not
   initialized" sends the reader to look at the wrong one. Split out as a pure
   function because Eio_context has no reset, so a test that drove the real
   globals could only reach these arms in one fragile order.

   Its raw detail is carried as [Setup_failure]; runtime attribution happens
   once when the panel result or diagnostic line is rendered. *)
(* TEL-OK: pure string selection, no effect; the failure it names is already
   observable through the panel outcome. *)
let missing_handle_detail ~env_present ~clock_present =
  match env_present, clock_present with
  | true, true -> None
  | false, false ->
    Some
      "official-client panelist requires Eio_context env and clock; neither is \
       published"
  | false, true ->
    Some
      "official-client panelist requires Eio_context env (process manager and \
       fs); it is not published"
  | true, false ->
    Some "official-client panelist requires Eio_context clock; it is not published"
;;

let eio_context () =
  let env = Eio_context.get_env_opt () in
  let clock = Eio_context.get_clock_opt () in
  match env, clock with
  | Some env, Some clock -> Ok (env, clock)
  | _ ->
    let detail =
      match
        missing_handle_detail
          ~env_present:(Option.is_some env)
          ~clock_present:(Option.is_some clock)
      with
      | Some detail -> detail
      (* Unreachable: the Some/Some pair is matched above. Kept as a total
         function rather than an assert so a future edit to either match cannot
         raise on a live panel. *)
      | None -> "official-client panelist could not resolve the Eio context"
    in
    Error detail
;;

(* [Runtime_execution.*] carries admission-time config; each adapter has its own
   config record. The conversions below mirror the keeper path exactly
   (keeper_claude_code_runtime.ml:224, keeper_antigravity_runtime.ml:241) so a
   panelist runs the same client the keeper would, minus the parts a panelist
   has no business using. *)

(* The preset's explicit declaration wins over the selected model default.
   Otherwise use that model's captured declaration, including absence and an
   explicit unbounded value. Native admission remains independently bounded.
   [override_s] has passed [Fusion_policy.valid_timeout_s] at config load. *)
let resolved_timeout_s ~turn_timeout_s ~override_s ~default_timeout_s =
  match override_s with
  | Some _ as declared -> declared
  | None ->
    Runtime_inference.turn_timeout_s_of_declared ~default:default_timeout_s turn_timeout_s
;;

let bounded_claude_probe_config ~fallback_timeout_s
  (config : Runtime_claude_code.config)
  =
  match config.timeout_s with
  | Some _ -> config
  | None -> { config with timeout_s = Some fallback_timeout_s }
;;

let claude_config ~base_dir ~turn_timeout_s ~system_prompt ~override_s ~output_schema
  (execution : Runtime_execution.claude_code)
  : Runtime_claude_code.config
  =
  { cli_path = execution.cli_path
  ; cwd = base_dir
  ; model = execution.model
  ; native = Runtime_native_tools.claude_code_default
  ; system_prompt
  ; admission_timeout_s = execution.timeout_s
  ; timeout_s =
      resolved_timeout_s ~turn_timeout_s ~override_s ~default_timeout_s:execution.timeout_s
  ; output_schema
  }
;;

let codex_config ~runtime ~system_prompt ~override_s ~output_schema
  (execution : Runtime_execution.codex_app_server)
  : Runtime_codex_app_server.config
  =
  { cli_path = execution.cli_path
  ; isolated_home = None
  ; model = execution.model
  ; context_window = Some (Runtime_instance.max_context_of_runtime runtime)
  ; native = Runtime_native_tools.codex_default
  ; developer_instructions = system_prompt
  ; admission_timeout_s = execution.timeout_s
  ; timeout_s =
      resolved_timeout_s ~turn_timeout_s:runtime.model.turn_timeout_s ~override_s
        ~default_timeout_s:execution.timeout_s
  ; output_schema
  }
;;

let antigravity_config ~base_dir ~turn_timeout_s ~override_s ~output_schema
  (execution : Runtime_execution.antigravity_cli)
  : Runtime_antigravity.config
  =
  { cli_path = execution.cli_path
  ; cwd = base_dir
  ; add_dirs = []
  ; model = execution.model
  ; agent = execution.agent
  ; effort = execution.effort
  ; (* A panelist answers a question in a private workspace. The managed read
       permission policy denies native commands and writes; Plan mode is an
       instruction posture and the official client's sandbox stays enabled. *)
    execution_mode = Runtime_antigravity.Plan
  ; sandbox = true
  ; disable_slash_commands = true
  ; admission_timeout_s = execution.timeout_s
  ; timeout_s =
      resolved_timeout_s ~turn_timeout_s ~override_s ~default_timeout_s:execution.timeout_s
  ; output_schema
  }
;;

let muse_config ~turn_timeout_s ~override_s (execution : Runtime_execution.muse_serve)
  : Runtime_muse_serve.config
  =
  { (Runtime_muse_serve.default_config ()) with
    cli_path = execution.cli_path
  ; model = Some execution.model
  ; (* Read posture uses the managed policy overlay and host write/shell
       suppression. A panelist receives no mutable operator workspace. *)
    native = Runtime_native_tools.muse_default
  ; admission_timeout_s = execution.timeout_s
  ; timeout_s =
      resolved_timeout_s ~turn_timeout_s ~override_s ~default_timeout_s:execution.timeout_s
  }
;;

(* Antigravity, Muse Code and Vibe have no system-prompt channel. A one-shot turn
   puts the instructions at the head of the input in the frame a keeper turn
   uses ({!Antigravity_input_frame}; the Muse Code keeper start uses the same
   labels). Without this the panel or judge system prompt — for a
   judge-of-judges first judge, its whole lens — never reaches the model. *)
let framed_prompt ~system_prompt ~prompt =
  match system_prompt with
  | None -> Ok prompt
  | Some instructions ->
    Result.bind (Antigravity_input_frame.system_instructions_label ()) (fun system_label ->
         Result.map
           (fun goal_label ->
              String.concat Antigravity_input_frame.section_separator
                [ system_label ^ instructions; goal_label ^ prompt ])
           (Antigravity_input_frame.current_goal_label ()))
;;

let claude_usage (usage : Runtime_claude_code.turn_usage) : Fusion_types.usage =
  { input_tokens = usage.input_tokens + usage.cache_creation_input_tokens + usage.cache_read_input_tokens;
    output_tokens = usage.output_tokens }

let codex_usage = function
  | Runtime_codex_app_server.Thread_count {thread_total; _} ->
    { Fusion_types.input_tokens = thread_total.input_tokens; output_tokens = thread_total.output_tokens }
  | Thread_count_replaced -> Fusion_types.zero_usage

let antigravity_usage (usage : Runtime_antigravity.usage) : Fusion_types.usage =
  { input_tokens = usage.input_tokens + usage.cache_read_tokens; output_tokens = usage.output_tokens }

let muse_usage (usage : Runtime_muse_msp.token_usage) : Fusion_types.usage =
  { input_tokens = usage.input_tokens; output_tokens = usage.output_tokens }

(* [total_tokens] is [input_tokens + output_tokens] in every retained export
   (m0, m10-m14), so [cached_input_tokens] is a part of [input_tokens] and is
   not added to it. *)
let vibe_usage (usage : Runtime_vibe_headless.usage) : Fusion_types.usage =
  { input_tokens = usage.input_tokens; output_tokens = usage.output_tokens }

let optional_usage convert = function
  | Some usage -> convert usage
  | None -> Fusion_types.zero_usage

type image_input = Runtime_official_client_tool.image_input =
  { media_type : string
  ; base64_data : string
  }
type response = { text : string; model : string; usage : Fusion_types.usage }
type failure =
  | Missing_reply
  | Setup_failure of string
  | Codex_failure of Runtime_codex_app_server.error
  | Claude_failure of Runtime_claude_code.error
  | Claude_admission_failure of Runtime_claude_code.error
  | Antigravity_failure of Runtime_antigravity.error
  | Muse_failure of Runtime_muse_serve.error
  | Vibe_failure of vibe_failure
and vibe_failure =
  | Vibe_run_failed of Runtime_vibe_cli.error
  | Vibe_not_answered of Runtime_vibe_answer.error

let failure_detail ~runtime_id = function
  | Missing_reply -> Printf.sprintf "%s: completed turn has no assistant reply" runtime_id
  | Setup_failure detail -> Printf.sprintf "%s: %s" runtime_id detail
  | Codex_failure error ->
    Printf.sprintf "%s: %s" runtime_id (Runtime_codex_app_server.error_to_string error)
  | Claude_failure error | Claude_admission_failure error ->
    Printf.sprintf "%s: %s" runtime_id (Runtime_claude_code.error_to_string error)
  | Antigravity_failure error ->
    Printf.sprintf "%s: %s" runtime_id (Runtime_antigravity.error_to_string error)
  | Muse_failure error ->
    Printf.sprintf "%s: %s" runtime_id (Runtime_muse_serve.error_to_string error)
  | Vibe_failure (Vibe_run_failed error) ->
    Printf.sprintf "%s: %s" runtime_id (Runtime_vibe_cli.error_to_string error)
  | Vibe_failure (Vibe_not_answered error) ->
    Printf.sprintf "%s: %s" runtime_id (Runtime_vibe_answer.error_to_string error)
;;

(* 어댑터마다 자기 [Timeout] 갈래를 갖는다. 그것을 문자열로 접으면 Fusion
   증거에서 "CLI 가 시간 안에 답을 못 냈다" 가 provider 실패와 구분되지 않는다 —
   HTTP 쪽 [Fusion_panel.attempt_of_result] 가 두 timeout 갈래를 [Timeout] 으로
   올리는 것과 같은 규칙을 여기에도 적용한다. *)
let panel_failure ~runtime_id = function
  | Missing_reply -> provider_error ~runtime_id "completed turn has no assistant reply"
  | Setup_failure detail -> provider_error ~runtime_id detail
  | Codex_failure (Runtime_codex_app_server.Timeout _) -> Fusion_types.Timeout
  | Codex_failure
      (( Runtime_codex_app_server.Invalid_config _
       | Runtime_codex_app_server.Spawn_failed _
       | Runtime_codex_app_server.Reasoning_effort_admission_failed _
       | Runtime_codex_app_server.Account_read_failed _
       | Runtime_codex_app_server.Turn_input_write_failed _
       | Runtime_codex_app_server.Protocol_error _
       | Runtime_codex_app_server.Rpc_error _
       | Runtime_codex_app_server.Subscription_required _
       | Runtime_codex_app_server.Unsupported_server_request _
       | Runtime_codex_app_server.Context_window_exceeded _
       | Runtime_codex_app_server.Turn_failed _
       | Runtime_codex_app_server.Stopped_by_host _
       | Runtime_codex_app_server.Turn_interrupted
       | Runtime_codex_app_server.Runtime_shutting_down
       | Runtime_codex_app_server.Process_exited _ ) as error) ->
    provider_error ~runtime_id (Runtime_codex_app_server.error_to_string error)
  | Claude_failure (Runtime_claude_code.Timeout _)
  | Claude_admission_failure (Runtime_claude_code.Timeout _) -> Fusion_types.Timeout
  | Claude_failure
      (( Runtime_claude_code.Invalid_config _
       | Runtime_claude_code.Spawn_failed _
       | Runtime_claude_code.Protocol_error _
       | Runtime_claude_code.Subscription_required _
       | Runtime_claude_code.Unsupported_control_request _
       | Runtime_claude_code.Turn_transport_interrupted _
       | Runtime_claude_code.Context_window_exceeded _
       | Runtime_claude_code.Turn_failed _
       | Runtime_claude_code.Turn_failed_with_observation _
       | Runtime_claude_code.Stopped_by_host _
       | Runtime_claude_code.Quota_blocked _
       | Runtime_claude_code.Process_exited _
       | Runtime_claude_code.Unhandled_exception _ ) as error)
  | Claude_admission_failure
      (( Runtime_claude_code.Invalid_config _
       | Runtime_claude_code.Spawn_failed _
       | Runtime_claude_code.Protocol_error _
       | Runtime_claude_code.Subscription_required _
       | Runtime_claude_code.Unsupported_control_request _
       | Runtime_claude_code.Turn_transport_interrupted _
       | Runtime_claude_code.Context_window_exceeded _
       | Runtime_claude_code.Turn_failed _
       | Runtime_claude_code.Turn_failed_with_observation _
       | Runtime_claude_code.Stopped_by_host _
       | Runtime_claude_code.Quota_blocked _
       | Runtime_claude_code.Process_exited _
       | Runtime_claude_code.Unhandled_exception _ ) as error) ->
    provider_error ~runtime_id (Runtime_claude_code.error_to_string error)
  | Antigravity_failure (Runtime_antigravity.Timeout _) -> Fusion_types.Timeout
  | Antigravity_failure
      (( Runtime_antigravity.Invalid_config _
       | Runtime_antigravity.Spawn_failed _
       | Runtime_antigravity.Protocol_error _
       | Runtime_antigravity.State_callback_failed _
       | Runtime_antigravity.Turn_failed _
       | Runtime_antigravity.Result_not_completed _
       | Runtime_antigravity.Actions_denied _
       | Runtime_antigravity.Process_exited _
       | Runtime_antigravity.Child_fd_ceiling_exceeded _
       | Runtime_antigravity.Unhandled_exception _ ) as error) ->
    provider_error ~runtime_id (Runtime_antigravity.error_to_string error)
  | Muse_failure (Runtime_muse_serve.Timeout _) -> Fusion_types.Timeout
  | Muse_failure
      (( Runtime_muse_serve.Invalid_config _
       | Runtime_muse_serve.Spawn_failed _
       | Runtime_muse_serve.Turn_input_write_failed _
       | Runtime_muse_serve.Protocol_error _
       | Runtime_muse_serve.Rpc_error _
       | Runtime_muse_serve.Capability_not_granted _
       | Runtime_muse_serve.Session_not_durable
       | Runtime_muse_serve.Session_model_mismatch _
       | Runtime_muse_serve.Session_workspace_mismatch _
       | Runtime_muse_serve.Session_approval_mode_mismatch _
       | Runtime_muse_serve.Auth_required _
       | Runtime_muse_serve.Turn_failed _
       | Runtime_muse_serve.Turn_cancelled
       | Runtime_muse_serve.Unsupported_server_request _
       | Runtime_muse_serve.Runtime_shutting_down
       | Runtime_muse_serve.Process_exited _ ) as error) ->
    provider_error ~runtime_id (Runtime_muse_serve.error_to_string error)
  (* MASC sets no Vibe deadline, so [after_s = Some _] does not occur today;
     [None] is an exit 124 Vibe chose itself. [deadline] is Vibe's own limit,
     which can come only from the user's Vibe config. *)
  | Vibe_failure (Vibe_run_failed (Runtime_vibe_cli.Timed_out { after_s = Some _; _ }))
  | Vibe_failure
      (Vibe_not_answered
         (Runtime_vibe_answer.Not_finished { stop = Runtime_vibe_answer.Deadline; _ })) ->
    Fusion_types.Timeout
  | Vibe_failure
      (Vibe_run_failed
         (( Runtime_vibe_cli.Invalid_config _
          | Runtime_vibe_cli.Native_tools_refused _
          | Runtime_vibe_cli.Process_runtime_unavailable
          | Runtime_vibe_cli.Call_dir_failed _
          | Runtime_vibe_cli.Spawn_refused _
          | Runtime_vibe_cli.Timed_out { after_s = None; _ }
          | Runtime_vibe_cli.Signaled _
          | Runtime_vibe_cli.Stopped _
          | Runtime_vibe_cli.No_export _
          | Runtime_vibe_cli.Export_unreadable _
          | Runtime_vibe_cli.Transcript_unreadable _
          | Runtime_vibe_cli.Exit_code_mismatch _
          | Runtime_vibe_cli.Outcome_exit_mismatch _ ) as error)) ->
    provider_error ~runtime_id (Runtime_vibe_cli.error_to_string error)
  | Vibe_failure
      (Vibe_not_answered
         (( Runtime_vibe_answer.Not_finished
              { stop =
                  ( Runtime_vibe_answer.Usage_error
                  | Runtime_vibe_answer.Config_error
                  | Runtime_vibe_answer.Infrastructure_failure
                  | Runtime_vibe_answer.Turn_limit
                  | Runtime_vibe_answer.Token_limit
                  | Runtime_vibe_answer.Price_limit
                  | Runtime_vibe_answer.Terminated
                  | Runtime_vibe_answer.Length
                  | Runtime_vibe_answer.Refusal
                  | Runtime_vibe_answer.Aborted
                  | Runtime_vibe_answer.Unrecognized_outcome _ )
              ; _
              }
          | Runtime_vibe_answer.No_output
          | Runtime_vibe_answer.No_assistant_reply
          | Runtime_vibe_answer.Unrecognized_last_role _
          | Runtime_vibe_answer.Unrecognized_last_entry _
          | Runtime_vibe_answer.Unrecognized_reply_part _ ) as error)) ->
    provider_error ~runtime_id (Runtime_vibe_answer.error_to_string error)


(* A Muse Code panelist starts in an empty temporary directory rather than
   the operator's runtime state directory. This selects its working directory;
   it does not confine native reads. The managed Muse policy is enforced by
   Runtime_muse_serve independently of this coordinate. *)
let create_muse_panel_root () =
  match Filename.temp_dir ~perms:0o700 "masc-muse-panelist-" "" |> Unix.realpath with
  | root -> Ok root
  | exception (Sys_error detail) ->
    Error (Setup_failure ("cannot create the Muse Code panelist workspace: " ^ detail))
  | exception Unix.Unix_error (error, _, path) ->
    Error
      (Setup_failure
         (Printf.sprintf
            "cannot resolve the Muse Code panelist workspace %s: %s"
            path
            (Unix.error_message error)))
;;

let remove_muse_panel_root root =
  try Fs_compat.remove_tree root with
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    Log.Runtime_agent.warn
      "Muse Code panelist left its workspace %s behind: %s"
      root
      (Printexc.to_string exn)
;;

(* A Vibe panelist starts in an empty private directory, passed as its
   [--workdir] without [--trust], so the [ask] agent finds no operator files
   and Vibe loads no project [.vibe] from it. The path is kept as
   [Filename.temp_dir] gives it: without [--trust] nothing compares it with
   a resolved form, and resolving it after creation could fail with the
   directory already made and no cleanup registered yet. *)
let create_vibe_panel_root () =
  match Filename.temp_dir ~perms:0o700 "masc-vibe-panelist-" "" with
  | root -> Ok root
  | exception Sys_error detail ->
    Error (Setup_failure ("cannot create the Mistral Vibe panelist workdir: " ^ detail))
;;

let remove_vibe_panel_root root =
  try Fs_compat.remove_tree root with
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    Log.Runtime_agent.warn
      "Mistral Vibe panelist left its workdir %s behind: %s"
      root
      (Printexc.to_string exn)
;;

(* An Antigravity one-shot call runs in a HOME of its own that is removed with
   the call. A HOME kept per account also kept the project each call creates
   ([--new-project]), and agy opens every project file when it starts: 23,987
   files after nine days, tens of thousands of descriptors in one process
   (#43256). The usage read and the context observation already work this way:
   the account's OAuth file seeds a disposable HOME. A token the call refreshes
   is not kept, so each call refreshes from the seed. *)
let antigravity_panel_root_prefix = "masc-antigravity-panelist-"

let is_decimal_digits s =
  s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s
;;

(* Parse the decimal creator PID from [masc-antigravity-panelist-<pid>-<nonce>].
   [int_of_string_opt] alone accepts OCaml literals such as [0x10], [+123], and
   [1_000], so require plain decimal digits before parsing. Unattributed legacy
   names without a [<pid>-] segment return [None] and are left alone. *)
let antigravity_panel_root_owner_pid name =
  let prefix_len = String.length antigravity_panel_root_prefix in
  if not (String.starts_with ~prefix:antigravity_panel_root_prefix name)
  then None
  else (
    let rest = String.sub name prefix_len (String.length name - prefix_len) in
    match String.index_opt rest '-' with
    | None -> None
    | Some dash ->
      let pid_str = String.sub rest 0 dash in
      let suffix_len = String.length rest - dash - 1 in
      if suffix_len <= 0 || not (is_decimal_digits pid_str)
      then None
      else (
        match int_of_string_opt pid_str with
        | Some pid when pid > 0 -> Some pid
        | None | Some _ -> None))
;;

(* [Unix.kill pid 0] probes existence without signalling. [EPERM] means the
   process exists under another user, and any non-[ESRCH] error fails closed by
   treating the process as live so a sibling process's disposable HOME is never
   removed while in use. *)
let pid_is_live pid =
  if pid <= 0
  then false
  else (
    match Unix.kill pid 0 with
    | () -> true
    | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
    | exception (Unix.Unix_error _ | Invalid_argument _) -> true)
;;

let sweep_stale_antigravity_panel_roots ?temp_dir () =
  let raw_dir =
    match temp_dir with
    | Some dir -> dir
    | None -> Filename.get_temp_dir_name ()
  in
  let dir = try Unix.realpath raw_dir with Unix.Unix_error _ -> raw_dir in
  match Sys.readdir dir with
  | exception Sys_error msg ->
    Log.Runtime_agent.warn
      "cannot scan %s for stale Antigravity panelist HOMEs: %s"
      dir
      msg
  | entries ->
    (* DET-OK: safety predicate on this process's own identity. *)
    let self = Unix.getpid () in
    let euid = Unix.geteuid () in
    Array.sort String.compare entries;
    Array.iter
      (fun name ->
         match antigravity_panel_root_owner_pid name with
         | None -> ()
         | Some pid when pid = self || pid_is_live pid -> ()
         | Some pid ->
           let path = Filename.concat dir name in
           (match Unix.lstat path with
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
            | exception Unix.Unix_error (error, _, _) ->
              Log.Runtime_agent.warn
                "cannot inspect stale Antigravity panelist HOME %s (pid %d): %s"
                path
                pid
                (Unix.error_message error)
            | stat
              when stat.Unix.st_kind = Unix.S_DIR
                   && stat.Unix.st_uid = euid
                   && stat.Unix.st_perm land 0o7777 = 0o700
                   && Antigravity_panel_root_owner.can_remove ~root:path ->
              Runtime_antigravity_home.forget_prepared_below ~runtime_root:path;
              (* try/with, not a match with an `exception` case: the handler
                 binds the exception, and an `as` binding under an exception
                 pattern is rejected by the compiler. *)
              (try
                 Fs_compat.remove_tree path;
                 Log.Runtime_agent.info
                   "removed stale Antigravity panelist HOME %s (creator %d and recorded users absent)"
                   path
                   pid
               with
               | (Sys_error _ | Unix.Unix_error _) as exn ->
                 if Sys.file_exists path
                 then
                   Log.Runtime_agent.warn
                     "cannot remove stale Antigravity panelist HOME %s (pid %d): %s"
                     path
                     pid
                     (Printexc.to_string exn))
            | _ -> ()))
      entries
;;

(* DET-OK: process identity tags the disposable root so the next startup can
   distinguish a dead creator from a live sibling process without an age
   cutoff (#43405). *)
let antigravity_panel_root_pid_prefix () =
  Printf.sprintf "%s%d-" antigravity_panel_root_prefix (Unix.getpid ())
;;

let create_antigravity_panel_root () =
  sweep_stale_antigravity_panel_roots ();
  match
    Filename.temp_dir ~perms:0o700 (antigravity_panel_root_pid_prefix ()) ""
    |> Unix.realpath
  with
  | root ->
    Antigravity_panel_root_owner.initialize ~root
    |> Result.map (fun () -> root)
    |> Result.map_error (fun detail -> Setup_failure
         ("cannot record Antigravity panelist HOME ownership: " ^ detail))
  | exception Sys_error detail ->
    Error (Setup_failure ("cannot create the Antigravity panelist HOME: " ^ detail))
  | exception Unix.Unix_error (error, _, path) ->
    Error
      (Setup_failure
         (Printf.sprintf
            "cannot resolve the Antigravity panelist HOME %s: %s"
            path
            (Unix.error_message error)))
;;

(* The root holds a copy of the account's OAuth file, so a removal that fails
   is said out loud. *)
let remove_antigravity_panel_root root =
  if not (Antigravity_panel_root_owner.can_remove ~root) then
    Log.Runtime_agent.warn
      "Antigravity panelist retained HOME %s: process-group ownership is live or unconfirmed" root
  else (
  Runtime_antigravity_home.forget_prepared_below ~runtime_root:root;
  try Fs_compat.remove_tree root with
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    Log.Runtime_agent.warn
      "Antigravity panelist left its disposable HOME %s behind: %s"
      root
      (Printexc.to_string exn))
;;

(* A host client starts on an account of the host, whoever asks for the
   panelist: only a single-user process shares it (plan D3b). *)
let authorize_host client =
  Runtime_account_access.authorize_host client
  |> Result.map_error (fun refusal ->
    Setup_failure (Runtime_account_access.refusal_to_string refusal))
;;

let prepare_antigravity_panel_home ~host ~runtime_root ~oauth_source =
  let open Result.Syntax in
  let* home, cwd = Runtime_antigravity_home.prepare_native
      ~host ~runtime_root ~owner_leaf:"panelist" ~oauth_source
      ~posture:Runtime_native_tools.Native_read
      ~workspace:Runtime_antigravity_home.Private_workspace
      ~additional_workspaces:[]
    |> Result.map_error (fun error -> Setup_failure
         (Runtime_antigravity_home.error_to_string error)) in
  let* () = Eio_guard.run_in_systhread ~label:"fusion-antigravity-mcp-cleanup" (fun () ->
    Runtime_antigravity_home.clear_mcp_config home)
    |> Result.map_error (fun error -> Setup_failure
         (Runtime_antigravity_home.error_to_string error)) in
  Ok (home, cwd)
;;

(* A spent window is the account's, until the reset it states. A throttle
   belongs to the dispatched candidate only, and states no wait, the same
   observation a Codex rate refusal makes. *)
let claude_quota_standing : Runtime_claude_code.quota_block -> Runtime_candidate_standing.observation
  = function
  | Runtime_claude_code.Quota_spent { resets_at; windows = _ } ->
    Runtime_candidate_standing.Hard_quota
      { source = Runtime_quota_window.Provider_quota_refused
      ; resets_at = Option.map float_of_int resets_at
      }
  | Runtime_claude_code.Rate_throttled ->
    Runtime_candidate_standing.Rate_limited { retry_after = None }
;;

let run_with_images ?(on_usage = fun _ -> ()) ~images ~base_dir ~(runtime : Runtime_instance.t) ~system_prompt ?timeout_s ?output_schema ~prompt () =
  let open Result.Syntax in
  (* The Codex and Claude adapters take the system prompt as an option and
     treat [None] as "client default"; Antigravity, Muse Code and Vibe get it
     framed into the input. An empty group prompt is not an instruction, so it becomes [None]
     rather than an empty instruction the client must obey. *)
  let system_prompt =
    match String.trim system_prompt with "" -> None | text -> Some text
  in
  (* Capture ownership with the execution before any subprocess yields. A
     runtime catalog reload may change the credential alias under this id. *)
  let execution = runtime.Runtime_instance.execution in
  let quota_scope = Runtime_instance.quota_scope_of_runtime runtime in
  let observe observation =
    Runtime_candidate_standing.observe
      ~candidate:(Some runtime.candidate_backpressure)
      ~quota_scope:(Some quota_scope) observation
  in
  let succeeded (text : response) =
    observe Runtime_candidate_standing.Answered;
    on_usage text.usage;
    Ok text
  in
  let claude_failed ~admission error =
    (match error with
     | Runtime_claude_code.Quota_blocked { block; _ } ->
       observe (claude_quota_standing block)
     | Runtime_claude_code.Invalid_config _ | Runtime_claude_code.Spawn_failed _
     | Runtime_claude_code.Protocol_error _ | Runtime_claude_code.Subscription_required _
     | Runtime_claude_code.Unsupported_control_request _
     | Runtime_claude_code.Turn_transport_interrupted _
     | Runtime_claude_code.Context_window_exceeded _ | Runtime_claude_code.Turn_failed _
     | Runtime_claude_code.Turn_failed_with_observation _ | Runtime_claude_code.Stopped_by_host _
     | Runtime_claude_code.Process_exited _ | Runtime_claude_code.Unhandled_exception _
     | Runtime_claude_code.Timeout _ -> ());
    Error (if admission then Claude_admission_failure error else Claude_failure error)
  in
  (* Spent usage belongs to the account scope. A typed rate refusal belongs
     only to the dispatched candidate; overload and transport failures do not
     create or replace a Fleet-owned failed-attempt observation. *)
  let codex_failed error =
    if Runtime_codex_app_server.refused_for_spent_usage error
    then observe (Runtime_candidate_standing.Hard_quota
      {source=Runtime_quota_window.Provider_quota_refused; resets_at=None})
    else (
      match error with
      | Runtime_codex_app_server.Turn_failed
          {codex_error_info=Some Runtime_codex_app_server.Codex_error_info.Rate_limit_exceeded; _} ->
        observe (Runtime_candidate_standing.Rate_limited {retry_after=None})
      | Runtime_codex_app_server.Turn_failed {codex_error_info=None; _}
      | Runtime_codex_app_server.Turn_failed
          {codex_error_info=Some
            (Runtime_codex_app_server.Codex_error_info.Usage_limit_exceeded
            | Session_budget_exceeded | Cyber_policy | Misalignment_policy_violation
            | Internal_server_error | Unauthorized | Bad_request | Thread_rollback_failed
            | Sandbox_error | Server_overloaded | Other | Http_connection_failed _
            | Response_stream_connection_failed _ | Response_stream_disconnected _
            | Response_too_many_failed_attempts _ | Active_turn_not_steerable _
            | Unrecognized _); _}
      | Runtime_codex_app_server.Invalid_config _ | Spawn_failed _
      | Reasoning_effort_admission_failed _ | Account_read_failed _
      | Turn_input_write_failed _
      | Protocol_error _ | Rpc_error _ | Subscription_required _
      | Unsupported_server_request _ | Context_window_exceeded _ | Stopped_by_host _
      | Turn_interrupted | Runtime_shutting_down | Process_exited _ | Timeout _ -> ());
    Error (Codex_failure error)
  in
  let* env, clock = eio_context ()
    |> Result.map_error (fun detail -> Setup_failure detail) in
  let mgr = (Posix_spawn_process_mgr.foreground_mgr ~clock
      ~grace_seconds:Process_eio.child_exit_grace_seconds) in
  let cwd = Eio.Path.(Eio.Stdenv.fs env / base_dir) in
  match execution with
  | Runtime_execution.Agent_core _ ->
    (* Callers route Agent_core panelists through Fusion_agent_core. Reaching
       here means the split in Fusion_panel disagreed with [is_official_client],
       which is a bug in this module's callers rather than a provider failure. *)
    Error (Setup_failure
      "runtime is Agent_core-owned; it belongs on the Async_agent path")
  (* A Vibe headless call takes one prompt file: no schema, no image, and no
     MASC deadline. The owner left Vibe calls without a time limit, so a
     declared one is refused here rather than dropped. *)
  | Runtime_execution.Vibe_cli _ when Option.is_some output_schema ->
    Error
      (Setup_failure
         "Mistral Vibe's headless call has no output-schema channel, so a \
          schema-held answer cannot be asked of it")
  | Runtime_execution.Vibe_cli _ when not (List.is_empty images) ->
    Error (Setup_failure "Mistral Vibe's headless call takes text only, so it cannot carry an image")
  | Runtime_execution.Vibe_cli _ when Option.is_some timeout_s ->
    Error
      (Setup_failure
         "a Mistral Vibe call has no MASC time limit, so a declared timeout_s \
          cannot be held")
  | Runtime_execution.Vibe_cli execution ->
    (* HIGH-RISK-UNREVIEWED: a panelist starts Vibe on the configuration of the
       host user, which a multi-account process shares with no person (plan
       D3b). A refusal starts no process. *)
    let* host = authorize_host Runtime_account_access.Vibe in
    let* prompt =
      framed_prompt ~system_prompt ~prompt
      |> Result.map_error (fun detail -> Setup_failure detail)
    in
    Eio.Switch.run
    @@ fun sw ->
    (* Enter the cancellation scope before acquiring the directory, then
       register its cleanup before cancellation can discard the acquisition. *)
    let* workdir = Eio.Cancel.protect (fun () ->
      let* root = create_vibe_panel_root () in
      Eio.Switch.on_release sw (fun () -> remove_vibe_panel_root root);
      Ok root) in
    let config : Runtime_vibe_cli.config =
      { cli_path = execution.cli_path
      ; workdir
      ; trust_workdir = false
      ; model = Some execution.model
      ; time_limit_s = None
      }
    in
    (match Runtime_vibe_cli.run ~host config ~prompt with
     | Error error ->
       Option.iter
         (fun usage -> on_usage (vibe_usage usage))
         (Runtime_vibe_cli.reported_usage error);
       Error (Vibe_failure (Vibe_run_failed error))
     | Ok run ->
       let usage = optional_usage vibe_usage run.export.usage in
       (* [export.json] names no model, so the panel records the [--model]
          MASC passed: the one Vibe did not contradict, not one it confirmed. *)
       (match Runtime_vibe_answer.of_run run with
        | Ok text -> succeeded { text; model = execution.model; usage }
        | Error error ->
          on_usage usage;
          Error (Vibe_failure (Vibe_not_answered error))))
  | Runtime_execution.Claude_code execution ->
    (* HIGH-RISK-UNREVIEWED: a panelist is a call of the operator, not a
       Keeper turn, so its CLI starts only where the access allows one (plan
       D2-5). A refusal starts no process and observes nothing of the
       candidate. *)
    (match
       Runtime_account_access.authorize Runtime_account_access.Operator_call
         execution.account_home
     with
     | Error refusal -> Error (Setup_failure (Runtime_account_access.refusal_to_string refusal))
     | Ok account ->
    let config =
      claude_config ~base_dir ~turn_timeout_s:runtime.model.turn_timeout_s
        ~system_prompt ~override_s:timeout_s
        ~output_schema execution
    in
    let probe_config =
      bounded_claude_probe_config
        ~fallback_timeout_s:execution.timeout_s
        config
    in
    (match
       Runtime_claude_code.probe_subscription
         ~mgr
         ~clock
         ~cwd
         ~account
         probe_config
     with
     | Error error -> claude_failed ~admission:true error
     | Ok admitted_subscription ->
       (match
          Runtime_claude_code.run_turn
            ?reasoning_effort:(Option.map Runtime_claude_code.cli_admitted_reasoning_effort
              runtime.model.reasoning_effort)
            ~on_stream_event:(function
              | Runtime_claude_code.Usage_reported {usage; _} -> on_usage (claude_usage usage)
              | Runtime_claude_code.Conversation_compacted | Runtime_claude_code.Turn_started _
              | Runtime_claude_code.Text_delta _ | Runtime_claude_code.Thinking_delta _
              | Runtime_claude_code.Child_content_observed _
              | Runtime_claude_code.Content_block_stopped _
              | Runtime_claude_code.Dynamic_tool_started _
              | Runtime_claude_code.Dynamic_tool_finished _
              | Runtime_claude_code.Native_tool_started _
              | Runtime_claude_code.Native_tool_finished _
              | Runtime_claude_code.Native_tool_progress _
              | Runtime_claude_code.Native_task_observed _
              | Runtime_claude_code.Usage_windows_reported _
              | Runtime_claude_code.Provider_retry_observed _ | Runtime_claude_code.Turn_finished _ -> ())
            ~admitted_subscription
            ~mgr
            ~clock
            ~cwd
            ~account
            config
            ~prompt
            ~images
        with
        | Ok (result : Runtime_claude_code.turn_result) -> succeeded { text = result.text; model = result.model; usage = optional_usage claude_usage result.usage.turn_total }
        | Error error -> claude_failed ~admission:false error)))
  | Runtime_execution.Codex_app_server execution ->
    (* HIGH-RISK-UNREVIEWED: a panelist is a call of the operator, so its
       app-server starts only where the access allows one (plan D2-6). A
       refusal starts no process and observes nothing of the candidate. *)
    (match
       Runtime_account_access.authorize Runtime_account_access.Operator_call
         execution.account_home
     with
     | Error refusal -> Error (Setup_failure (Runtime_account_access.refusal_to_string refusal))
     | Ok account ->
    let config =
      codex_config ~runtime ~system_prompt ~override_s:timeout_s ~output_schema execution
    in
    (* Fresh-thread totals are snapshots. A window fill replaces the vendor
       counter, so retain the last observed spend and ignore later reset totals. *)
    let observed_usage = ref Fusion_types.zero_usage in
    let counter_replaced = ref false in
    (match Runtime_codex_app_server.run_turn
       ~thread:Runtime_codex_app_server.Ephemeral
       ?reasoning_effort:runtime.model.reasoning_effort
       ~on_stream_event:(function
         | Runtime_codex_app_server.Usage_reported {frame=Counted {thread_total; _}; _}
           when not !counter_replaced ->
           observed_usage := { Fusion_types.input_tokens=thread_total.input_tokens;
                               output_tokens=thread_total.output_tokens };
           on_usage !observed_usage
         | Usage_reported {frame=Context_window_filled _; _} -> counter_replaced := true
         | Runtime_codex_app_server.Compaction_observed | Runtime_codex_app_server.Turn_started _
         | Runtime_codex_app_server.Text_delta _ | Runtime_codex_app_server.Thinking_delta _
         | Runtime_codex_app_server.Text_completed _ | Runtime_codex_app_server.Thinking_completed _
         | Runtime_codex_app_server.Dynamic_tool_started _
         | Runtime_codex_app_server.Dynamic_tool_finished _
         | Runtime_codex_app_server.Tool_delivery_closed _
         | Runtime_codex_app_server.Native_tool_started _
         | Runtime_codex_app_server.Native_tool_finished _
         | Runtime_codex_app_server.Native_tool_progress _
         | Runtime_codex_app_server.Elicitation_cancelled _
         | Runtime_codex_app_server.Usage_windows_reported _
         | Runtime_codex_app_server.Turn_finished _ | Usage_reported {frame=Counted _; _ } -> ())
       ~mgr ~clock ~cwd ~account config ~prompt ~images with
     | Ok (result : Runtime_codex_app_server.turn_result) -> succeeded { text = result.text; model = result.model; usage = (match result.usage with
         | Some Runtime_codex_app_server.Thread_count_replaced -> !observed_usage
         | (Some (Runtime_codex_app_server.Thread_count _) | None) as usage -> optional_usage codex_usage usage) }
     | Error error -> codex_failed error))
  | Runtime_execution.Antigravity_cli _ when not (List.is_empty images) ->
    Error (Setup_failure "Antigravity transport does not support image input")
  | Runtime_execution.Antigravity_cli execution ->
    (* HIGH-RISK-UNREVIEWED: a panelist starts the client on a credential of
       the host, which a multi-account process shares with no person (plan
       D3b). A refusal starts no process. *)
    let* host = authorize_host Runtime_account_access.Antigravity in
    let config =
      antigravity_config ~base_dir ~turn_timeout_s:runtime.model.turn_timeout_s
        ~override_s:timeout_s ~output_schema execution
    in
    let* prompt =
      framed_prompt ~system_prompt ~prompt
      |> Result.map_error (fun detail -> Setup_failure detail)
    in
    Eio.Switch.run
    @@ fun sw ->
    (* Enter the cancellation scope before acquiring the directory, then
       register its cleanup before cancellation can discard the acquisition. *)
    let* panel_root = Eio.Cancel.protect (fun () ->
      let* root = create_antigravity_panel_root () in
      Eio.Switch.on_release sw (fun () -> remove_antigravity_panel_root root);
      Ok root) in
    (* Wait for the preparation to finish before cancellation can run the
       registered cleanup; the worker must not outlive the tree it fills. *)
    let* home, native_cwd = Eio.Cancel.protect (fun () ->
      prepare_antigravity_panel_home
        ~host ~runtime_root:panel_root ~oauth_source:execution.oauth_source) in
    let config = { config with Runtime_antigravity.cwd = native_cwd } in
    (match Runtime_antigravity.run_turn
       ~host
       ~before_spawn:(fun () ->
         match Antigravity_panel_root_owner.before_spawn ~root:panel_root with
         | Ok () -> ()
         | Error detail -> raise (Sys_error detail))
       ~on_spawned:(fun ~pid ->
         match Antigravity_panel_root_owner.spawned ~root:panel_root ~pid with
         | Ok () -> ()
         | Error detail -> raise (Sys_error detail))
       ~on_stream_event:(function
         | Runtime_antigravity.Usage_reported {usage; _} -> on_usage (antigravity_usage usage)
         | Runtime_antigravity.Turn_started _ | Runtime_antigravity.Text_delta _
         | Runtime_antigravity.Text_completed _ | Runtime_antigravity.Native_tool_started _
         | Runtime_antigravity.Native_tool_finished _ | Runtime_antigravity.Turn_finished _ -> ())
       ~home_dir:(Runtime_antigravity_home.home_dir home)
       ~mgr ~clock ~cwd:Eio.Path.(Eio.Stdenv.fs env / native_cwd) config ~prompt with
     | Ok (result : Runtime_antigravity.turn_result) -> succeeded { text = result.text; model = result.model; usage = antigravity_usage result.usage }
     | Error error ->
       Error (Antigravity_failure error))
  (* MSP's [turn/start] has no output-schema field, so a caller that needs
     the client to hold its answer to a schema is refused before a process
     starts instead of receiving an answer nothing held. *)
  | Runtime_execution.Muse_serve _ when Option.is_some output_schema ->
    Error
      (Setup_failure
         "Muse Code's session protocol has no output-schema channel, so a \
          schema-held answer cannot be asked of it")
  | Runtime_execution.Muse_serve execution ->
    (* HIGH-RISK-UNREVIEWED: a panelist is a call of the operator, so Muse
       starts only where the access allows one (plan D3). A refusal starts no
       process. *)
    (match
       Runtime_account_access.authorize_muse Runtime_account_access.Operator_call
         (Runtime_account_access.Declared_home execution.account_home)
     with
     | Error refusal -> Error (Setup_failure (Runtime_account_access.refusal_to_string refusal))
     | Ok account ->
    let config = muse_config ~turn_timeout_s:runtime.model.turn_timeout_s ~override_s:timeout_s execution in
    let* prompt =
      framed_prompt ~system_prompt ~prompt
      |> Result.map_error (fun detail -> Setup_failure detail)
    in
    Eio.Switch.run
    @@ fun sw ->
    (* Enter the cancellation scope before acquiring the directory, then
       register its cleanup before cancellation can discard the acquisition. *)
    let* panel_root = Eio.Cancel.protect (fun () ->
      let* root = create_muse_panel_root () in
      Eio.Switch.on_release sw (fun () -> remove_muse_panel_root root);
      Ok root) in
    let* workspace_root, storage_root =
      (* Wait for filesystem preparation before cancellation can run the
         already registered cleanup; the worker must not outlive that tree. *)
      Eio.Cancel.protect (fun () ->
        Eio_guard.run_in_systhread ~label:"muse fusion native storage" (fun () ->
          try
            let workspace_root = Filename.concat panel_root "workspace" in
            let storage_root = Filename.concat panel_root "native" in
            Unix.mkdir workspace_root 0o700;
            Runtime_muse_serve.ensure_storage_dirs storage_root;
            Ok (workspace_root, storage_root)
          with Unix.Unix_error (error, _, _) ->
            Error (Setup_failure ("cannot prepare Muse Code stateless storage: " ^ Unix.error_message error))))
    in
    (match
       Runtime_muse_serve.run_turn
         ~storage:(Runtime_muse_serve.Stateless storage_root)
         ?reasoning_effort:(Option.map Runtime_muse_msp.reasoning_effort_of_requested
           runtime.model.reasoning_effort)
         ~on_stream_event:(function
           | Runtime_muse_serve.Usage_reported {usage; _} -> on_usage (muse_usage usage)
           | Runtime_muse_serve.Subscription_usage_observed usage ->
             Runtime_muse_usage.observe ~scope:quota_scope Runtime_muse_usage.Usage_changed usage
           | Runtime_muse_serve.Turn_terminal_received terminal ->
             Runtime_muse_usage.observe_terminal ~scope:quota_scope terminal
           | Runtime_muse_serve.Turn_started _ | Runtime_muse_serve.Text_delta _
           | Runtime_muse_serve.Text_completed _ | Runtime_muse_serve.Native_tool_started _
           | Runtime_muse_serve.Native_tool_finished _ | Runtime_muse_serve.Approval_decided _
           | Runtime_muse_serve.Compaction_observed _ | Runtime_muse_serve.View_gap_observed
           | Runtime_muse_serve.Turn_items_read _ | Runtime_muse_serve.Model_call_reported _
           | Runtime_muse_serve.Turn_finished _ -> ())
         ~mgr
         ~clock
         ~cwd:Eio.Path.(Eio.Stdenv.fs env / workspace_root)
         ~account
         config
         ~workspace_root
         ~prompt
         ~images
     with
     | Ok (result : Runtime_muse_serve.turn_result) ->
       (* The panel records the model the turn's last call ran on, as the
          host named it. With no call reported it records the session's model:
          the session starts with [modelId] set to the configured model, and
          the serve client refuses a start the host names another model for.
          A host that names neither left the model its record omits, so the
          panel records the model MASC asked for: the one the host did not
          contradict, not one it confirmed. *)
       let model =
         match Runtime_muse_serve.reported_model result with
         | Some reported -> reported
         | None -> execution.model
       in
       (match result.text with
        | Some text -> succeeded { text; model; usage = optional_usage muse_usage result.usage }
        | None -> Error Missing_reply)
     | Error error -> Error (Muse_failure error)))
;;

let run_panelist ~base_dir ~runtime_id ~system_prompt ?timeout_s ?output_schema ~prompt () =
  let open Result.Syntax in
  let* runtime = match Runtime.get_runtime_by_id runtime_id with
    | Some runtime -> Ok runtime
    | None -> Error (provider_error ~runtime_id "runtime is not configured", Fusion_types.zero_usage) in
  let usage = ref Fusion_types.zero_usage in
  run_with_images ~on_usage:(fun observed -> usage := observed) ~images:[] ~base_dir ~runtime ~system_prompt ?timeout_s
    ?output_schema ~prompt ()
  |> Result.map (fun (response : response) -> response.text, response.usage)
  |> Result.map_error (fun failure -> panel_failure ~runtime_id failure, !usage)
;;

module For_testing = struct
  (* Re-exported so a test can reach every arm without driving the
     process-global Eio context, which has no reset. *)
  (* TEL-OK: alias of a pure function; no behaviour of its own. *)
  let missing_handle_detail = missing_handle_detail
  let resolved_timeout_s = resolved_timeout_s
  let bounded_claude_probe_config = bounded_claude_probe_config
  let claude_usage = claude_usage
  let codex_usage = codex_usage
  let antigravity_panel_root_owner_pid = antigravity_panel_root_owner_pid
  let claude_quota_standing = claude_quota_standing
end
