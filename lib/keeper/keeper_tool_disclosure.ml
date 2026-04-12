(** Keeper_tool_disclosure — tool selection, usage tracking, and response normalization.

    Extracted from keeper_agent_run.ml as part of #5732 god-module split.
    Contains helpers for tool usage snapshots, delta computation, response
    validation, query text extraction, and tool selection boundary merging. *)

let keeper_tool_usage_snapshot ~base_path ~keeper_name : (string * int) list =
  Keeper_registry.tool_usage_of ~base_path keeper_name
  |> List.map (fun (tool_name, entry) -> tool_name, entry.Keeper_types.count)
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
;;

let tool_usage_delta ~(before : (string * int) list) ~(after : (string * int) list)
  : string list
  =
  let before_counts = Hashtbl.create 16 in
  List.iter
    (fun (tool_name, count) -> Hashtbl.replace before_counts tool_name count)
    before;
  after
  |> List.concat_map (fun (tool_name, after_count) ->
    let before_count =
      Option.value ~default:0 (Hashtbl.find_opt before_counts tool_name)
    in
    List.init (max 0 (after_count - before_count)) (fun _ -> tool_name))
;;

let merge_reported_and_observed_tool_names
      ~(reported_tool_names : string list)
      ~(observed_tool_names : string list)
  : string list
  =
  match observed_tool_names with
  | [] -> reported_tool_names
  | _ ->
    let observed = Hashtbl.create 16 in
    List.iter (fun tool_name -> Hashtbl.replace observed tool_name ()) observed_tool_names;
    observed_tool_names
    @ List.filter
        (fun tool_name -> not (Hashtbl.mem observed tool_name))
        reported_tool_names
;;

type completion_contract =
  | Allow_text_or_tool
  | Require_tool_use

let completion_contract_of_tool_choice
      (tool_choice : Agent_sdk.Types.tool_choice option)
  : completion_contract
  =
  match tool_choice with
  | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) -> Require_tool_use
  | _ -> Allow_text_or_tool

let validate_completion_contract
      ~(contract : completion_contract)
      ~(tool_names : string list)
      ()
  : (unit, string) result
  =
  match contract with
  | Allow_text_or_tool -> Ok ()
  | Require_tool_use ->
    (match tool_names with
     | _ :: _ -> Ok ()
     | [] ->
       Error
         "keeper turn violated required tool contract: no tools were called")

let normalize_response_text ~(text : string) ~(tool_names : string list) ()
  : (string, string) result
  =
  let trimmed = String.trim text in
  if trimmed <> ""
  then Ok text
  else (
    match tool_names with
    | [] -> Error "keeper turn completed with no textual reply"
    | _ ->
      Ok
        (Printf.sprintf
           "Completed without a textual reply. Tools used: %s."
           (String.concat ", " tool_names)))
;;

let tool_query_text_of_user_message (text : string) : string =
  let allowed_sections =
    [ "### Pending Mentions"
    ; "### Scope Messages"
    ; "### Active Goals"
    ; "### Namespace State"
    ; "### Board Activity"
    ; "### Actionable Routes"
    ; "### Live Worktree Delta"
    ]
  in
  let is_allowed_section section =
    List.exists
      (fun allowed -> String.starts_with ~prefix:allowed section)
      allowed_sections
  in
  let lines = String.split_on_char '\n' text in
  let rec loop current_section kept = function
    | [] ->
      let filtered = List.rev kept |> String.concat "\n" |> String.trim in
      if filtered <> "" then filtered else String.trim text
    | line :: rest ->
      let trimmed = String.trim line in
      let current_section =
        if String.starts_with ~prefix:"### " trimmed
        then Some trimmed
        else current_section
      in
      let keep_line =
        match current_section with
        | None -> String.starts_with ~prefix:"## Current World State" trimmed
        | Some section -> is_allowed_section section
      in
      if keep_line
      then loop current_section (line :: kept) rest
      else loop current_section kept rest
  in
  loop None [] lines
;;

let deterministic_prefilter_names
    ~(search_index : Agent_sdk.Tool_index.t)
    ~(query_text : string)
    ~(selection_limit : int)
    ~(core : string list) : string list =
  if selection_limit <= 0 then []
  else
    Agent_sdk.Tool_index.retrieve search_index query_text
    |> List.filter_map (fun (name, _) ->
         if List.mem name core then None else Some name)
    |> List.filteri (fun i _ -> i < selection_limit)
;;

let latest_tool_name (entries : Yojson.Safe.t list) : string option =
  entries
  |> List.rev
  |> List.find_map (Safe_ops.json_string_opt "tool")
;;

let prune_boring_tools_after_recent_polling
    ~(visible_tools : string list)
    ~(recent_entries : Yojson.Safe.t list) : string list =
  let productive_visible =
    List.exists
      (fun name -> not (Keeper_tool_registry.is_boring_tool name))
      visible_tools
  in
  let just_polled =
    match latest_tool_name recent_entries with
    | Some name ->
      Keeper_tool_registry.is_boring_tool name
      && not (String.equal name "keeper_stay_silent")
    | None -> false
  in
  if not just_polled then visible_tools
  else if not productive_visible then
    (* All visible tools are boring and we just used one — force silent
       to break the polling loop instead of offering the same boring tools. *)
    List.filter (fun name -> String.equal name "keeper_stay_silent") visible_tools
  else
    List.filter
      (fun name ->
         not (Keeper_tool_registry.is_boring_tool name)
         || String.equal name "keeper_stay_silent")
      visible_tools
;;

let merge_tool_selection_boundary
    ~(core : string list)
    ~(deterministic_prefilter : string list)
    ~(llm_selected : string list)
    ~(discovered : string list) : string list =
  let sorted_discovered = List.sort String.compare discovered in
  let deterministic_floor =
    Keeper_types.dedupe_keep_order
      (core @ deterministic_prefilter @ sorted_discovered)
  in
  Keeper_types.dedupe_keep_order (deterministic_floor @ llm_selected)
