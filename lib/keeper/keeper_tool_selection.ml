(** Keeper_tool_selection - deterministic keeper tool-surface selection. *)

let allow_deterministic_tool ~(query_text : string) (name : string) : bool =
  let query = String.lowercase_ascii query_text in
  let contains needle =
    let needle = String.lowercase_ascii needle in
    let needle_len = String.length needle in
    let query_len = String.length query in
    let rec loop i =
      if i + needle_len > query_len
      then false
      else if String.sub query i needle_len = needle
      then true
      else loop (i + 1)
    in
    needle_len = 0 || loop 0
  in
  let source_path_hint =
    (contains "/" || contains "\\") && (contains ".ml" || contains ".mli" || contains ".")
  in
  let source_subject =
    contains "source"
    || contains "code"
    || contains "repo"
    || contains "repository"
    || contains "function"
    || contains "symbol"
    || contains "class"
    || source_path_hint
  in
  let source_read_intent = (contains "read" || contains "open") && source_subject in
  let source_navigation_intent =
    source_subject
    && (contains "search"
        || contains "find"
        || contains "show"
        || contains "list"
        || contains "grep"
        || contains "symbol"
        || contains "function")
  in
  match Keeper_tool_resolution.canonical_tool_name name with
  | "tool_read_file" -> source_read_intent
  | "tool_search_files" -> source_navigation_intent
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
  else (
    let tool_available name =
      Agent_sdk.Tool_index.retrieve search_index name
      |> List.exists (fun (found, _) -> String.equal found name)
    in
    let preferred_source_tools =
      [ (allow_deterministic_tool ~query_text "tool_read_file", [ "tool_read_file"; "ReadFile" ])
      ; ( allow_deterministic_tool ~query_text "tool_search_files"
        , [ "tool_search_files"; "SearchFiles" ] )
      ]
      |> List.concat_map (fun (enabled, names) ->
        if enabled
        then List.filter (fun name -> (not (List.mem name core)) && tool_available name) names
        else [])
    in
    let retrieved =
      Agent_sdk.Tool_index.retrieve search_index query_text
      |> List.filter_map (fun (name, _) ->
      if List.mem name core
      then None
      else if not (allow_deterministic_tool ~query_text name)
      then None
      else Some name)
    in
    Keeper_types.dedupe_keep_order (preferred_source_tools @ retrieved)
    |> List.filteri (fun i _ -> i < selection_limit)
  )
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
    let preserved, _removed =
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
