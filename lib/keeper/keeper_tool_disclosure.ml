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

let merge_observed_tool_names
      ~(registry_observed_tool_names : string list)
      ~(hook_observed_tool_names : string list)
  : string list
  =
  let hook_counts = Hashtbl.create 16 in
  List.iter
    (fun tool_name ->
       let count = Option.value ~default:0 (Hashtbl.find_opt hook_counts tool_name) in
       Hashtbl.replace hook_counts tool_name (count + 1))
    hook_observed_tool_names;
  let emitted_extra = Hashtbl.create 16 in
  hook_observed_tool_names
  @ List.filter
      (fun tool_name ->
         let hook_count =
           Option.value ~default:0 (Hashtbl.find_opt hook_counts tool_name)
         in
         let already_emitted =
           Option.value ~default:0 (Hashtbl.find_opt emitted_extra tool_name)
         in
         if already_emitted < hook_count
         then (
           Hashtbl.replace emitted_extra tool_name (already_emitted + 1);
           false)
         else true)
      registry_observed_tool_names
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

let final_keeper_tool_names
      ~(reported_tool_names : string list)
      ~(observed_tool_names : string list)
      ~(allowed_tool_names : string list)
  : string list
  =
  let allowed_tool_names =
    allowed_tool_names |> List.map Keeper_tool_resolution.canonical_tool_name |> Keeper_types.dedupe_keep_order
  in
  let allowed = Hashtbl.create (List.length allowed_tool_names) in
  List.iter (fun tool_name -> Hashtbl.replace allowed tool_name ()) allowed_tool_names;
  let reported_tool_names = List.map Keeper_tool_resolution.canonical_tool_name reported_tool_names in
  let observed_tool_names = List.map Keeper_tool_resolution.canonical_tool_name observed_tool_names in
  let tool_names =
    match observed_tool_names with
    | [] -> reported_tool_names
    | _ :: _ ->
      let observed = Hashtbl.create (List.length observed_tool_names) in
      List.iter
        (fun tool_name -> Hashtbl.replace observed tool_name ())
        observed_tool_names;
      observed_tool_names
      @ List.filter
          (fun tool_name -> not (Hashtbl.mem observed tool_name))
          reported_tool_names
  in
  tool_names
  |> List.filter (fun tool_name -> Hashtbl.mem allowed tool_name)
;;

let result_text_for_progress_check output_text =
  match Tool_output.decode_from_oas output_text with
  | Tool_output.Stored { preview; _ } -> preview
  | Tool_output.Inline value -> value
;;

let tool_result_has_material_progress ~(tool_name : string) ~(output_text : string)
  : bool
  =
  let tool_name = Keeper_tool_resolution.canonical_tool_name tool_name in
  let output_text = result_text_for_progress_check output_text |> String.trim in
  not
    (String.equal tool_name "masc_worktree_create"
     && String.starts_with ~prefix:"Worktree already exists:" output_text)
;;

let unexpected_tool_names ~(allowed_tool_names : string list) ~(tool_names : string list)
  : string list
  =
  let allowed_tool_names =
    allowed_tool_names |> List.map Keeper_tool_resolution.canonical_tool_name |> Keeper_types.dedupe_keep_order
  in
  let allowed = Hashtbl.create (List.length allowed_tool_names) in
  let seen = Hashtbl.create (List.length tool_names) in
  List.iter
    (fun tool_name -> Hashtbl.replace allowed (Keeper_tool_resolution.canonical_tool_name tool_name) ())
    allowed_tool_names;
  tool_names
  |> List.filter (fun tool_name ->
    let canonical = Keeper_tool_resolution.canonical_tool_name tool_name in
    if Hashtbl.mem allowed canonical || Hashtbl.mem seen canonical
    then false
    else (
      Hashtbl.replace seen canonical ();
      true))
;;

(** [has_valid_tool_call ~unexpected_tool_names ~tool_names] returns
    true iff at least one name in [tool_names] is absent from
    [unexpected_tool_names] — i.e. at least one call is on the keeper
    surface. Used by [Keeper_agent_run] (#8471) to decide whether a
    turn mixing unknown tools with valid ones should hard-fail or
    continue with a partial-tolerance WARN. *)
let has_valid_tool_call ~(unexpected_tool_names : string list) ~(tool_names : string list)
  : bool
  =
  let unexpected = Hashtbl.create (List.length unexpected_tool_names) in
  List.iter (fun n -> Hashtbl.replace unexpected n ()) unexpected_tool_names;
  List.exists (fun n -> not (Hashtbl.mem unexpected n)) tool_names
;;

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

let response_has_text_or_tool_progress (response : Agent_sdk.Types.api_response) =
  let text = Agent_sdk.Types.text_of_content response.content |> String.trim in
  text <> ""
  || List.exists
       (function
         | Agent_sdk.Types.ToolUse _ -> true
         | Agent_sdk.Types.Text _
         | Agent_sdk.Types.Thinking _
         | Agent_sdk.Types.RedactedThinking _
         | Agent_sdk.Types.ToolResult _
         | Agent_sdk.Types.Image _
         | Agent_sdk.Types.Document _
         | Agent_sdk.Types.Audio _ -> false)
       response.content
  || response.stop_reason <> Agent_sdk.Types.EndTurn
;;

let tool_query_text_of_user_message (text : string) : string =
  let allowed_sections =
    [ "### Pending Mentions"
    ; "### Scope Messages"
    ; "### Active Goals"
    ; "### Namespace State"
    ; "### Board Activity"
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

include Keeper_tool_code_intent
let allow_deterministic_tool ~(query_text : string) (name : string) : bool =
  match name with
  | "masc_code_search" -> query_requests_code_search query_text
  | "masc_code_read" -> query_requests_code_read query_text
  | "masc_code_symbols" -> query_requests_code_symbols query_text
  | _ -> true
;;

let deterministic_prefilter_names
      ~(search_index : Agent_sdk.Tool_index.t)
      ~(query_text : string)
      ~(selection_limit : int)
      ~(core : string list)
  : string list
  =
  if selection_limit <= 0
  then []
  else
    Agent_sdk.Tool_index.retrieve search_index query_text
    |> List.filter_map (fun (name, _) ->
      if List.mem name core
      then None
      else if not (allow_deterministic_tool ~query_text name)
      then None
      else Some name)
    |> List.filteri (fun i _ -> i < selection_limit)
;;

let merge_tool_selection_boundary
      ~(core : string list)
      ~(deterministic_prefilter : string list)
      ~(llm_selected : string list)
      ~(discovered : string list)
  : string list
  =
  let sorted_discovered = List.sort String.compare discovered in
  (* BM25-relevant tools first: when downstream truncation caps at
     max_tools, the tail is dropped.  Placing deterministic_prefilter
     and discovered before core ensures context-relevant tools survive
     while generic core tools are truncated first.
     Core tools that also appear in deterministic_prefilter are deduped
     (first occurrence wins), so they naturally keep their BM25 rank. *)
  let deterministic_floor =
    Keeper_types.dedupe_keep_order (deterministic_prefilter @ sorted_discovered @ core)
  in
  Keeper_types.dedupe_keep_order (deterministic_floor @ llm_selected)
;;

let contract_enforcement_filter
      ~(passive_streak : int)
      ~(streak_threshold : int)
      ~(actionable_signal : bool)
      (tool_names : string list)
  : string list
  =
  if passive_streak < streak_threshold || not actionable_signal
  then tool_names
  else (
    let preserved, removed =
      List.partition
        (fun name ->
           match Keeper_tool_progress.classify_tool_progress name with
           | Keeper_tool_progress.Passive_status -> false
           | Keeper_tool_progress.Claim_context
           | Keeper_tool_progress.Execution
           | Keeper_tool_progress.Completion -> true)
        tool_names
    in
    (* stay_silent is Completion-class, already in [preserved].
       This filter removes only Passive_status tools (ReadFile, SearchFiles, List, etc.)
       that contribute nothing to owned tasks during streaks. *)
    preserved)
;;
