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

(* Naming the absent handle is the point: the server publishes both together but
   other entry points publish them separately, so "the Eio runtime is not
   initialized" sends the reader to look at the wrong one. Split out as a pure
   function because Eio_context has no reset, so a test that drove the real
   globals could only reach these arms in one fragile order.

   Its result is already carried to the caller as a typed
   [Fusion_types.panel_failure] and lands in the fusion run record. *)
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

let eio_context ~runtime_id =
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
    Error (provider_error ~runtime_id detail)
;;

(* [Runtime_execution.*] carries admission-time config; each adapter has its own
   config record. The conversions below mirror the keeper path exactly
   (keeper_claude_code_runtime.ml:224, keeper_antigravity_runtime.ml:241) so a
   panelist runs the same client the keeper would, minus the parts a panelist
   has no business using. *)

(* 데드라인 우선순위: preset 그룹의 [panel_timeout_s]([override_s]) > 런타임이 추론한
   turn timeout > 어댑터 admission timeout. preset 이 가장 강한 이유는 그것이 이
   요청에 대한 소비자의 명시 선언이기 때문이다 — 런타임 값은 모든 소비자가 공유하는
   기본값이라, preset 이 그것을 이기지 못하면 "이 심의는 240s 까지 기다린다" 를
   표현할 방법이 없다. [override_s] 는 [Fusion_policy.valid_timeout_s] 를 통과한
   값만 들어온다(config 로드에서 판정). *)
let resolved_timeout_s ~runtime_id ~override_s ~default_timeout_s =
  match override_s with
  | Some _ as declared -> declared
  | None ->
    (match Runtime_inference.resolve_turn_timeout_s ~runtime_id with
     | None -> Some default_timeout_s
     | Some seconds when seconds <= 0.0 -> None
     | Some seconds -> Some seconds)
;;

let bounded_claude_probe_config ~fallback_timeout_s
  (config : Runtime_claude_code.config)
  =
  match config.timeout_s with
  | Some _ -> config
  | None -> { config with timeout_s = Some fallback_timeout_s }
;;

let claude_config ~base_dir ~runtime_id ~system_prompt ~override_s ~output_schema
  (execution : Runtime_execution.claude_code)
  : Runtime_claude_code.config
  =
  { cli_path = execution.cli_path
  ; cwd = base_dir
  ; model = execution.model
  ; native = Runtime_native_tools.claude_code_default
  ; setting_sources = []
  ; system_prompt
  ; admission_timeout_s = execution.timeout_s
  ; timeout_s =
      resolved_timeout_s ~runtime_id ~override_s ~default_timeout_s:execution.timeout_s
  ; wall_clock_ceiling_s = None
  ; output_schema
  }
;;

let codex_config ~runtime_id ~system_prompt ~override_s ~output_schema
  (execution : Runtime_execution.codex_app_server)
  : Runtime_codex_app_server.config
  =
  { cli_path = execution.cli_path
  ; model = execution.model
  ; native = Runtime_native_tools.codex_default
  ; developer_instructions = system_prompt
  ; admission_timeout_s = execution.timeout_s
  ; timeout_s =
      resolved_timeout_s ~runtime_id ~override_s ~default_timeout_s:execution.timeout_s
  ; wall_clock_ceiling_s = None
  ; output_schema
  }
;;

let antigravity_config ~base_dir ~runtime_id ~override_s ~output_schema
  (execution : Runtime_execution.antigravity_cli)
  : Runtime_antigravity.config
  =
  { cli_path = execution.cli_path
  ; cwd = base_dir
  ; add_dirs = []
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
  ; admission_timeout_s = execution.timeout_s
  ; timeout_s =
      resolved_timeout_s ~runtime_id ~override_s ~default_timeout_s:execution.timeout_s
  ; wall_clock_ceiling_s = None
  ; output_schema
  }
;;

let run_panelist ~base_dir ~runtime_id ~system_prompt ?timeout_s ?output_schema ~prompt () =
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
    let config =
      claude_config ~base_dir ~runtime_id ~system_prompt ~override_s:timeout_s
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
         probe_config
     with
     | Error error ->
       Error (provider_error ~runtime_id (Runtime_claude_code.error_to_string error))
     | Ok admitted_subscription ->
       (match
          Runtime_claude_code.run_turn
            ~admitted_subscription
            ~mgr
            ~clock
            ~cwd
            config
            ~prompt
            ~images:[]
        with
        | Ok (result : Runtime_claude_code.turn_result) -> Ok result.text
        | Error error ->
          Error
            (provider_error
               ~runtime_id
               (Runtime_claude_code.error_to_string error))))
  | Runtime_execution.Codex_app_server execution ->
    let config =
      codex_config ~runtime_id ~system_prompt ~override_s:timeout_s ~output_schema execution
    in
    (match Runtime_codex_app_server.run_turn ~mgr ~clock ~cwd config ~prompt ~images:[] with
     | Ok (result : Runtime_codex_app_server.turn_result) -> Ok result.text
     | Error error ->
       Error
         (provider_error ~runtime_id (Runtime_codex_app_server.error_to_string error)))
  | Runtime_execution.Antigravity_cli execution ->
    let config =
      antigravity_config ~base_dir ~runtime_id ~override_s:timeout_s ~output_schema execution
    in
    (* [home_dir] is left unset so the client uses the inherited HOME, which is
       where its OAuth token already lives. The keeper path overrides it for
       per-keeper isolation; a panelist has no durable state to isolate. *)
    (match Runtime_antigravity.run_turn ~mgr ~clock ~cwd config ~prompt with
     | Ok (result : Runtime_antigravity.turn_result) -> Ok result.text
     | Error error ->
       Error (provider_error ~runtime_id (Runtime_antigravity.error_to_string error)))
;;

module For_testing = struct
  (* Re-exported so a test can reach every arm without driving the
     process-global Eio context, which has no reset. *)
  (* TEL-OK: alias of a pure function; no behaviour of its own. *)
  let missing_handle_detail = missing_handle_detail
  let resolved_timeout_s = resolved_timeout_s
  let bounded_claude_probe_config = bounded_claude_probe_config
end
