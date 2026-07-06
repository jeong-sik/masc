(** Idle-loop decision helpers for [Keeper_hooks_oas]. *)

open Keeper_hooks_oas_types

(** Suggest alternative tools from the keeper's allowed set that were
    NOT part of the repeated tool calls. Returns up to [max_suggestions]
    tool names, deterministically selected from the allowed set.
    This is the deterministic envelope: gathering candidates from a
    known set. The LLM (non-deterministic) decides which to use. *)
let suggest_alternatives ~(allowed_tools : string list)
    ~(repeated_tools : string list) ~(max_suggestions : int) : string list =
  let module SS = Set_util.StringSet in
  let repeated_set =
    List.fold_left (fun acc t -> SS.add t acc) SS.empty repeated_tools
  in
  allowed_tools
  |> List.filter (fun t -> not (SS.mem t repeated_set))
  |> fun candidates ->
     let len = List.length candidates in
     if len <= max_suggestions then candidates
     else List.filteri (fun i _ -> i < max_suggestions) candidates
  |> schema_visible_keep_order

let includes_tool name tools = List.exists (String.equal name) tools

let schema_visible_name name =
  match Keeper_tool_visibility_projection.public_alias_for_internal name with
  | Some public_name -> public_name
  | None -> name

let schema_visible_keep_order names =
  names
  |> List.map schema_visible_name
  |> Keeper_types_profile_toml_normalizers.dedupe_keep_order

let allowed_visible_candidates candidates ~allowed_tools =
  candidates
  |> List.filter (fun name -> includes_tool name allowed_tools)
  |> schema_visible_keep_order

let recovery_hint ~allowed_tools ~tool_names =
  if includes_tool "keeper_tool_search" tool_names then
    Some
      (let code_search =
         allowed_visible_candidates
           [ "Grep"; "tool_search_files"; "Read"; "tool_read_file"; "Execute"; "tool_execute" ]
           ~allowed_tools
       in
       let next =
         match code_search with
         | [] -> "Use a visible file/content search tool if one is active."
         | names ->
           Printf.sprintf
             "For source files, functions, types, or symbols, switch to %s."
             (String.concat " then " names)
       in
       "keeper_tool_search discovers active tool schemas only; it does not search \
        repository files, definitions, functions, types, or symbols. " ^ next)
  else if includes_tool "keeper_tools_list" tool_names then
    Some
      (if includes_tool "keeper_surface_read" allowed_tools then
         "keeper_tools_list lists capabilities, not connected-surface or lane \
          contents; for current lane context use keeper_surface_read with a \
          surface label from Connected Surfaces or chat history. If the user asks \
          for a connector-wide channel registry outside those connected lanes, \
          state that it is unavailable."
       else
         "keeper_tools_list lists capabilities, not connected-surface or lane \
          contents; do not repeat it to answer user content questions.")
  else if
    includes_tool "keeper_board_get" tool_names
    || includes_tool "keeper_board_post_get" tool_names
  then
    let discovery_tools =
      [ "keeper_board_list"; "keeper_board_search" ]
      |> List.filter (fun name -> includes_tool name allowed_tools)
    in
    let discovery =
      match discovery_tools with
      | [] -> "a visible board activity post_id"
      | [ one ] -> one
      | many -> String.concat " or " many
    in
    (* The routable tool is keeper_board_post_get; "keeper_board_get" has no
       dispatch route (models hallucinate it, which is why both names trigger
       this hint above) — the nudge must name the tool that actually exists. *)
    Some
      (Printf.sprintf
         "keeper_board_post_get requires an exact post_id from board activity. \
          Use %s to discover one before calling keeper_board_post_get."
         discovery)
  else if includes_tool "keeper_tool_search" allowed_tools then
    Some
      "Use keeper_tool_search with a keyword to discover available tools. \
       If the tool you need is not listed, report that it is unavailable."
  else
    None

let on_idle_decision_with_threshold ~skip_at ~consecutive_idle_turns ~allowed_tools
    ~tool_names =
  if consecutive_idle_turns >= skip_at then
    let hint = recovery_hint ~allowed_tools ~tool_names in
    let alternatives =
      suggest_alternatives ~allowed_tools ~repeated_tools:tool_names ~max_suggestions:3
    in
    let decision =
      match hint with
      | Some hint_text ->
        let msg =
          Printf.sprintf
            "You have been idle for %d consecutive turns. %s\n\n\
             Consider one of these tools instead: %s"
            consecutive_idle_turns hint_text
            (String.concat ", " alternatives)
        in
        Hook_decision.Suggest msg
      | None ->
        let msg =
          Printf.sprintf
            "You have been idle for %d consecutive turns. \
             Consider one of these tools instead: %s"
            consecutive_idle_turns
            (String.concat ", " alternatives)
        in
        Hook_decision.Suggest msg
    in
    decision
  else
    Hook_decision.Pass

let on_idle_decision ~consecutive_idle_turns ~allowed_tools ~tool_names =
  on_idle_decision_with_threshold ~skip_at:3 ~consecutive_idle_turns ~allowed_tools
    ~tool_names

let keeper_idle_decision ~meta_ref ~consecutive_idle_turns ~tool_names =
  let meta = !meta_ref in
  let allowed_tools = meta.allowed_tools in
  on_idle_decision ~consecutive_idle_turns ~allowed_tools ~tool_names

let recent_tool_streak_count ?(within_sec = 900.0) ~(tool_name : string)
    (history : Yojson.Safe.t list) : int =
  let now = Unix.time () in
  history
  |> List.filter_map (fun entry ->
         match entry with
         | `Assoc fields ->
           (match List.assoc_opt "tool" fields, List.assoc_opt "timestamp" fields with
           | Some (`String name), Some (`Float ts) when String.equal name tool_name ->
             if now -. ts <= within_sec then Some () else None
           | _ -> None)
         | _ -> None)
  |> List.length