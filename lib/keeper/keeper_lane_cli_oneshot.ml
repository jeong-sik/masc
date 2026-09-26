module Exact_output = Agent_core.Exact_output

type failure =
  | Unknown_runtime of { runtime_id : string }
  | Not_an_official_client of { runtime_id : string }
  | Execution_failed of
      { runtime_id : string
      ; cause : Fusion_official_client.failure
      }
  | Invalid_json_output of
      { runtime_id : string
      ; detail : string
      }
  | Invalid_domain_output of
      { runtime_id : string
      ; detail : string
      }

let failure_to_string = function
  | Invalid_domain_output { runtime_id; detail } ->
    Printf.sprintf "cli lane slot %s answered invalid domain output: %s" runtime_id detail
  | Unknown_runtime { runtime_id } ->
    Printf.sprintf "cli lane slot %s names no configured runtime" runtime_id
  | Not_an_official_client { runtime_id } ->
    Printf.sprintf "cli lane slot %s is not an official-client runtime" runtime_id
  | Execution_failed { runtime_id; cause } ->
    let detail = Fusion_official_client.failure_detail ~runtime_id cause in
    Printf.sprintf "cli lane slot failed to answer: %s" detail
  | Invalid_json_output { runtime_id; detail } ->
    Printf.sprintf "cli lane slot %s answered non-JSON: %s" runtime_id detail

(* A client refusal that names the account's standing: Claude reports its
   quota blocked; Codex tags a failed turn with a usage or rate limit spent,
   or its server overloaded. Antigravity reports RESOURCE_EXHAUSTED only as
   turn text, which is not read here, so its refusals are not rest. *)
let claude_error_is_binding_rest : Runtime_claude_code.error -> bool = function
  | Runtime_claude_code.Quota_blocked _ -> true
  | Runtime_claude_code.Invalid_config _
  | Runtime_claude_code.Spawn_failed _
  | Runtime_claude_code.Protocol_error _
  | Runtime_claude_code.Subscription_required _
  | Runtime_claude_code.Unsupported_control_request _
  | Runtime_claude_code.Turn_transport_interrupted _
  | Runtime_claude_code.Context_window_exceeded _
  | Runtime_claude_code.Turn_failed _
  | Runtime_claude_code.Turn_failed_with_observation _
  | Runtime_claude_code.Stopped_by_host _
  | Runtime_claude_code.Process_exited _
  | Runtime_claude_code.Timeout _ -> false
;;

let codex_info_is_binding_rest :
  Runtime_codex_app_server.Codex_error_info.t -> bool
  = function
  | Runtime_codex_app_server.Codex_error_info.Usage_limit_exceeded
  | Runtime_codex_app_server.Codex_error_info.Rate_limit_exceeded
  | Runtime_codex_app_server.Codex_error_info.Server_overloaded -> true
  | Runtime_codex_app_server.Codex_error_info.Session_budget_exceeded
  | Runtime_codex_app_server.Codex_error_info.Cyber_policy
  | Runtime_codex_app_server.Codex_error_info.Misalignment_policy_violation
  | Runtime_codex_app_server.Codex_error_info.Internal_server_error
  | Runtime_codex_app_server.Codex_error_info.Unauthorized
  | Runtime_codex_app_server.Codex_error_info.Bad_request
  | Runtime_codex_app_server.Codex_error_info.Thread_rollback_failed
  | Runtime_codex_app_server.Codex_error_info.Sandbox_error
  | Runtime_codex_app_server.Codex_error_info.Other
  | Runtime_codex_app_server.Codex_error_info.Http_connection_failed _
  | Runtime_codex_app_server.Codex_error_info.Response_stream_connection_failed _
  | Runtime_codex_app_server.Codex_error_info.Response_stream_disconnected _
  | Runtime_codex_app_server.Codex_error_info.Response_too_many_failed_attempts _
  | Runtime_codex_app_server.Codex_error_info.Active_turn_not_steerable _
  | Runtime_codex_app_server.Codex_error_info.Unrecognized _ -> false
;;

let codex_error_is_binding_rest : Runtime_codex_app_server.error -> bool = function
  | Runtime_codex_app_server.Turn_failed { codex_error_info = Some info; detail = _ } ->
    codex_info_is_binding_rest info
  | Runtime_codex_app_server.Turn_failed { codex_error_info = None; detail = _ }
  | Runtime_codex_app_server.Invalid_config _
  | Runtime_codex_app_server.Spawn_failed _
  | Runtime_codex_app_server.Turn_input_write_failed _
  | Runtime_codex_app_server.Protocol_error _
  | Runtime_codex_app_server.Rpc_error _
  | Runtime_codex_app_server.Subscription_required _
  | Runtime_codex_app_server.Unsupported_server_request _
  | Runtime_codex_app_server.Context_window_exceeded _
  | Runtime_codex_app_server.Stopped_by_host _
  | Runtime_codex_app_server.Turn_interrupted
  | Runtime_codex_app_server.Runtime_shutting_down
  | Runtime_codex_app_server.Process_exited _
  | Runtime_codex_app_server.Timeout _ -> false
;;

let antigravity_error_is_binding_rest : Runtime_antigravity.error -> bool = function
  | Runtime_antigravity.Invalid_config _
  | Runtime_antigravity.Spawn_failed _
  | Runtime_antigravity.Protocol_error _
  | Runtime_antigravity.State_callback_failed _
  | Runtime_antigravity.Turn_failed _
  | Runtime_antigravity.Process_exited _
  | Runtime_antigravity.Timeout _ -> false
;;

let refused_for_binding_rest = function
  | Execution_failed { cause = Fusion_official_client.Claude_failure error; runtime_id = _ }
  | Execution_failed
      { cause = Fusion_official_client.Claude_admission_failure error; runtime_id = _ } ->
    claude_error_is_binding_rest error
  | Execution_failed { cause = Fusion_official_client.Codex_failure error; runtime_id = _ } ->
    codex_error_is_binding_rest error
  | Execution_failed
      { cause = Fusion_official_client.Antigravity_failure error; runtime_id = _ } ->
    antigravity_error_is_binding_rest error
  | Execution_failed { cause = Fusion_official_client.Setup_failure _; runtime_id = _ }
  | Unknown_runtime _
  | Not_an_official_client _
  | Invalid_json_output _
  | Invalid_domain_output _ -> false
;;

type runner =
  runtime_id:string
  -> system_prompt:string
  -> output_schema:Yojson.Safe.t
  -> prompt:string
  -> (string, Fusion_official_client.failure) result

let default_runner ~base_dir : runner =
  fun ~runtime_id ~system_prompt ~output_schema ~prompt ->
  match Runtime.get_runtime_by_id runtime_id with
  | None -> Error (Fusion_official_client.Setup_failure "runtime is not configured")
  | Some runtime ->
    Fusion_official_client.run_with_images ~images:[]
      ~base_dir ~runtime ~system_prompt ~output_schema ~prompt ()
    |> Result.map (fun (response : Fusion_official_client.response) -> response.text)
;;

let prompt_with_schema ~requirement ~prompt =
  prompt ^ "\n\n" ^ Exact_output.schema_instruction_text requirement
;;

(* [Unknown_runtime] and [Not_an_official_client] used to be one case
   ([Fusion_official_client.is_official_client] answers [false] for both: no
   such runtime, and a runtime that is not an official client), so every
   cli-slot refusal read "is not an official-client runtime" even when the id
   was a plain typo. Load-time validation (RFC: [runtime.ml]
   [exact_lane_cli_slot_references] / [validate_exact_lane_cli_slot_official_clients])
   now refuses an unresolved or non-official cli_slots id before a lane
   publishes, so [Unknown_runtime] should be unreachable through a loaded
   config; it stays a distinct, correctly-labeled case rather than folding
   back into [Not_an_official_client] for a caller that dispatches a
   [runtime_id] the loader never validated (e.g. a test-injected value). *)
let run ?runner ~base_dir ~runtime_id ~system_prompt ~requirement ~prompt () =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> Error (Unknown_runtime { runtime_id })
  | Some runtime ->
    (match Runtime_execution.checkpoint_owner runtime.Runtime.execution with
     | Runtime_execution.Masc_agent_core -> Error (Not_an_official_client { runtime_id })
     | Runtime_execution.Official_client ->
       let runner =
         match runner with
         | Some runner -> runner
         | None -> default_runner ~base_dir
       in
       (* Same words as the HTTP path's prompt-carried schema ([Off]/[JsonMode]).
          The instruction stays even though the transport now carries the schema
          too: the Claude and Antigravity CLIs enforce by validating their own
          answer and re-prompting, so a model that was told the shape needs fewer
          rounds to produce it, and llama.cpp's own documentation notes that a
          schema handed to a grammar is never shown to the model at all. The two
          channels answer different halves -- one says what to write, the other
          refuses what does not match. *)
       let prompt =
         prompt_with_schema ~requirement ~prompt
       in
       (match
          runner
            ~runtime_id
            ~system_prompt
            ~output_schema:(Exact_output.domain_schema requirement)
            ~prompt
        with
        | Error cause -> Error (Execution_failed { runtime_id; cause })
        | Ok answer ->
          (* Strict on purpose: Agent Core parses a [Json_syntax_only] HTTP body
             with exactly [Yojson.Safe.from_string] and no repair, and a lane
             slot changes transport, not contract. *)
          (try Ok (Yojson.Safe.from_string answer) with
           | Yojson.Json_error detail -> Error (Invalid_json_output { runtime_id; detail }))))
;;

let order_slots slots =
  Runtime_quota_window.demote_order
    ~now:(Time_compat.now ())
    ~quota_scope_of:Runtime.quota_scope_of_runtime_id
    slots
;;

let walk ?runner ~base_dir ~cli_slots ~system_prompt ~requirement ~prompt ~validate ~on_failure () =
  let rec reject failures rest failure =
    on_failure failure;
    loop (failure :: failures) rest
  and loop failures slots =
    match order_slots slots with
    | [] -> Error (List.rev failures)
    | runtime_id :: rest ->
      (match run ?runner ~base_dir ~runtime_id ~system_prompt ~requirement ~prompt () with
       | Ok value ->
         (match validate value with
          | Ok accepted -> Ok (runtime_id, accepted)
          | Error detail ->
            reject failures rest (Invalid_domain_output { runtime_id; detail }))
       | Error failure -> reject failures rest failure)
  in
  loop [] cli_slots
;;

type input_capacity =
  { runtime_id : string
  ; capacity : Runtime_codex_app_server.input_capacity
  }

let input_capacity = function
  | Execution_failed { runtime_id; cause = Fusion_official_client.Codex_failure error } ->
    Runtime_codex_app_server.input_capacity_refusal error
    |> Option.map (fun capacity -> {runtime_id; capacity})
  | _ -> None
;;
