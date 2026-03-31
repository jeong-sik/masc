(** Tempo Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    5 tools: tempo, tempo_get, tempo_set, tempo_adjust, tempo_reset
*)

open Tool_args

(** Tool handler context *)
type context = {
  config: Room.config;
  agent_name: string;
}

(** Tool result type *)
type result = bool * string

(** {1 Individual Handlers} *)

let handle_tempo_get ctx _args : result =
  let state = Tempo.get_tempo ctx.config in
  (true, Yojson.Safe.pretty_to_string (Tempo.state_to_json state))

let handle_tempo_set ctx args : result =
  let interval = get_float args "interval_seconds" 0.0 in
  let reason = get_string args "reason" "manual" in
  if interval <= 0.0 then
    (false, "❌ interval_seconds must be > 0")
  else
    let state = Tempo.set_tempo ctx.config ~interval_s:interval ~reason in
    (true, Yojson.Safe.pretty_to_string (Tempo.state_to_json state))

let handle_tempo_adjust ctx _args : result =
  let state = Tempo.adjust_tempo ctx.config in
  (true, Yojson.Safe.pretty_to_string (Tempo.state_to_json state))

let handle_tempo_reset ctx _args : result =
  let state = Tempo.reset_tempo ctx.config in
  (true, Yojson.Safe.pretty_to_string (Tempo.state_to_json state))

let handle_tempo ctx args : result =
  let action = get_string args "action" "get" in
  match action with
  | "get" ->
      let json = Room.get_tempo ctx.config in
      (true, Yojson.Safe.pretty_to_string json)
  | "set" ->
      let mode = get_string args "mode" "normal" in
      let reason = get_string_opt args "reason" in
      (true, Room.set_tempo ctx.config ~mode ~reason ~agent_name:ctx.agent_name)
  | _ ->
      (false, "❌ Unknown action. Use 'get' or 'set'")

let schemas : Types.tool_schema list = [
  {
    name = "masc_tempo_reset";
    description = "Reset room tempo to default 300s (5 minutes). \
Tempo controls SSE heartbeat interval and agent timeout detection. \
Use after: intensive work phase complete, debugging tempo issues. \
Lower tempo = faster detection but more overhead. Default balances both. \
Example: masc_tempo_reset() → {tempo: 300, message: 'Reset to default'}";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_tempo_get *)
  {
    name = "masc_tempo_get";
    description = "Read the current orchestrator check interval and adaptive tempo status. \
Use when checking how frequently the orchestrator polls before adjusting tempo. \
Pair with masc_tempo_set to change interval or masc_tempo_adjust for auto-tuning.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_tempo_set *)
  {
    name = "masc_tempo_set";
    description = "Set the orchestrator check interval manually (clamped 60s-600s). \
Use when you need a specific polling frequency for intensive or idle work phases. \
Check current value with masc_tempo_get first. Use masc_tempo_reset to return to default 300s.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("interval_seconds", `Assoc [
          ("type", `String "number");
          ("description", `String "Check interval in seconds (60-600)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for tempo change");
        ]);
      ]);
      ("required", `List [`String "interval_seconds"]);
    ];
  };

  (* masc_tempo_adjust *)
  {
    name = "masc_tempo_adjust";
    description = "Auto-tune orchestrator tempo based on pending task urgency: fast for urgent, slow when idle. \
Call when you want the system to pick the right interval without manual calculation. \
Pair with masc_tempo_get to see the resulting interval after adjustment.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_tempo *)
  {
    name = "masc_tempo";
    description = "Read or change cluster-wide tempo (pace) in one call: get current or set normal/slow/fast/paused. \
Use when switching between careful review (slow) and batch processing (fast). \
For finer control, use masc_tempo_set (exact interval) or masc_tempo_adjust (auto-tune).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "get"; `String "set"]);
          ("description", `String "Get current tempo or set new tempo");
        ]);
        ("mode", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "normal"; `String "slow"; `String "fast"; `String "paused"]);
          ("description", `String "Tempo mode (only for set action)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Why changing tempo");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };

]

(** {1 Dispatcher} *)

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_tempo_get" -> Some (handle_tempo_get ctx args)
  | "masc_tempo_set" -> Some (handle_tempo_set ctx args)
  | "masc_tempo_adjust" -> Some (handle_tempo_adjust ctx args)
  | "masc_tempo_reset" -> Some (handle_tempo_reset ctx args)
  | "masc_tempo" -> Some (handle_tempo ctx args)
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
           ~module_tag:Tool_dispatch.Mod_tempo
           ~input_schema:s.input_schema
           ()))
    schemas
