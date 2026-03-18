(** Keeper_oas_adapter — OAS Agent.run wrappers for keeper LLM calls.

    Replaces direct [Llm_orchestration.cascade] usage in keeper modules.
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

let run_with_tools
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(system_prompt : string)
    ~(goal : string)
    ~(max_turns : int)
    ~(temperature : float)
    ~(max_tokens : int)
  : (Oas_worker.run_result, string) result =
  match resolve_primary_model_spec meta with
  | Error e -> Error e
  | Ok model_spec ->
  match require_net () with
  | Error e -> Error e
  | Ok net ->
  match require_switch () with
  | Error e -> Error e
  | Ok sw ->
  let masc_tools = keeper_allowed_llm_tools meta in
  let dispatch = make_dispatch ~config ~meta ~model_spec in
  let oas_config = { (Oas_worker.default_config
    ~name:(Printf.sprintf "keeper-%s" meta.name)
    ~model_spec
    ~system_prompt
    ~tools:[]) with
    max_turns;
    max_tokens;
    temperature;
  } in
  Oas_worker.run_with_masc_tools
    ~sw ~net ~config:oas_config ~masc_tools ~dispatch goal

(* ================================================================ *)
(* Public: run_simple                                                *)
(* ================================================================ *)

let run_simple
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(system_prompt : string)
    ~(prompt : string)
    ~(temperature : float)
    ~(max_tokens : int)
  : (Oas_worker.run_result, string) result =
  ignore config;
  match resolve_primary_model_spec meta with
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
(* Public: cascade compatibility wrappers                           *)
(* ================================================================ *)

let run_cascade ?timeout_sec requests =
  Llm_orchestration.cascade ?timeout_sec requests

let run_cascade_stream ?timeout_sec ~on_event request ~fallback =
  match
    Llm_orchestration.call_provider_stream ?timeout_sec request ~on_event
  with
  | Ok _ as ok -> ok
  | Error e ->
      Log.Keeper.warn "oas adapter stream failed (%s), falling back to batch" e;
      let timeout_int = Option.map int_of_float timeout_sec in
      Llm_orchestration.cascade ?timeout_sec:timeout_int fallback
