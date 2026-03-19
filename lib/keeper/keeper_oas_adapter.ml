(** Keeper_oas_adapter — OAS wrappers for keeper LLM calls.

    Delegates to [Oas_worker.run_named] / [run_named_with_masc_tools]
    (cascade-name-based, no model_spec construction) or to
    [Llm_cascade.call_with_tools] for single-shot cascade calls.

    @since OAS migration Phase 1
    @since LLM-free cascade Phase 2 *)

open Keeper_types
open Keeper_exec_tools

(* ================================================================ *)
(* Internal: tool dispatch                                           *)
(* ================================================================ *)

(** Default context window for tool dispatch scratch context. *)
let tool_dispatch_max_context = 8192

(** Context offload config: threshold from env or default 4096. *)
let context_offload_config () : Agent_sdk.Context_offload.config =
  let threshold = match Sys.getenv_opt "MASC_CONTEXT_OFFLOAD_THRESHOLD" with
    | Some s -> (try int_of_string s with Failure _ -> 4096)
    | None -> 4096
  in
  { Agent_sdk.Context_offload.default_config with threshold_bytes = threshold }

let make_dispatch ~(config : Room.config) ~(meta : keeper_meta)
    ~(gate_config : Eval_gate.gate_config option)
    ~(accumulated_cost_ref : float ref)
    ~(name : string) ~(args : Yojson.Safe.t) : bool * string =
  let ctx_work = Context_manager.create
    ~system_prompt:(Printf.sprintf "Keeper %s OAS tool dispatch" meta.name)
    ~max_tokens:tool_dispatch_max_context
  in
  let args_json = Yojson.Safe.to_string args in
  let execute () =
    let tc : Llm_types.tool_call = {
      call_id = "";
      call_name = name;
      call_arguments = args_json;
    } in
    execute_keeper_tool_call ~config ~meta ~ctx_work tc
  in
  match gate_config with
  | None ->
    (try
       let raw = execute () in
       let offloaded = Agent_sdk.Context_offload.offload_tool_result
         ~config:(context_offload_config ()) ~tool_name:name raw in
       (true, offloaded)
     with exn ->
       Log.Keeper.error "oas adapter tool %s failed: %s"
         name (Printexc.to_string exn);
       (false, Yojson.Safe.to_string
          (`Assoc [("error", `String "Tool execution failed");
                   ("tool", `String name)])))
  | Some gate ->
    let (decision, result_opt, eval_opt, _duration) =
      Eval_gate.guarded_execute
        ~config:gate
        ~accumulated_cost:!accumulated_cost_ref
        ~trajectory_acc:None
        ~tool_name:name
        ~args_json
        ~execute
    in
    (match decision with
     | Trajectory.Reject reason ->
       Log.Keeper.warn "eval_gate rejected %s: %s" name reason;
       (false, Yojson.Safe.to_string
          (`Assoc [("error", `String ("Gate rejected: " ^ reason));
                   ("tool", `String name)]))
     | Trajectory.Pass ->
       let raw_output = Option.value ~default:"{}" result_opt in
       let output = Agent_sdk.Context_offload.offload_tool_result
         ~config:(context_offload_config ()) ~tool_name:name raw_output in
       (match eval_opt with
        | Some eval ->
          accumulated_cost_ref :=
            !accumulated_cost_ref +. eval.Eval_gate.cost_usd;
          if eval.Eval_gate.should_warn then
            Log.Keeper.warn "eval_gate warning for %s: %s"
              name (Option.value ~default:"" eval.Eval_gate.warning)
        | None -> ());
       (true, output))

(* ================================================================ *)
(* Public: run_with_tools                                            *)
(* ================================================================ *)

type tools_run_result = {
  oas_result : Oas_worker.run_result;
  tools_executed : string list;
  cost_report : Agent_sdk.Cost_tracker.cost_report option;
}

let run_with_tools
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(cascade_name : string)
    ~(system_prompt : string)
    ~(goal : string)
    ~(max_turns : int)
    ~(temperature : float)
    ~(max_tokens : int)
    ?(gate_config : Eval_gate.gate_config option)
    ?(guardrails : Agent_sdk.Guardrails.t option)
    ()
  : (tools_run_result, string) result =
  let masc_tools = keeper_allowed_llm_tools meta in
  let tools_executed_ref = ref [] in
  let accumulated_cost_ref = ref 0.0 in
  let dispatch ~(name : string) ~(args : Yojson.Safe.t) : bool * string =
    tools_executed_ref := name :: !tools_executed_ref;
    make_dispatch ~config ~meta ~gate_config ~accumulated_cost_ref ~name ~args
  in
  match Oas_worker.run_named_with_masc_tools
    ~cascade_name ~goal ~system_prompt ~masc_tools ~dispatch
    ~max_turns ~temperature ~max_tokens ?guardrails ()
  with
  | Ok oas_result ->
      let usage = Llm_types.usage_of_response oas_result.response in
      let cost_report = Some (Eval_gate.cost_report
        ~accumulated_cost:!accumulated_cost_ref
        ~api_calls:(max 1 oas_result.turns)
        ~input_tokens:usage.input_tokens
        ~output_tokens:usage.output_tokens)
      in
      Ok { oas_result; tools_executed = List.rev !tools_executed_ref; cost_report }
  | Error e -> Error e

(* ================================================================ *)
(* Public: run_with_custom_dispatch                                  *)
(* ================================================================ *)

(** Run with a custom dispatch function and explicit tool list.
    Uses cascade-name-based API (post-#1730).
    [model_spec_override] is accepted for backward compat but ignored —
    model resolution happens inside [Oas_worker.run_named_with_masc_tools]. *)
let run_with_custom_dispatch
    ~(meta : keeper_meta)
    ?(model_spec_override : Llm_types.model_spec option)
    ~(system_prompt : string)
    ~(goal : string)
    ~(max_turns : int)
    ~(temperature : float)
    ~(max_tokens : int)
    ~(masc_tools : Llm_types.tool_def list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(guardrails : Agent_sdk.Guardrails.t option)
    ()
  : (Oas_worker.run_result, string) result =
  ignore model_spec_override;
  let cascade_name = Printf.sprintf "keeper_%s" meta.name in
  Oas_worker.run_named_with_masc_tools
    ~cascade_name ~goal ~system_prompt ~masc_tools ~dispatch
    ~max_turns ~temperature ~max_tokens ?guardrails ()

(* ================================================================ *)
(* Public: run_simple                                                *)
(* ================================================================ *)

let run_simple
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(cascade_name : string)
    ~(system_prompt : string)
    ~(prompt : string)
    ~(temperature : float)
    ~(max_tokens : int)
    ()
  : (Oas_worker.run_result, string) result =
  ignore (config, meta);
  Oas_worker.run_named ~cascade_name ~goal:prompt ~system_prompt
    ~max_turns:1 ~temperature ~max_tokens ()

(* ================================================================ *)
(* Public: result extractors                                         *)
(* ================================================================ *)

let text_of_run_result (r : Oas_worker.run_result) : string =
  Llm_types.text_of_response r.response

let usage_of_run_result (r : Oas_worker.run_result) : Llm_types.token_usage =
  Llm_types.usage_of_response r.response

let model_of_run_result (r : Oas_worker.run_result) : string =
  r.response.model

(* ================================================================ *)
(* Internal: extract prompt from completion_request list             *)
(* ================================================================ *)

type prompt_params = {
  system_prompt : string;
  goal : string;
  temperature : float;
  max_tokens : int;
}

let separate_system_and_user (msgs : Agent_sdk.Types.message list) :
    string * Agent_sdk.Types.message list =
  let sys_parts = ref [] in
  let rest = ref [] in
  List.iter (fun (m : Agent_sdk.Types.message) ->
    match m.role with
    | Agent_sdk.Types.System -> sys_parts := Llm_types.text_of_message m :: !sys_parts
    | _ -> rest := m :: !rest
  ) msgs;
  let sys = String.concat "\n" (List.rev !sys_parts) in
  (sys, List.rev !rest)

let messages_to_goal_text (msgs : Agent_sdk.Types.message list) : string =
  msgs
  |> List.map (fun (m : Agent_sdk.Types.message) -> Llm_types.text_of_message m)
  |> List.filter (fun s -> String.length s > 0)
  |> String.concat "\n"

let extract_prompt_params
    (requests : Llm_types.completion_request list)
  : (prompt_params, string) result =
  match requests with
  | [] -> Error "empty cascade request list"
  | first :: _ ->
      let sys_prompt, user_msgs = separate_system_and_user first.messages in
      let goal = messages_to_goal_text user_msgs in
      if String.length goal = 0 then
        Error "no user messages in cascade request"
      else
        Ok {
          system_prompt = sys_prompt;
          goal;
          temperature = first.temperature;
          max_tokens = first.max_tokens;
        }

(* ================================================================ *)
(* Public: cascade through Llm_cascade (single-shot, no Agent loop) *)
(* ================================================================ *)

let run_cascade ?(cascade_name = "keeper_turn") ?timeout_sec requests =
  match extract_prompt_params requests with
  | Error e -> Error e
  | Ok params ->
  let messages : Llm_provider.Types.message list =
    (if String.length params.system_prompt > 0 then
       [ Llm_provider.Types.system_msg params.system_prompt ]
     else [])
    @ [ Llm_provider.Types.user_msg params.goal ]
  in
  Llm_cascade.call_with_tools ~cascade_name ~messages
    ~temperature:params.temperature ~max_tokens:params.max_tokens
    ?timeout_sec ()

let run_cascade_stream ?(cascade_name = "keeper_turn") ?timeout_sec ~on_event request ~fallback =
  let timeout_int = Option.map int_of_float timeout_sec in
  match run_cascade ~cascade_name ?timeout_sec:timeout_int (request :: fallback) with
  | Ok resp ->
      let text = Llm_types.text_of_response resp in
      on_event (Llm_provider.Types.MessageStart {
        id = "batch-keeper"; model = resp.Llm_provider.Types.model; usage = None });
      if text <> "" then
        on_event (Llm_provider.Types.ContentBlockDelta {
          index = 0; delta = TextDelta text });
      on_event Llm_provider.Types.MessageStop;
      Ok resp
  | Error _ as e -> e
