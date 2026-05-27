(** Keeper_tool_capability_axis -- semantic capability classification for tool names.

    Callers may pass public aliases ([Execute], [WriteFile], ...), public MCP
    names, prefixed MCP names, or internal handler names. This module
    normalizes names through descriptor resolution before answering capability
    predicates. *)

type t =
  | Claim_task
  | Board_activity
  | Pr_work_action
  | Pr_work_shell_command
  | Pr_work_git_action
  | Docker_route_pr_work_action

let keeper_name (tool : Tool_name.Keeper.t) =
  Tool_name.to_string (Tool_name.Keeper tool)
;;

let masc_name (tool : Tool_name.Masc.t) =
  Tool_name.to_string (Tool_name.Masc tool)
;;

let masc_keeper_name (tool : Tool_name.Masc_keeper.t) =
  Tool_name.to_string (Tool_name.Masc_keeper tool)
;;

let canonical_tool_name name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  match Agent_tool_descriptor_resolution.canonical_internal_name_for_tool_name name with
  | Some internal -> internal
  | None -> stripped
;;

let candidate_names name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  let canonical = canonical_tool_name name in
  if String.equal stripped canonical then [ canonical ] else [ canonical; stripped ]
;;

let claim_task_tool_names =
  [ keeper_name Tool_name.Keeper.Task_claim; masc_name Tool_name.Masc.Claim_next ]
;;

let board_activity_tool_names =
  [ keeper_name Tool_name.Keeper.Board_post
  ; keeper_name Tool_name.Keeper.Board_comment
  ; masc_name Tool_name.Masc.Broadcast
  ; masc_keeper_name Tool_name.Masc_keeper.Msg
  ]
;;

let pr_work_shell_command_tool_names =
  [ keeper_name Tool_name.Keeper.Execute ]
;;

let pr_work_git_action_tool_names = [ keeper_name Tool_name.Keeper.Execute ]

let tool_names = function
  | Claim_task -> claim_task_tool_names
  | Board_activity -> board_activity_tool_names
  | Pr_work_shell_command -> pr_work_shell_command_tool_names
  | Pr_work_git_action -> pr_work_git_action_tool_names
  | Pr_work_action | Docker_route_pr_work_action ->
    pr_work_git_action_tool_names @ pr_work_shell_command_tool_names
;;

let supports capability name =
  let supported = tool_names capability in
  candidate_names name |> List.exists (fun candidate -> List.mem candidate supported)
;;

let supports_any capability names =
  List.exists (supports capability) names
;;

let json_string_opt key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Some value
     | Some _ | None -> None)
  | _ -> None
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
  match Agent_tool_execute_typed_input.of_json input with
  | Error _ -> []
  | Ok (Agent_tool_execute_typed_input.Exec { executable; argv; _ }) ->
    command_of_exec_stage ~executable ~argv |> Option.to_list
  | Ok (Agent_tool_execute_typed_input.Pipeline { stages; _ }) ->
    let commands =
      stages
      |> List.filter_map (fun { Agent_tool_execute_typed_input.executable; argv } ->
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
  if supports Pr_work_shell_command tool_name
  then
    match canonical_tool_name tool_name with
    | "tool_execute" ->
      let candidates = [] |> add_candidate (json_string_opt "cmd" input) in
      List.fold_left
        (fun acc command -> add_candidate (Some command) acc)
        candidates
        (typed_execute_command_candidates input)
    | _ -> []
  else []
;;
