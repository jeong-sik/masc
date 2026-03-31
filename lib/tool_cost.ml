(** Tool_cost - Cost tracking and reporting handlers *)

open Tool_args

type context = {
  agent_name: string;
}

(* Safe exec helper - runs CLI command and returns result (Eio-native) *)
let safe_exec args =
  match Process_eio.run_argv_with_status ~timeout_sec:60.0 args with
  | Unix.WEXITED 0, output -> (true, output)
  | _, output -> (false, if output = "" then "❌ Command failed" else output)

(* Handle masc_cost_log *)
let handle_cost_log ctx args =
  let model = get_string args "model" "unknown" in
  let input_tokens = get_int args "input_tokens" 0 in
  let output_tokens = get_int args "output_tokens" 0 in
  let cost_usd = get_float args "cost_usd" 0.0 in
  let task_id = get_string args "task_id" "" in
  let base_args = ["masc-cost"; "--log"; "--agent"; ctx.agent_name; "--model"; model;
                   "--input-tokens"; string_of_int input_tokens;
                   "--output-tokens"; string_of_int output_tokens;
                   "--cost"; Printf.sprintf "%.4f" cost_usd] in
  let cli_args = if task_id = "" then base_args else base_args @ ["--task"; task_id] in
  safe_exec cli_args

(* Handle masc_cost_report *)
let handle_cost_report _ctx args =
  let period = get_string args "period" "daily" in
  let agent = get_string args "agent" "" in
  let task_id = get_string args "task_id" "" in
  let base_args = ["masc-cost"; "--report"; "--period"; period; "--json"] in
  let cli_args = base_args
                 |> (fun a -> if agent = "" then a else a @ ["--agent"; agent])
                 |> (fun a -> if task_id = "" then a else a @ ["--task"; task_id]) in
  safe_exec cli_args

let schemas : Types.tool_schema list = [
  {
    name = "masc_cost_log";
    description = "Log token usage and cost for tracking multi-agent expenses. Call after significant API calls to track spending per agent and task.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name (claude, gemini, codex)");
        ]);
        ("model", `Assoc [
          ("type", `String "string");
          ("description", `String "Model name (e.g., opus, sonnet, pro, flash)");
        ]);
        ("input_tokens", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of input tokens");
        ]);
        ("output_tokens", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of output tokens");
        ]);
        ("cost_usd", `Assoc [
          ("type", `String "number");
          ("description", `String "Estimated cost in USD");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional task ID for attribution");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "cost_usd"]);
    ];
  };
  {
    name = "masc_cost_report";
    description = "Get cost report showing token usage and spending by agent. Use to monitor multi-agent collaboration expenses.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("period", `Assoc [
          ("type", `String "string");
          ("description", `String "Time period: hourly, daily, weekly, monthly, all");
          ("default", `String "daily");
        ]);
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by agent name (optional)");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by task ID (optional)");
        ]);
      ]);
    ];
  };
]

(* Dispatch handler *)
let dispatch ctx ~name ~args =
  match name with
  | "masc_cost_log" -> Some (handle_cost_log ctx args)
  | "masc_cost_report" -> Some (handle_cost_report ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_cost
           ~input_schema:s.input_schema
           ()))
    schemas
