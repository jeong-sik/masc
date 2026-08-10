(* Execution path for fusion panelists on official-client runtimes. See the
   .mli for why this exists. *)

let runtime_execution ~runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> None
  | Some runtime -> Some runtime.Runtime.execution
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

let eio_context ~runtime_id =
  (* Naming the absent handle is the point: both are published together by the
     server but separately by other entry points, so "the Eio runtime is not
     initialized" sends the reader to look at the wrong one. *)
  match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
  | Some env, Some clock -> Ok (env, clock)
  | None, None ->
    Error
      (provider_error
         ~runtime_id
         "official-client panelist requires Eio_context env and clock; neither \
          is published")
  | None, Some _ ->
    Error
      (provider_error
         ~runtime_id
         "official-client panelist requires Eio_context env (process manager \
          and fs); it is not published")
  | Some _, None ->
    Error
      (provider_error
         ~runtime_id
         "official-client panelist requires Eio_context clock; it is not \
          published")
;;

(* [Runtime_execution.*] carries admission-time config; each adapter has its own
   config record. The conversions below mirror the keeper path exactly
   (keeper_claude_code_runtime.ml:224, keeper_antigravity_runtime.ml:241) so a
   panelist runs the same client the keeper would, minus the parts a panelist
   has no business using. *)

let claude_config ~base_dir ~system_prompt (execution : Runtime_execution.claude_code)
  : Runtime_claude_code.config
  =
  { cli_path = execution.cli_path
  ; cwd = base_dir
  ; model = execution.model
  ; system_prompt
  ; timeout_s = execution.timeout_s
  }
;;

let codex_config ~system_prompt (execution : Runtime_execution.codex_app_server)
  : Runtime_codex_app_server.config
  =
  { cli_path = execution.cli_path
  ; model = execution.model
  ; developer_instructions = system_prompt
  ; timeout_s = execution.timeout_s
  }
;;

let antigravity_config ~base_dir (execution : Runtime_execution.antigravity_cli)
  : Runtime_antigravity.config
  =
  { cli_path = execution.cli_path
  ; cwd = base_dir
  ; model = execution.model
  ; agent = execution.agent
  ; effort = execution.effort
  ; (* A panelist answers a question; it does not edit the workspace. Plan mode
       plus the sandbox is the same pair the keeper path uses, and it is the
       correct pair here for a stronger reason: nothing downstream of a panel
       answer expects files to have changed. *)
    execution_mode = Runtime_antigravity.Plan
  ; sandbox = true
  ; disable_slash_commands = true
  ; timeout_s = execution.timeout_s
  }
;;

let run_panelist ~base_dir ~runtime_id ~system_prompt ~prompt =
  let ( let* ) = Result.bind in
  (* Both adapters take the system prompt as an option and treat [None] as
     "client default". An empty group prompt is not an instruction, so it
     becomes [None] rather than an empty instruction the client must obey. *)
  let system_prompt =
    match String.trim system_prompt with "" -> None | text -> Some text
  in
  let* execution =
    match runtime_execution ~runtime_id with
    | Some execution -> Ok execution
    | None -> Error (provider_error ~runtime_id "runtime is not configured")
  in
  let* env, clock = eio_context ~runtime_id in
  let mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Path.(Eio.Stdenv.fs env / base_dir) in
  match execution with
  | Runtime_execution.Agent_core _ ->
    (* Callers route Agent_core panelists through Fusion_agent_core. Reaching
       here means the split in Fusion_panel disagreed with [is_official_client],
       which is a bug in this module's callers rather than a provider failure. *)
    Error
      (provider_error
         ~runtime_id
         "runtime is Agent_core-owned; it belongs on the Async_agent path")
  | Runtime_execution.Claude_code execution ->
    let config = claude_config ~base_dir ~system_prompt execution in
    (match Runtime_claude_code.run_turn ~mgr ~clock ~cwd config ~prompt with
     | Ok (result : Runtime_claude_code.turn_result) -> Ok result.text
     | Error error ->
       Error (provider_error ~runtime_id (Runtime_claude_code.error_to_string error)))
  | Runtime_execution.Codex_app_server execution ->
    let config = codex_config ~system_prompt execution in
    (match Runtime_codex_app_server.run_turn ~mgr ~clock ~cwd config ~prompt with
     | Ok (result : Runtime_codex_app_server.turn_result) -> Ok result.text
     | Error error ->
       Error
         (provider_error ~runtime_id (Runtime_codex_app_server.error_to_string error)))
  | Runtime_execution.Antigravity_cli execution ->
    let config = antigravity_config ~base_dir execution in
    (* [home_dir] is left unset so the client uses the inherited HOME, which is
       where its OAuth token already lives. The keeper path overrides it for
       per-keeper isolation; a panelist has no durable state to isolate. *)
    (match Runtime_antigravity.run_turn ~mgr ~clock ~cwd config ~prompt with
     | Ok (result : Runtime_antigravity.turn_result) -> Ok result.text
     | Error error ->
       Error (provider_error ~runtime_id (Runtime_antigravity.error_to_string error)))
;;
