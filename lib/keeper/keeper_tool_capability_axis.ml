(** Keeper_tool_capability_axis -- semantic capability classification for tool names.

    Callers may pass public aliases ([Execute], [Write], ...), public MCP
    names, prefixed MCP names, or internal handler names. This module
    normalizes names through descriptor resolution before answering capability
    predicates. *)

type t =
  | Claim_task
  | Board_activity
  | Shell_command_input
  | Polling_read

type command_candidate_error =
  | Tool_execute_input_parse_error of string

let command_candidate_error_label = function
  | Tool_execute_input_parse_error _ -> "typed_input_parse"
;;

let command_candidate_error_to_string = function
  | Tool_execute_input_parse_error detail ->
    Printf.sprintf "tool_execute typed input parse failed: %s" detail
;;

let canonical_tool_name name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  match Keeper_tool_descriptor_resolution.canonical_internal_name_for_tool_name name with
  | Some internal -> internal
  | None -> stripped
;;

let candidate_names name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  let canonical = canonical_tool_name name in
  if String.equal stripped canonical then [ canonical ] else [ canonical; stripped ]
;;

let claim_task_tool_names =
  [ Keeper_tool_name.(to_string Task_claim) ]
;;

let board_activity_tool_names =
  (* #22042 / RFC-0299 Phase 4 — canonical-form membership.

     [supports]/[candidate_names] canonicalize the *incoming* name before
     [List.mem], so every entry here must be a canonical form the runtime can
     actually present. [broadcast] has an asymmetric registration: the
     descriptor (keeper.task.broadcast) carries the internal name
     "keeper_broadcast", while "masc_broadcast" is a
     [public_mcp_non_descriptor_name] (routing_table miss -> known_runtime
     identity, stays unchanged). The two representations therefore canonicalize
     to two different strings, so both must be listed or the internal form
     classifies as Passive_status and silently resets the RFC-0239 anti-thrash
     streak. [keeper_msg] is symmetric (public_name = internal_name =
     "masc_keeper_msg" via [masc_keeper_descriptor]) so its single entry
     already covers every representation. *)
  [ Keeper_tool_name.(to_string Board_post)
  ; Keeper_tool_name.(to_string Board_comment)
  ; Keeper_tool_name.(to_string Broadcast) (* internal canonical = "keeper_broadcast" *)
  ; "masc_broadcast" (* non-descriptor public form; canonicalizes to itself *)
  ; "masc_keeper_msg"
  ]
;;

let shell_command_input_tool_names =
  [ "tool_execute" ]
;;

let polling_read_tool_names =
  Keeper_tool_descriptor.polling_read_internal_names ()
;;

let tool_names = function
  | Claim_task -> claim_task_tool_names
  | Board_activity -> board_activity_tool_names
  | Shell_command_input -> shell_command_input_tool_names
  | Polling_read -> polling_read_tool_names
;;

let supports capability name =
  let supported = tool_names capability in
  candidate_names name |> List.exists (fun candidate -> List.mem candidate supported)
;;

let supports_any capability names =
  List.exists (supports capability) names
;;


let shell_quote_token token =
  let needs_quote =
    String.equal token ""
    || String.exists
         (function
           | ' ' | '\t' | '\n' | '\r' | '\'' | '"' | '\\' | '$' | '`' | '|'
           | '&' | ';' | '<' | '>' | '(' | ')' -> true
           | _ -> false)
         token
  in
  if not needs_quote
  then token
  else
    "'"
    ^ (String.split_on_char '\'' token |> String.concat "'\"'\"'")
    ^ "'"
;;

let command_of_exec_stage ~executable ~argv =
  let executable = String.trim executable in
  if String.equal executable ""
  then None
  else
    Some (String.concat " " (List.map shell_quote_token (executable :: argv)))
;;

let typed_execute_command_candidates input =
  match Keeper_tool_execute_typed_input.of_json input with
  | Error error -> Error (Tool_execute_input_parse_error error)
  | Ok (Keeper_tool_execute_typed_input.Exec { executable; argv; _ }) ->
    Ok (command_of_exec_stage ~executable ~argv |> Option.to_list)
  | Ok (Keeper_tool_execute_typed_input.Pipeline { stages; _ }) ->
    let commands =
      stages
      |> List.filter_map (fun { Keeper_tool_execute_typed_input.executable; argv } ->
           command_of_exec_stage ~executable ~argv)
    in
    (match commands with
     | [] -> Ok []
     | _ -> Ok [ String.concat " | " commands ])
;;

let shell_command_input_candidates_result tool_name input =
  let add_candidate candidate acc =
    match candidate with
    | None -> acc
    | Some value ->
      let command = String.trim value in
      if String.equal command "" || List.mem command acc then acc else acc @ [ command ]
  in
  if supports Shell_command_input tool_name
  then
    match canonical_tool_name tool_name with
    | "tool_execute" ->
      let candidates = [] |> add_candidate (Json_util.get_string input "cmd") in
      (match typed_execute_command_candidates input with
       | Ok commands ->
         Ok
           (List.fold_left
              (fun acc command -> add_candidate (Some command) acc)
              candidates
              commands)
       | Error _ as error -> error)
    | _ -> Ok []
  else Ok []
;;

let observe_command_candidate_error ~tool_name error =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ToolExecuteFailures)
    ~labels:
      [ "tool", tool_name
      ; "site", "capability_axis"
      ; "reason", command_candidate_error_label error
      ]
    ();
  Log.Keeper.warn
    "tool capability-axis command candidate parse failed: tool=%s reason=%s detail=%s"
    tool_name
    (command_candidate_error_label error)
    (command_candidate_error_to_string error)
;;

let shell_command_input_candidates tool_name input =
  match shell_command_input_candidates_result tool_name input with
  | Ok candidates -> candidates
  | Error error ->
    observe_command_candidate_error ~tool_name error;
    []
;;
