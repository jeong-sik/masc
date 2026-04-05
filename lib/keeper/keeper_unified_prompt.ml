(** Keeper_unified_prompt — Build a single unified prompt from keeper identity
    and world observation.

    @since Unified Keeper Loop *)

(** Format a list of (from_agent, content) mentions into a prompt section. *)
let format_mentions (mentions : (string * string) list) : string =
  String.concat "\n"
    (List.map
       (fun (from_agent, content) ->
         Printf.sprintf "- @%s: %s" from_agent
           (Keeper_types.short_preview ~max_len:200 content))
       mentions)

(** Format active goals into a prompt section. *)
let format_goals (goal_ids : string list) : string =
  String.concat "\n"
    (List.map (fun gid -> Printf.sprintf "- %s" gid) goal_ids)

let format_scope_messages
    (messages : (string * string) list) : string =
  String.concat "\n"
    (List.map
       (fun (from_agent, content) ->
         Printf.sprintf "- %s: %s"
           from_agent
           (Keeper_types.short_preview ~max_len:200 content))
       messages)

let format_board_events
    (events : Keeper_world_observation.pending_board_event list) : string =
  String.concat "\n"
    (List.map
       (fun (event : Keeper_world_observation.pending_board_event) ->
         let kind =
           match event.post_kind with
           | Board.Human_post -> "direct"
           | Board.Automation_post -> "automation"
           | Board.System_post -> "system"
         in
         let mention_note =
           if event.explicit_mention then
             let targets =
               match event.matched_targets with
               | [] -> "explicit mention"
               | xs -> "mentions " ^ String.concat ", " xs
             in
             " [" ^ targets ^ "]"
           else ""
         in
         let hearth_note =
           match event.hearth with
           | Some hearth when String.trim hearth <> "" -> " {" ^ hearth ^ "}"
           | _ -> ""
         in
         let self_note =
           if event.self_commented && event.new_external_since > 0 then
             Printf.sprintf " [%d new reply since yours%s]"
               event.new_external_since
               (match event.latest_external_author, event.latest_external_preview with
                | Some a, Some p -> Printf.sprintf ", latest by %s: %s" a p
                | _ -> "")
           else ""
         in
         Printf.sprintf "- [%s] %s%s%s%s: %s"
           kind event.author hearth_note mention_note self_note event.preview)
       events)

let line_block label value =
  if value = "" then ""
  else Printf.sprintf "%s: %s\n" label value

let format_room_signal_salience salience =
  Meta_cognition.salience_to_string salience

let actionable_routes ~(allowed_tools : string list)
    (observation : Keeper_world_observation.world_observation) : string list =
  let can tool_name = List.mem tool_name allowed_tools in
  let available tool_names =
    List.filter (fun tool_name -> can tool_name) tool_names
  in
  let routes = ref [] in
  let add route = routes := route :: !routes in
  if observation.pending_mentions <> [] then
    add
      "- Pending mentions: reply in-room before going silent.";
  if observation.pending_board_events <> [] then
    (match available [ "keeper_board_comment"; "keeper_board_post" ] with
     | [] ->
         add
           "- Board activity is actionable, but board reply tools are unavailable under the current tool policy."
     | tools ->
         add
           (Printf.sprintf
              "- Board activity: use %s if a visible response is warranted."
              (String.concat " or " tools)));
  if observation.unclaimed_task_count > 0 then
    if can "keeper_task_claim" then
      add
        "- Unclaimed tasks: use keeper_task_claim before treating the room as idle."
    else
      add
        "- Unclaimed tasks are present, but task-claim tooling is unavailable under the current tool policy.";
  if observation.failed_task_count > 0 then
    if can "keeper_tasks_audit" then
      add
        "- Failed tasks: audit once with keeper_tasks_audit. If the audit returns no orphans or actionable items, do NOT call keeper_tasks_audit again — instead post a brief status summary to the board with keeper_board_post and end your turn."
    else
      add
        "- Failed tasks are actionable, but task-audit tooling is unavailable under the current tool policy.";
  if Option.is_some observation.worktree_change_summary then
    (match available [ "keeper_fs_read"; "keeper_shell_readonly"; "masc_code_read" ] with
     | [] ->
         add
           "- Live worktree delta is actionable, but file-inspection tools are unavailable under the current tool policy."
     | tools ->
         add
           (Printf.sprintf
              "- Live worktree delta: inspect changed files with %s if you need to understand whether action is required."
              (String.concat ", " tools)));
  if !routes = [] then
    add "- No actionable work. Emit your [STATE] block and end your turn.";
  List.rev !routes

let autonomous_trigger_lines
    ~(decision : Keeper_world_observation.unified_turn_decision)
    ~(observation : Keeper_world_observation.world_observation) : string list =
  match decision.channel, decision.should_run with
  | Keeper_world_observation.Scheduled_autonomous, true ->
      let lines =
        [
          Some "- Scheduler: scheduled autonomous keepalive turn.";
          (match decision.reasons with
           | [] -> None
           | reasons ->
               Some
                 (Printf.sprintf "- Reasons: %s"
                    (String.concat ", " reasons)));
          (match decision.idle_gate_sec with
           | Some idle_gate ->
               Some
                 (Printf.sprintf "- Idle gate: %ds (current idle: %ds)"
                    idle_gate observation.idle_seconds)
           | None -> None);
          (match decision.since_last_scheduled_autonomous, decision.effective_cooldown with
           | Some since_last, Some cooldown ->
               Some
                 (Printf.sprintf
                    "- Since last autonomous turn: %ds, effective cooldown: %ds"
                    since_last cooldown)
           | _ -> None);
          (match decision.task_reactive_cooldown with
           | Some cooldown
             when observation.unclaimed_task_count > 0
                  || observation.failed_task_count > 0 ->
               Some
                 (Printf.sprintf
                    "- Backlog acceleration cooldown: %ds for unclaimed/failed tasks"
                    cooldown)
           | _ -> None);
        ]
      in
      List.filter_map Fun.id lines
  | _ -> []

let has_room_signal_section
    (observation : Keeper_world_observation.world_observation) =
  match observation.room_signal_interpretation with
  | Some interpretation ->
      interpretation.primary_salience <> Meta_cognition.Stable
      || interpretation.secondary_saliences <> []
  | None -> false

let build_prompt ~(meta : Keeper_types.keeper_meta)
    ~(observation : Keeper_world_observation.world_observation) : string * string
    =
  let trait_lines =
    String.concat ""
      [
        
        line_block "Will" meta.will;
        line_block "Needs" meta.needs;
        line_block "Desires" meta.desires;
      ]
  in
  let instructions_block =
    if meta.instructions = "" then ""
    else Printf.sprintf "\nInstructions:\n%s\n" meta.instructions
  in
  let goal_lines =
    String.concat ""
      [
        line_block "Primary goal" meta.goal;
        (if meta.short_goal <> "" && meta.short_goal <> meta.goal then
           line_block "Short-term goal" meta.short_goal
         else "");
        (if meta.mid_goal <> "" && meta.mid_goal <> meta.goal then
           line_block "Mid-term goal" meta.mid_goal
         else "");
        (if meta.long_goal <> "" && meta.long_goal <> meta.goal then
           line_block "Long-term goal" meta.long_goal
         else "");
      ]
  in
  let base_system_prompt =
    match
      Prompt_registry.render_prompt_template Keeper_prompt_names.unified_system
        [
          ("identity_header", Printf.sprintf "You are %s, a keeper agent." meta.name);
          ("trait_lines", trait_lines);
          ("instructions_block", instructions_block);
          ("goal_lines", goal_lines);
        ]
    with
    | Ok value -> value
    | Error _ -> Prompt_registry.get_prompt Keeper_prompt_names.unified_system
  in
  let turn_intent_block =
    "Use the world state below as raw context.\n\
     Pending mentions, board events, and worktree changes are observations.\n\
     Focus on one observation and one action per cycle. \
     Your checkpoint survives across cycles — do not rush to finish everything now.\n\
     Unclaimed tasks in the backlog are actionable work — if your skills match, \
     claim one with keeper_task_claim and work on it.\n\
     When you have findings, opinions, or status updates worth sharing, post them to the board \
     using keeper_board_post. When responding to board activity, use keeper_board_comment.\n\n\
     ## Anti-Repetition Rules\n\
     CRITICAL: Never call the same tool with the same arguments twice in a row within a single turn.\n\
     If a tool returned no actionable results (e.g. audit found no orphans, search found nothing), \
     do NOT retry it. Instead choose one of:\n\
     1. Post a status summary to the board (keeper_board_post)\n\
     2. Claim a different task if available (keeper_task_claim)\n\
     3. End your turn silently (DELIVERY_SURFACE: silent)\n\
     Progress means doing something NEW each cycle, not re-checking the same state.\n\n\
     Every response must begin with these machine-readable headers exactly once:\n\
     SOCIAL_MODEL: bdi_speech_v1\n\
     BELIEF_SUMMARY: <short summary>\n\
     ACTIVE_DESIRE: <value or none>\n\
     CURRENT_INTENTION: <value or none>\n\
     BLOCKER: <value or none>\n\
     NEED: <value or none>\n\
     SPEECH_ACT: stay_silent|inform|request_help|claim_task|comment_board|post_board|broadcast|defer\n\
     DELIVERY_SURFACE: silent|visible_reply|board_post|board_comment|task_claim|broadcast\n\
     If DELIVERY_SURFACE is silent, emit no visible body after the headers.\n\
     End every response with a [STATE]...[/STATE] block:\n\
     DONE: what you accomplished this cycle\n\
     NEXT: what the next cycle should do\n\
     Goal: current active goal\n\
     Decisions: key decisions (semicolon-separated)"
  in
  let system_prompt =
    Printf.sprintf "%s\n\n## Turn Intent\n%s" base_system_prompt turn_intent_block
    |> Inference_utils.sanitize_text_utf8
  in
  (* User message: structured world observation *)
  let ubuf = Buffer.create 1024 in
  Buffer.add_string ubuf "## Current World State\n\n";
  (* Pending mentions *)
  if observation.pending_mentions <> [] then (
    Buffer.add_string ubuf
      (Printf.sprintf "### Pending Mentions (%d)\n"
         (List.length observation.pending_mentions));
    Buffer.add_string ubuf (format_mentions observation.pending_mentions);
    Buffer.add_string ubuf "\n\n");
  if observation.pending_scope_messages <> [] then (
    Buffer.add_string ubuf
      (Printf.sprintf "### Scope Messages (%d recent)\n"
         (List.length observation.pending_scope_messages));
    Buffer.add_string ubuf
      (format_scope_messages observation.pending_scope_messages);
    Buffer.add_string ubuf "\n\n");
  (* Active goals *)
  if observation.active_goals <> [] then (
    Buffer.add_string ubuf
      (Printf.sprintf "### Active Goals (%d)\n"
         (List.length observation.active_goals));
    Buffer.add_string ubuf (format_goals observation.active_goals);
    Buffer.add_string ubuf "\n\n");
  (* Namespace state *)
  if
    observation.unclaimed_task_count > 0
    || observation.failed_task_count > 0
    || observation.active_agent_count > 0
  then (
    Buffer.add_string ubuf "### Namespace State\n";
    if observation.unclaimed_task_count > 0 then
      Buffer.add_string ubuf
        (Printf.sprintf "- Unclaimed tasks: %d\n"
           observation.unclaimed_task_count);
    if observation.failed_task_count > 0 then
      Buffer.add_string ubuf
        (Printf.sprintf "- Failed tasks: %d\n" observation.failed_task_count);
    Buffer.add_string ubuf
      (Printf.sprintf "- Active agents: %d\n" observation.active_agent_count);
    Buffer.add_string ubuf "\n");
  (* Board activity *)
  if observation.pending_board_events <> [] then (
    Buffer.add_string ubuf
      (Printf.sprintf "### Board Activity (%d new)\n"
         (List.length observation.pending_board_events));
    Buffer.add_string ubuf (format_board_events observation.pending_board_events);
    Buffer.add_string ubuf "\n";
    Buffer.add_string ubuf "\n");
  if meta.room_signal_prompt_enabled && has_room_signal_section observation then (
    match observation.room_signal_interpretation with
    | Some interpretation ->
        Buffer.add_string ubuf "### Namespace Signal Interpretation\n";
        Buffer.add_string ubuf
          (Printf.sprintf "- namespace_signal_primary: %s\n"
             (format_room_signal_salience interpretation.primary_salience));
        (match interpretation.secondary_saliences with
         | [] -> ()
         | secondary ->
             Buffer.add_string ubuf
               (Printf.sprintf "- namespace_signal_secondary: %s\n"
                  (secondary
                  |> List.map format_room_signal_salience
                  |> String.concat ", ")));
        Buffer.add_string ubuf
          (Printf.sprintf "- namespace_signal_reason: %s\n" interpretation.reason);
        (match interpretation.target_id with
         | Some target_id ->
             Buffer.add_string ubuf
               (Printf.sprintf "- namespace_signal_target_id: %s\n" target_id)
         | None -> ());
        (match interpretation.evidence_refs with
         | [] -> ()
         | refs ->
             Buffer.add_string ubuf
               (Printf.sprintf "- namespace_signal_evidence_refs: %s\n"
                  (String.concat ", " refs)));
        (match observation.room_signal_digest_ref with
         | Some digest ->
             Buffer.add_string ubuf
               (Printf.sprintf "- namespace_digest_post_id: %s\n" digest.post_id);
             Buffer.add_string ubuf
               (Printf.sprintf "- namespace_digest_title: %s\n" digest.title)
         | None -> ());
        Buffer.add_string ubuf
          "- namespace_signal_guard: do not call keeper_board_post or keeper_task_claim from this derived signal alone; read at least one raw board item from namespace_signal_evidence_refs or namespace_digest_post_id first.\n\n"
    | None -> ());
  (* Context health *)
  Buffer.add_string ubuf
    (Printf.sprintf "### Context\n- Utilization: %.0f%%\n- Idle: %ds\n"
       (observation.context_ratio *. 100.0)
       observation.idle_seconds);
  (* Turn budget from previous generation *)
  (match observation.last_turn_budget with
   | Some (used, total) when used > 0 ->
     Buffer.add_string ubuf
       (Printf.sprintf "- Previous turn budget: %d/%d used\n" used total)
   | _ -> ());
  (* Economic pressure *)
  (match observation.economic_pressure with
   | Agent_economy.Normal -> ()
   | Frugal ->
       Buffer.add_string ubuf "- Economy: Frugal (reduce token usage)\n"
   | Hustle ->
        Buffer.add_string ubuf
          "- Economy: Hustle (minimize actions, conserve budget)\n");
  let turn_decision =
    Keeper_world_observation.unified_turn_decision ~meta observation
  in
  let autonomous_trigger =
    autonomous_trigger_lines ~decision:turn_decision ~observation
  in
  if autonomous_trigger <> [] then (
    Buffer.add_string ubuf "\n### Autonomous Trigger\n";
    Buffer.add_string ubuf (String.concat "\n" autonomous_trigger);
    Buffer.add_string ubuf "\n");
  (* Keeper tool inventory — show the keeper_* subset available this cycle *)
  let allowed_tools = Keeper_tool_policy.keeper_allowed_tool_names meta in
  let keeper_tools =
    List.filter (fun n -> String.starts_with ~prefix:"keeper_" n) allowed_tools
  in
  if keeper_tools <> [] then (
    Buffer.add_string ubuf "\n### Keeper Tools\n";
    Buffer.add_string ubuf (String.concat ", " keeper_tools);
    Buffer.add_string ubuf "\n");
  let routes = actionable_routes ~allowed_tools observation in
  if routes <> [] then (
    Buffer.add_string ubuf "\n### Actionable Routes\n";
    Buffer.add_string ubuf (String.concat "\n" routes);
    Buffer.add_string ubuf "\n");
  (* Continuity *)
  if
    observation.continuity_summary <> ""
    && observation.continuity_summary <> "No continuity snapshot available."
  then (
    Buffer.add_string ubuf "\n### Continuity\n";
    Buffer.add_string ubuf observation.continuity_summary;
    Buffer.add_string ubuf "\n");
  (match observation.worktree_change_summary with
   | Some summary when String.trim summary <> "" ->
       Buffer.add_string ubuf "\n### Live Worktree Delta\n";
       Buffer.add_string ubuf summary;
       Buffer.add_string ubuf "\n"
   | _ -> ());
  let user_message =
    Buffer.contents ubuf |> Inference_utils.sanitize_text_utf8
  in
  (system_prompt, user_message)
