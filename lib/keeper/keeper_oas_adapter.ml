(** Keeper_oas_adapter — OAS wrappers for keeper LLM calls.

    Delegates to [Oas_worker.run_named] / [run_named_with_masc_tools]
    (cascade-name-based, no model_spec construction) or to
    [Cascade.complete] for single-shot cascade calls.

    @since OAS migration Phase 1
    @since LLM-free cascade Phase 2 *)

open Keeper_types
open Keeper_exec_tools

(* ================================================================ *)
(* Internal: tool dispatch                                           *)
(* ================================================================ *)

(** Default context window for tool dispatch scratch context. *)
let tool_dispatch_max_context = 8192

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
    execute_keeper_tool_call ~config ~meta ~ctx_work ~name ~input:args
  in
  match gate_config with
  | None ->
    (try (true, execute ())
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
       let output = Option.value ~default:"{}" result_opt in
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
      Ok { oas_result; tools_executed = List.rev !tools_executed_ref }
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
    ?(model_spec_override : Cascade.model_spec option)
    ~(system_prompt : string)
    ~(goal : string)
    ~(max_turns : int)
    ~(temperature : float)
    ~(max_tokens : int)
    ~(masc_tools : Cascade.tool_def list)
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
  Cascade.text_of_response r.response

let usage_of_run_result (r : Oas_worker.run_result) : Agent_sdk.Types.api_usage =
  Cascade.usage_of_response r.response

let model_of_run_result (r : Oas_worker.run_result) : string =
  r.response.model

(* ================================================================ *)
(* Public: cascade through Cascade (single-shot, no Agent loop)      *)
(* ================================================================ *)

let run_cascade ?(cascade_name = "keeper_turn") ?timeout_sec
    ~(messages : Agent_sdk.Types.message list) ~temperature ~max_tokens () =
  Cascade.complete ~cascade_name ~messages ~temperature ~max_tokens
    ?timeout_sec ()

let run_cascade_stream ?(cascade_name = "keeper_turn") ?timeout_sec ~on_event
    ~(messages : Agent_sdk.Types.message list) ~temperature ~max_tokens () =
  let timeout_int = Option.map int_of_float timeout_sec in
  match run_cascade ~cascade_name ?timeout_sec:timeout_int ~messages ~temperature ~max_tokens () with
  | Ok resp ->
      let text = Cascade.text_of_response resp in
      on_event (Llm_provider.Types.MessageStart {
        id = "batch-keeper"; model = resp.Llm_provider.Types.model; usage = None });
      if text <> "" then
        on_event (Llm_provider.Types.ContentBlockDelta {
          index = 0; delta = TextDelta text });
      on_event Llm_provider.Types.MessageStop;
      Ok resp
  | Error _ as e -> e
