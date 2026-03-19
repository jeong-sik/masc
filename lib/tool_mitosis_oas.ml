(** Tool_mitosis_oas — OAS-based mitosis tool handlers.

    Replaces [Tool_mitosis] with OAS Agent lifecycle management.
    Same 10 MCP tool interface, ~50% less code.

    Key changes from legacy:
    - Divide/Handoff use [Oas_worker.run_with_masc_tools] to spawn real agents
    - DNA extraction reuses [Succession_oas]
    - Child agents receive MASC tools via dispatch adapter

    MASC L3 state ([Mcp_server.current_cell], [stem_pool]) is preserved.
    OAS manages agent lifecycle; MASC coordinates across agents.

    @since Phase 1 — MASC->OAS migration *)

module Oas = Agent_sdk

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type context = {
  config : Room_utils.config;
  agent_name : string;
  masc_tools : Cascade.tool_def list;
  dispatch : name:string -> args:Yojson.Safe.t -> bool * string;
}

type result = bool * string

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let json_ok json = (true, Yojson.Safe.pretty_to_string json)
let json_err msg = (false, Yojson.Safe.pretty_to_string
  (`Assoc [("error", `String msg)]))

let get_string args key default =
  Tool_args.get_string args key default

let get_float args key default =
  Tool_args.get_float args key default

let current_cell () = !(Mcp_server.current_cell)
let stem_pool () = !(Mcp_server.stem_pool)

(** Clamp context_ratio to valid range *)
let validate_context_ratio ratio =
  if ratio < 0.0 then (
    Printf.eprintf "[MITOSIS_OAS/WARN] context_ratio < 0 (%.2f), clamping to 0.0\n%!" ratio;
    0.0)
  else if ratio > 1.0 then (
    Printf.eprintf "[MITOSIS_OAS/WARN] context_ratio > 1 (%.2f), clamping to 1.0\n%!" ratio;
    1.0)
  else ratio

(* ================================================================ *)
(* Status / read-only handlers                                       *)
(* ================================================================ *)

let handle_mitosis_status _ctx _args : result =
  let cell = current_cell () in
  let pool = stem_pool () in
  json_ok (`Assoc [
    ("cell", Mitosis.cell_to_json cell);
    ("pool", Mitosis.pool_to_json pool);
    ("config", Mitosis.config_to_json Mitosis.default_config);
    ("runtime", `String "oas");
  ])

let handle_mitosis_all ctx _args : result =
  let statuses = Mitosis.get_all_statuses ~room_config:ctx.config in
  json_ok (`List (List.map (fun (node_id, status, ratio) ->
    `Assoc [
      ("node_id", `String node_id);
      ("status", `String status);
      ("estimated_ratio", `Float ratio);
    ]) statuses))

let handle_mitosis_pool _ctx _args : result =
  json_ok (Mitosis.pool_to_json (stem_pool ()))

(* ================================================================ *)
(* Check — threshold readiness                                       *)
(* ================================================================ *)

let handle_mitosis_check _ctx args : result =
  let cell = current_cell () in
  let config = Mitosis.default_config in
  let raw_ratio = get_float args "context_ratio" 0.0 in
  let context_ratio = validate_context_ratio raw_ratio in
  if raw_ratio = 0.0 then
    Printf.eprintf "[MITOSIS_OAS/WARN] context_ratio is 0.0 - did you forget to estimate it?\n%!";
  let should_prepare = Mitosis.should_prepare ~config ~cell ~context_ratio in
  let should_handoff = Mitosis.should_handoff ~config ~cell ~context_ratio in
  let phase = match should_handoff, should_prepare with
    | true, _ -> "handoff"
    | _, true -> "prepare"
    | _, _ -> "normal"
  in
  let warning = if raw_ratio = 0.0 then
    [("warning", `String "context_ratio is 0.0 - did you forget to provide it?")]
  else [] in
  json_ok (`Assoc ([
    ("phase", `String phase);
    ("should_prepare", `Bool should_prepare);
    ("should_handoff", `Bool should_handoff);
    ("context_ratio", `Float context_ratio);
    ("generation", `Int cell.Mitosis.generation);
  ] @ warning))

(* ================================================================ *)
(* Record — task/tool event                                          *)
(* ================================================================ *)

let handle_mitosis_record ctx args : result =
  let task_done = match Yojson.Safe.Util.member "task_done" args with
    | `Bool b -> b | _ -> true in
  let tool_called = match Yojson.Safe.Util.member "tool_called" args with
    | `Bool b -> b | _ -> false in
  let cell = current_cell () in
  let updated = Mitosis.record_activity ~cell ~task_done ~tool_called in
  Mcp_server.current_cell := updated;
  Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:updated ~config:Mitosis.default_config;
  json_ok (`Assoc [
    ("recorded", `Bool true);
    ("task_done", `Bool task_done);
    ("tool_called", `Bool tool_called);
    ("task_count", `Int updated.Mitosis.task_count);
    ("tool_call_count", `Int updated.Mitosis.tool_call_count);
  ])

(* ================================================================ *)
(* Prepare — Phase 1: extract DNA, mark ReadyForHandoff              *)
(* ================================================================ *)

let handle_mitosis_prepare ctx args : result =
  let full_context = get_string args "full_context" "" in
  let cell = current_cell () in
  if full_context = "" then
    json_err "full_context is required for DNA extraction"
  else begin
    let config = Mitosis.default_config in
    let prepared = Mitosis.prepare_for_division ~config ~cell ~full_context in
    Mcp_server.current_cell := prepared;
    Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:prepared ~config;
    json_ok (`Assoc [
      ("prepared", `Bool true);
      ("generation", `Int prepared.Mitosis.generation);
      ("phase", `String (Mitosis.phase_to_string prepared.Mitosis.phase));
      ("dna_length", `Int (String.length (Option.value ~default:"" prepared.Mitosis.prepared_dna)));
    ])
  end

(* ================================================================ *)
(* Divide — OAS-based agent spawn                                    *)
(* ================================================================ *)

(** Spawn a child agent via OAS Agent lifecycle.

    Uses [Oas_worker.run_with_masc_tools] to actually execute the child:
    1. Extract DNA from current context
    2. Run OAS Agent with DNA + current_task as goal and MASC tools
    3. Update cell state (increment generation)
    4. Return actual execution results *)
let handle_mitosis_divide ctx args : result =
  let summary = get_string args "summary" "" in
  let current_task = get_string args "current_task" "" in
  let target_agent = get_string args "target_agent" "claude" in
  match Mitosis_spawn.validate_target_agent_label target_agent with
  | Error msg -> json_err msg
  | Ok _normalized ->
  let cell = current_cell () in
  let config = Mitosis.default_config in
  let full_context =
    if current_task = "" then summary
    else Printf.sprintf "Summary: %s\n\nCurrent Task: %s" summary current_task
  in
  let dna = Mitosis.extract_dna ~config ~parent_cell:cell ~full_context in
  let next_gen = cell.Mitosis.generation + 1 in
  let system_prompt = Printf.sprintf
    "You are a continuation agent (generation %d). Previous context DNA:\n\n%s"
    next_gen dna
  in
  let goal =
    if current_task <> "" then
      Printf.sprintf "Continue from generation %d. Task: %s\n\nContext: %s"
        next_gen current_task summary
    else
      Printf.sprintf "Continue from generation %d. Context: %s" next_gen summary
  in
  let run_result =
    Oas_worker.run_named_with_masc_tools
      ~cascade_name:"mitosis" ~goal ~system_prompt
      ~masc_tools:ctx.masc_tools ~dispatch:ctx.dispatch ()
  in
  (* Update MASC L3 state regardless of run outcome *)
  let new_cell = Mitosis.create_stem_cell ~generation:next_gen in
  Mcp_server.current_cell := new_cell;
  Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:new_cell ~config;
  match run_result with
  | Error e ->
    json_err (Printf.sprintf "OAS child agent failed: %s" e)
  | Ok result ->
    let response_text = Cascade.text_of_response result.response in
    json_ok (`Assoc [
      ("divided", `Bool true);
      ("session_id", `String result.session_id);
      ("generation", `Int new_cell.Mitosis.generation);
      ("target_agent", `String target_agent);
      ("dna_length", `Int (String.length dna));
      ("turns", `Int result.turns);
      ("response", `String response_text);
      ("runtime", `String "oas");
    ])

(* ================================================================ *)
(* Handoff — OAS-based automated lifecycle transition                *)
(* ================================================================ *)

(** Automated 2-phase handoff via OAS Agent lifecycle.

    1. Check thresholds (prepare at 50%, handoff at 80%)
    2. If handoff needed: extract DNA, run successor via [Oas_worker.run_with_masc_tools]
    3. Return actual execution results *)
let handle_mitosis_handoff ctx args : result =
  let force = match Yojson.Safe.Util.member "force" args with
    | `Bool b -> b | _ -> false in
  let cell = current_cell () in
  let config_m = Mitosis.default_config in
  let raw_ratio = get_float args "context_ratio" 0.0 in
  let context_ratio = validate_context_ratio raw_ratio in
  let should = force || Mitosis.should_handoff ~config:config_m ~cell ~context_ratio in
  if not should then
    json_ok (`Assoc [
      ("action", `String "no_action");
      ("reason", `String "thresholds not met");
      ("context_ratio", `Float context_ratio);
    ])
  else begin
    (* Phase 1: Prepare DNA *)
    let summary = get_string args "summary"
      (Printf.sprintf "Auto-handoff at ratio %.1f%%" (context_ratio *. 100.0)) in
    let full_context = summary in
    let dna = Mitosis.extract_dna ~config:config_m ~parent_cell:cell ~full_context in
    let prepared_cell = Mitosis.prepare_for_division ~config:config_m ~cell ~full_context in
    Mcp_server.current_cell := prepared_cell;
    (* Phase 2: Run successor agent *)
    let target = get_string args "target_agent" "claude" in
    let next_gen = prepared_cell.Mitosis.generation + 1 in
    let system_prompt = Printf.sprintf
      "You are generation %d. Continue from this DNA:\n\n%s"
      next_gen dna
    in
    let goal = Printf.sprintf
      "You are the successor agent (generation %d). Resume work from the handoff DNA above. Context ratio was %.1f%%."
      next_gen (context_ratio *. 100.0)
    in
    let run_result =
      Oas_worker.run_named_with_masc_tools
        ~cascade_name:"mitosis" ~goal ~system_prompt
        ~masc_tools:ctx.masc_tools ~dispatch:ctx.dispatch ()
    in
    (* Update state regardless of run outcome *)
    let new_cell = Mitosis.create_stem_cell ~generation:next_gen in
    Mcp_server.current_cell := new_cell;
    Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:new_cell ~config:config_m;
    match run_result with
    | Error e ->
      json_ok (`Assoc [
        ("action", `String "handoff");
        ("generation", `Int new_cell.Mitosis.generation);
        ("dna_length", `Int (String.length dna));
        ("successor_ran", `Bool false);
        ("error", `String e);
        ("target_agent", `String target);
        ("runtime", `String "oas");
      ])
    | Ok result ->
      let response_text = Cascade.text_of_response result.response in
      json_ok (`Assoc [
        ("action", `String "handoff");
        ("generation", `Int new_cell.Mitosis.generation);
        ("dna_length", `Int (String.length dna));
        ("successor_ran", `Bool true);
        ("session_id", `String result.session_id);
        ("turns", `Int result.turns);
        ("response", `String response_text);
        ("target_agent", `String target);
        ("runtime", `String "oas");
      ])
  end

(* ================================================================ *)
(* Metrics handlers                                                  *)
(* ================================================================ *)

let handle_metrics_compare _ctx args : result =
  let gen_a = int_of_float (get_float args "gen_a" 0.0) in
  let gen_b = int_of_float (get_float args "gen_b" 1.0) in
  match Generational_metrics.compare_generations gen_a gen_b with
  | None -> json_err "Not enough data for comparison"
  | Some comp ->
    json_ok (`Assoc [
      ("gen_a", `Int comp.gen_a);
      ("gen_b", `Int comp.gen_b);
      ("completion_delta", `Float comp.completion_delta);
      ("error_delta", `Float comp.error_delta);
      ("duration_delta", `Float comp.duration_delta);
      ("token_delta", `Float comp.token_delta);
      ("retention_b", match comp.retention_b with Some r -> `Float r | None -> `Null);
      ("verdict", `String comp.verdict);
      ("formatted", `String (Generational_metrics.format_comparison comp));
    ])

let handle_metrics_record _ctx args : result =
  let task_id = get_string args "task_id"
    (Printf.sprintf "task-%d" (int_of_float (Time_compat.now () *. 1000.0) mod 100000)) in
  let completed = match Yojson.Safe.Util.member "completed" args with
    | `Bool b -> b | _ -> true in
  let duration_ms = int_of_float (get_float args "duration_ms" 0.0) in
  let error_count = int_of_float (get_float args "error_count" 0.0) in
  let input_tokens = int_of_float (get_float args "input_tokens" 0.0) in
  let output_tokens = int_of_float (get_float args "output_tokens" 0.0) in
  let cell = current_cell () in
  let record = Generational_metrics.record_task
    ~generation:cell.Mitosis.generation
    ~task_id ~completed ~duration_ms ~error_count
    ~input_tokens ~output_tokens
  in
  json_ok (`Assoc [
    ("recorded", `Bool true);
    ("generation", `Int record.Generational_metrics.generation);
    ("task_id", `String record.Generational_metrics.task_id);
    ("completed", `Bool record.Generational_metrics.completed);
  ])

(* ================================================================ *)
(* Schemas                                                           *)
(* ================================================================ *)

let schemas : Types.tool_schema list = Tool_mitosis.schemas

(* ================================================================ *)
(* Dispatch                                                          *)
(* ================================================================ *)

let dispatch (ctx : context) ~name ~args : result option =
  let handler = match name with
    | "masc_mitosis_status" -> Some handle_mitosis_status
    | "masc_mitosis_all" -> Some handle_mitosis_all
    | "masc_mitosis_pool" -> Some handle_mitosis_pool
    | "masc_mitosis_divide" -> Some handle_mitosis_divide
    | "masc_mitosis_check" -> Some handle_mitosis_check
    | "masc_mitosis_record" -> Some handle_mitosis_record
    | "masc_mitosis_prepare" -> Some handle_mitosis_prepare
    | "masc_mitosis_handoff" -> Some handle_mitosis_handoff
    | "masc_metrics_compare" -> Some handle_metrics_compare
    | "masc_metrics_record" -> Some handle_metrics_record
    | _ -> None
  in
  Option.map (fun h -> h ctx args) handler
