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

let includes_tool name tools = List.exists (String.equal name) tools

let schema_visible_name name =
  match Keeper_tool_visibility_projection.public_alias_for_internal name with
  | Some public_name -> public_name
  | None -> name

let schema_visible_keep_order names =
  names
  |> List.map schema_visible_name
  |> Keeper_types_profile_toml_normalizers.dedupe_keep_order

let recovery_hint ~allowed_tools ~tool_names =
  if includes_tool "keeper_tool_search" tool_names then
    Some
      "keeper_tool_search discovers active tool schemas only; it does not search \
       repository files, definitions, functions, types, or symbols. Use an \
       explicitly visible file/content tool if one is active; otherwise state \
       that repository content search is unavailable in the current tool surface."
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
         "keeper_board_post_get requires post_id; if no post_id is visible, use %s first. \
          Do not call keeper_board_post_get with {}."
         discovery)
  else
    None

(** Pure decision logic for the on_idle hook.  Testable without Workspace.config.

    Graduated response to repeated tool calls uses the configured
    [Env_config_keeper.KeeperKeepalive.idle_skip_threshold]:
    - For idle counts below [skip_at - 1]: gentle nudge suggesting alternatives
    - For idle counts at [skip_at - 1]: final warning (stronger nudge)
      suggesting a different visible tool or a text/no-work completion
    - For idle counts at or above [skip_at]: Skip (end this turn, but the
      heartbeat loop will retry next cycle)

    The [~allowed_tools] parameter enables concrete alternative suggestions
    instead of generic "try a different tool" messages. This is the
    deterministic envelope providing structured options for the
    non-deterministic LLM to choose from.

    Skip is not death. The keeper's heartbeat loop will schedule a new
    turn on the next cycle with fresh context. The key insight is that
    burning more tokens on a stuck LLM is worse than retrying later. *)
let on_idle_decision_with_threshold ~skip_at ~consecutive_idle_turns
    ~allowed_tools ~tool_names
  : Agent_sdk.Hooks.hook_decision =
  let tools_str = match tool_names with
    | [] -> "<none>"
    | names -> String.concat ", " names
  in
  let alternatives =
    let base =
      suggest_alternatives ~allowed_tools ~repeated_tools:tool_names
        ~max_suggestions:5
    in
    let preferred =
      if includes_tool "keeper_tools_list" tool_names
              && includes_tool "keeper_surface_read" allowed_tools
      then
        [ "keeper_surface_read" ]
      else
        []
    in
    Keeper_types_profile_toml_normalizers.dedupe_keep_order
      (preferred @ base)
    |> schema_visible_keep_order
    |> List.filteri (fun i _ -> i < 5)
  in
  let alt_str = match alternatives with
    | [] -> "a different visible tool, or finish with a direct no-work/status response"
    | alts -> String.concat ", " alts
  in
  let hint = recovery_hint ~allowed_tools ~tool_names in
  let append_hint msg =
    match hint with
    | None -> msg
    | Some hint -> msg ^ " " ^ hint
  in
  if consecutive_idle_turns >= skip_at then
    Agent_sdk.Hooks.Skip
  else if consecutive_idle_turns = skip_at - 1 then
    Agent_sdk.Hooks.Nudge
      (append_hint
         (Printf.sprintf
            "FINAL WARNING: you repeated %s %d times. Next idle = turn ends. \
             Use one of these instead: %s."
            tools_str consecutive_idle_turns alt_str))
  else
    Agent_sdk.Hooks.Nudge
      (append_hint
         (Printf.sprintf
            "You are repeating %s without progress. \
             Available alternatives: %s."
            tools_str alt_str))

(** Wrapper around {!on_idle_decision_with_threshold} that supplies the
    [idle_skip_threshold] constant from [Env_config_keeper.KeeperKeepalive].
    Reads the keeper's allowed tool names from [meta_ref] for concrete
    alternative suggestions. *)
let on_idle_decision ~consecutive_idle_turns ~allowed_tools ~tool_names
  : Agent_sdk.Hooks.hook_decision =
  let skip_at = Env_config_keeper.KeeperKeepalive.idle_skip_threshold in
  on_idle_decision_with_threshold ~skip_at ~consecutive_idle_turns
    ~allowed_tools ~tool_names

let keeper_idle_decision
    ~(meta_ref : Keeper_meta_contract.keeper_meta ref)
    ~consecutive_idle_turns
    ~tool_names =
  let keeper_name = (!meta_ref).name in
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string ConsecutiveIdle)
    ~labels:[ label_keeper, keeper_name ]
    (Float.of_int (max 0 consecutive_idle_turns));
  let allowed_tools =
    Keeper_tool_policy.keeper_allowed_tool_names !meta_ref in
  let decision =
    on_idle_decision ~consecutive_idle_turns ~tool_names
      ~allowed_tools in
  let tools_str = match tool_names with
    | [] -> "<none>" | names -> String.concat ", " names in
  (match decision with
   | Agent_sdk.Hooks.Skip ->
     Log.Keeper.warn ~keeper_name "idle_turns=%d repeated_tools=[%s] — requesting stop"
       consecutive_idle_turns tools_str
   | Agent_sdk.Hooks.Nudge _ ->
     Log.Keeper.info ~keeper_name "idle_turns=%d tools=[%s] — nudging LLM via Nudge"
       consecutive_idle_turns tools_str
   | _ -> ());
  decision

let recent_tool_streak_count ?(within_sec = 900.0) ~(tool_name : string)
    (entries : Yojson.Safe.t list) : int =
  let now = Time_compat.now () in
  let rec loop count = function
    | [] -> count
    | entry :: rest ->
      (match Safe_ops.json_string_opt "tool" entry,
              Safe_ops.json_float_opt "ts" entry with
       | Some logged_tool, Some ts
         when String.equal logged_tool tool_name && now -. ts <= within_sec ->
           loop (count + 1) rest
       | _ -> count)
  in
  loop 0 (List.rev entries)
