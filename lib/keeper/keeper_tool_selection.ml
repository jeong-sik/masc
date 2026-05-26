(** Keeper_tool_selection - deterministic keeper tool-surface selection. *)

let allow_deterministic_tool ~(query_text : string) (name : string) : bool =
  match name with
  | "masc_code_search" -> Keeper_tool_code_intent.query_requests_code_search query_text
  | "masc_code_read" -> Keeper_tool_code_intent.query_requests_code_read query_text
  | "masc_code_symbols" -> Keeper_tool_code_intent.query_requests_code_symbols query_text
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
