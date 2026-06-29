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
  [ Keeper_tool_name.(to_string Board_post)
  ; Keeper_tool_name.(to_string Board_comment)
  ; "masc_broadcast"
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
  | Error _ -> []
  | Ok (Keeper_tool_execute_typed_input.Exec { executable; argv; _ }) ->
    command_of_exec_stage ~executable ~argv |> Option.to_list
  | Ok (Keeper_tool_execute_typed_input.Pipeline { stages; _ }) ->
    let commands =
      stages
      |> List.filter_map (fun { Keeper_tool_execute_typed_input.executable; argv } ->
           command_of_exec_stage ~executable ~argv)
    in
    (match commands with
     | [] -> []
     | _ -> [ String.concat " | " commands ])
;;

let shell_command_input_candidates tool_name input =
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
      List.fold_left
        (fun acc command -> add_candidate (Some command) acc)
        candidates
        (typed_execute_command_candidates input)
    | _ -> []
  else []
;;
