(** Tool_misc - Miscellaneous operations

    Handles: dashboard, verify_handoff, gc, cleanup_zombies
*)

open Tool_args

type result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
}

(* Handlers *)

let handle_dashboard ctx args =
  let compact = get_bool args "compact" false in
  let scope_arg = String.lowercase_ascii (get_string args "scope" "all") in
  let scope =
    match scope_arg with
    | "all" -> Ok Dashboard.All
    | "current" -> Ok Dashboard.Current
    | other -> Error other
  in
  match scope with
  | Error other ->
      (false, Printf.sprintf "❌ Invalid dashboard scope '%s' (expected: all | current)" other)
  | Ok scope ->
      let output =
        if compact then Dashboard.generate_compact ~scope ctx.config
        else Dashboard.generate ~scope ctx.config
      in
      (true, output)

let handle_verify_handoff _ctx args =
  let original = get_string args "original" "" in
  let received = get_string args "received" "" in
  if original = "" || received = "" then
    (false, "❌ original and received are required")
  else
    let threshold =
      get_float args "threshold" (Level2_config.Drift_guard.default_threshold ())
    in
    let result =
      Drift_guard.verify_handoff ~original ~received ~threshold ()
      |> Drift_guard.result_to_json
    in
    (true, Yojson.Safe.pretty_to_string result)

let handle_gc ctx args =
  let days = get_int args "days" 7 in
  (true, Room.gc ctx.config ~days ())

let handle_cleanup_zombies ctx _args =
  (true, Room.cleanup_zombies ctx.config)

let handle_tool_stats _ctx args =
  let top_n = max 1 (min 100 (get_int args "top_n" 20)) in
  let all_tool_names =
    List.map (fun (s : Types.tool_schema) -> s.name)
      Config.all_tool_schemas
  in
  let report = Tool_registry.stats_report ~top_n ~all_tool_names in
  (true, Yojson.Safe.pretty_to_string report)

let handle_tool_help _ctx args =
  let tool_name = String.trim (get_string args "tool_name" "") in
  if tool_name = "" then
    (false, "❌ tool_name is required")
  else
    match Tool_help_registry.find_entry Config.raw_all_tool_schemas tool_name with
    | None -> (false, Printf.sprintf "❌ unknown tool: %s" tool_name)
    | Some entry ->
        (true, Yojson.Safe.pretty_to_string (Tool_help_registry.entry_json entry))

(* Dispatch function *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_dashboard" -> Some (handle_dashboard ctx args)
  | "masc_verify_handoff" -> Some (handle_verify_handoff ctx args)
  | "masc_gc" -> Some (handle_gc ctx args)
  | "masc_cleanup_zombies" -> Some (handle_cleanup_zombies ctx args)
  | "masc_tool_stats" -> Some (handle_tool_stats ctx args)
  | "masc_tool_help" -> Some (handle_tool_help ctx args)
  | _ -> None
