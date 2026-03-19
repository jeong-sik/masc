(** Keeper_oas_adapter — OAS Agent.run wrappers for keeper LLM calls.

    Delegates to [Oas_worker.run] (no tools) or [Oas_worker.run_with_masc_tools]
    (with keeper tool dispatch).

    @since OAS migration Phase 1 *)

open Keeper_types
open Keeper_exec_tools

(* ================================================================ *)
(* Internal: resolve model spec from keeper meta                     *)
(* ================================================================ *)

let resolve_primary_model_spec (meta : keeper_meta) :
    (Llm_types.model_spec, string) result =
  let labels =
    match Keeper_exec_status.active_model_of_meta meta with
    | "" ->
      let pool = dedupe_keep_order (meta.allowed_models @ meta.models) in
      if pool = [] then meta.models else pool
    | model -> [model]
  in
  match model_specs_of_strings labels with
  | Error e -> Error e
  | Ok [] -> Error "no model specs resolved"
  | Ok (primary :: _) -> Ok primary

let require_net () =
  match Eio_context.get_net_opt () with
  | Some net -> Ok net
  | None -> Error "Eio net not available (keeper running outside server context)"

let require_switch () =
  match Eio_context.get_switch_opt () with
  | Some sw -> Ok sw
  | None -> Error "Eio switch not available (keeper running outside server context)"

(* ================================================================ *)
(* Internal: keeper tool dispatch closure for OAS                    *)
(* ================================================================ *)

(** Build a dispatch closure compatible with [Oas_worker.run_with_masc_tools].
    Creates a minimal [Context_manager.working_context] for tool execution. *)
let make_dispatch ~(config : Room.config) ~(meta : keeper_meta)
    ~(model_spec : Llm_types.model_spec)
    ~(name : string) ~(args : Yojson.Safe.t) : bool * string =
  let ctx_work = Context_manager.create
    ~system_prompt:(Printf.sprintf "Keeper %s OAS tool dispatch" meta.name)
    ~max_tokens:model_spec.max_context
  in
  let tc : Llm_types.tool_call = {
    call_id = "";
    call_name = name;
    call_arguments = Yojson.Safe.to_string args;
  } in
  try
    let output = execute_keeper_tool_call ~config ~meta ~ctx_work tc in
    (true, output)
  with exn ->
    Log.Keeper.error "oas adapter tool %s failed: %s" name (Printexc.to_string exn);
    (false, Yojson.Safe.to_string
       (`Assoc [
         ("error", `String "Tool execution failed");
         ("tool", `String name);
       ]))

(* ================================================================ *)
(* Public: run_with_tools                                            *)
(* ================================================================ *)

type tools_run_result = {
  oas_result : Oas_worker.run_result;
  tools_executed : string list;
}

let run_with_tools
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ?model_spec:model_spec_override
    ~(system_prompt : string)
    ~(goal : string)
    ~(max_turns : int)
    ~(temperature : float)
    ~(max_tokens : int)
    ?(guardrails : Agent_sdk.Guardrails.t option)
    ()
  : (tools_run_result, string) result =
  let model_spec_result = match model_spec_override with
    | Some spec -> Ok spec
    | None -> resolve_primary_model_spec meta
  in
  match model_spec_result with
  | Error e -> Error e
  | Ok model_spec ->
  match require_net () with
  | Error e -> Error e
  | Ok net ->
  match require_switch () with
  | Error e -> Error e
  | Ok sw ->
  let masc_tools = keeper_allowed_llm_tools meta in
  let tools_executed_ref = ref [] in
  let dispatch ~(name : string) ~(args : Yojson.Safe.t) : bool * string =
    tools_executed_ref := name :: !tools_executed_ref;
    make_dispatch ~config ~meta ~model_spec ~name ~args
  in
  let oas_config = { (Oas_worker.default_config
    ~name:(Printf.sprintf "keeper-%s" meta.name)
    ~model_spec
    ~system_prompt
    ~tools:[]) with
    max_turns;
    max_tokens;
    temperature;
    guardrails;
  } in
  match Oas_worker.run_with_masc_tools
    ~sw ~net ~config:oas_config ~masc_tools ~dispatch goal
  with
  | Ok oas_result ->
      Ok { oas_result; tools_executed = List.rev !tools_executed_ref }
  | Error e -> Error e

(* ================================================================ *)
(* Public: run_simple                                                *)
(* ================================================================ *)

let run_simple
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ?model_spec:model_spec_override
    ~(system_prompt : string)
    ~(prompt : string)
    ~(temperature : float)
    ~(max_tokens : int)
    ()
  : (Oas_worker.run_result, string) result =
  ignore config;
  let model_spec_result = match model_spec_override with
    | Some spec -> Ok spec
    | None -> resolve_primary_model_spec meta
  in
  match model_spec_result with
  | Error e -> Error e
  | Ok model_spec ->
  match require_net () with
  | Error e -> Error e
  | Ok net ->
  match require_switch () with
  | Error e -> Error e
  | Ok sw ->
  let oas_config = { (Oas_worker.default_config
    ~name:(Printf.sprintf "keeper-%s-simple" meta.name)
    ~model_spec
    ~system_prompt
    ~tools:[]) with
    max_turns = 1;
    max_tokens;
    temperature;
  } in
  Oas_worker.run ~sw ~net ~config:oas_config prompt

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
(* Internal: extract OAS parameters from completion_request list    *)
(* ================================================================ *)

type cascade_params = {
  primary_spec : Llm_types.model_spec;
  fallback_specs : Llm_types.model_spec list;
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

let cascade_config_of_requests
    (requests : Llm_types.completion_request list)
  : (cascade_params, string) result =
  match requests with
  | [] -> Error "empty cascade request list"
  | first :: rest ->
      let sys_prompt, user_msgs = separate_system_and_user first.messages in
      let goal = messages_to_goal_text user_msgs in
      if String.length goal = 0 then
        Error "no user messages in cascade request"
      else
        Ok {
          primary_spec = first.model;
          fallback_specs =
            List.map (fun (r : Llm_types.completion_request) -> r.model) rest;
          system_prompt = sys_prompt;
          goal;
          temperature = first.temperature;
          max_tokens = first.max_tokens;
        }

(* ================================================================ *)
(* Public: cascade through OAS Agent.t                              *)
(* ================================================================ *)

let run_cascade ?timeout_sec requests =
  match cascade_config_of_requests requests with
  | Error e -> Error e
  | Ok params ->
  let messages : Llm_provider.Types.message list =
    (if String.length params.system_prompt > 0 then
       [ Llm_provider.Types.system_msg params.system_prompt ]
     else [])
    @ [ Llm_provider.Types.user_msg params.goal ]
  in
  Llm_cascade.call_with_tools ~cascade_name:"keeper_autonomy" ~messages
    ~temperature:params.temperature ~max_tokens:params.max_tokens
    ?timeout_sec ()

let run_cascade_stream ?timeout_sec ~on_event request ~fallback =
  (* Batch fallback with synthetic SSE events.
     All calls route through Llm_cascade. *)
  let timeout_int = Option.map int_of_float timeout_sec in
  match run_cascade ?timeout_sec:timeout_int (request :: fallback) with
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
