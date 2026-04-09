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
    (match available [ "keeper_fs_read"; "keeper_shell"; "masc_code_read" ] with
     | [] ->
         add
           "- Live worktree delta is actionable, but file-inspection tools are unavailable under the current tool policy."
     | tools ->
         add
           (Printf.sprintf
              "- Live worktree delta: inspect changed files with %s if you need to understand whether action is required."
              (String.concat ", " tools)));
  (* When no reactive triggers exist, suggest proactive behaviors instead of
     telling the keeper to do nothing.  This prevents the idle-death loop where
     keepers repeatedly call keeper_tasks_audit on the same failed tasks and
     OAS kills them for "5 consecutive identical tool call turns". *)
  if !routes = [] then begin
    if can "keeper_board_post" then
      add
        "- No reactive work. Share an observation, thought, or question on the Board \
         using keeper_board_post (set hearth to your name).";
    if can "keeper_broadcast" then
      add
        "- No reactive work. Share a brief status update using keeper_broadcast.";
    if can "keeper_board_list" then
      add
        "- Browse recent Board posts with keeper_board_list to look for topics \
         or ideas worth revisiting.";
    if can "keeper_memory_search" then
      add
        "- Search your memories with keeper_memory_search for something worth \
         revisiting or building on.";
    if can "keeper_library_search" then
      add
        "- Explore library references with keeper_library_search for new knowledge.";
    if !routes = [] then
      add "- No actionable work. Emit your [STATE] block and end your turn."
  end;
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

let build_prompt ~(meta : Keeper_types.keeper_meta) ~(base_path : string)
    ~(observation : Keeper_world_observation.world_observation)
    ?(diversity_hint : string option) () : string * string
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
     \n\
     You may chain multiple tool calls within this turn to complete a meaningful interaction.\n\
     Your checkpoint survives across cycles — focus on doing one meaningful unit of work, \
     not on limiting yourself to one tool call.\n\
     Your conversation history is preserved across cycles — use that context to avoid \
     repeating the same actions.\n\
     \n\
     Act through tools, not declarations. Call the tool directly.\n\
     - See board activity? Read the full post with keeper_board_get, then comment with \
     keeper_board_comment.\n\
     - See an unclaimed task matching your skills? Call keeper_task_claim.\n\
     - Have a finding or update? Call keeper_board_post.\n\
     - Need to share broadly? Call keeper_broadcast.\n\
     - Nothing genuinely actionable after checking? End your turn with the [STATE] block.\n\
     \n\
     If you call tools, BDI headers are optional and informational only. \
     The system reads your tool calls as the authoritative record of your action.\n\
     \n\
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
  (* Keeper tool inventory — show allowed tools with auto-generated hints
     from schema descriptions.  This is the SSOT for tool discovery:
     keepers see what they can use and why, without manual duplication
     in instructions. *)
  let allowed_tools = Keeper_tool_policy.keeper_allowed_tool_names meta in
  if allowed_tools <> [] then (
    Buffer.add_string ubuf "\n### Available Tools\n\
      These tools are already loaded. Call them directly — no keeper_tool_search needed.\n\
      Use keeper_tool_search ONLY for tools NOT listed here.\n";
    List.iter (fun name ->
      match Keeper_tool_policy.tool_hint_of name with
      | Some hint ->
        Buffer.add_string ubuf (Printf.sprintf "- %s — %s\n" name hint)
      | None ->
        Buffer.add_string ubuf (Printf.sprintf "- %s\n" name))
      allowed_tools);
  (* Metacognition: show the keeper its own recent tool activity so it can
     recognise patterns — thrashing, failure loops, tool over-reliance.
     Data comes from Keeper_registry per-entry tool_usage Hashtbl. *)
  let tool_activity =
    Keeper_registry.tool_usage_of ~base_path meta.name
    |> List.sort (fun (_, a) (_, b) ->
      Float.compare b.Keeper_types.last_used_at a.Keeper_types.last_used_at)
  in
  let recent_activity = List.filteri (fun i _ -> i < 8) tool_activity in
  if recent_activity <> [] then (
    Buffer.add_string ubuf "\n### Recent Tool Activity\n";
    List.iter (fun (name, (e : Keeper_types.tool_call_entry)) ->
      let rate =
        if e.count > 0
        then float_of_int e.successes /. float_of_int e.count *. 100.0
        else 0.0
      in
      let warning =
        if e.count >= 3 && rate < 50.0 then " [LOW SUCCESS — try different approach]"
        else ""
      in
      Buffer.add_string ubuf
        (Printf.sprintf "- %s: %d calls (%d ok, %d fail, %.0f%% success)%s\n"
           name e.count e.successes e.failures rate warning)
    ) recent_activity;
    );
  (* Metacognition: last cycle outcome so keeper knows its own behavioral pattern.
     This is MASC domain data (proactive_rt) not available in OAS.
     Per-turn behavioral correction (idle loops, tool repetition) is handled by
     OAS on_idle → Nudge hook in keeper_hooks_oas.ml — not here. *)
  let prt = meta.runtime.proactive_rt in
  let outcome_str = Keeper_types.proactive_cycle_outcome_to_string prt.last_outcome in
  if prt.count_total > 0 then (
    Buffer.add_string ubuf "\n### Last Cycle Outcome\n";
    Buffer.add_string ubuf
      (Printf.sprintf "- Result: %s\n" outcome_str);
    if prt.last_reason <> "" then
      Buffer.add_string ubuf
        (Printf.sprintf "- Reason: %s\n" prt.last_reason);
    Buffer.add_string ubuf
      (Printf.sprintf "- Cycles total: %d (visible: %d, silent: %d)\n"
         prt.count_total prt.visible_count_total
         (prt.count_total - prt.visible_count_total)));
  (* Tool diversity hint — deterministic gate from entropy analysis.
     Injected when normalized entropy is below threshold, prompting the
     LLM (non-deterministic) to explore underused tools. *)
  (match diversity_hint with
   | Some hint ->
     Buffer.add_string ubuf "\n### Tool Diversity Signal\n";
     Buffer.add_string ubuf (Printf.sprintf "%s\n" hint)
   | None -> ());
  (* Peer keepers — show other running keepers so this keeper can @mention them *)
  let peer_keepers =
    Keeper_registry.all ~base_path ()
    |> List.filter_map (fun (entry : Keeper_registry.registry_entry) ->
      if String.equal entry.name meta.name then None
      else if entry.phase <> Keeper_state_machine.Running then None
      else
        let targets = entry.meta.mention_targets in
        let targets_str =
          if targets = [] then ""
          else " (mention with: " ^ String.concat ", "
            (List.map (fun t -> "@" ^ t) targets) ^ ")"
        in
        let goal_summary =
          if entry.meta.goal = "" then "active"
          else if String.length entry.meta.goal <= 200 then entry.meta.goal
          else String.sub entry.meta.goal 0 197 ^ "..."
        in
        Some (Printf.sprintf "- %s%s — %s" entry.name targets_str goal_summary))
  in
  if peer_keepers <> [] then (
    Buffer.add_string ubuf "\n### Peer Keepers\n";
    Buffer.add_string ubuf
      "You can interact with these keepers by mentioning them in board posts.\n";
    Buffer.add_string ubuf (String.concat "\n" peer_keepers);
    Buffer.add_string ubuf "\n");
  (* Self-awareness: show this keeper its own recent board posts so it can
     recognize repetitive patterns.  Non-heuristic: the model decides whether
     its behavior is repetitive, not a hardcoded similarity check. *)
  let own_recent_posts =
    let posts_path =
      Filename.concat (Filename.concat base_path ".masc") "board_posts.jsonl"
    in
    (try
       Fs_compat.load_jsonl posts_path
       |> List.filter_map Board.post_of_yojson
       |> List.filter (fun (p : Board_types.post) ->
         String.equal (Board_types.Agent_id.to_string p.author) meta.name)
       |> List.rev
       |> (fun posts ->
         if List.length posts > 5
         then List.filteri (fun i _ -> i < 5) posts
         else posts)
       |> List.map (fun (p : Board_types.post) ->
         let title = p.title in
         let truncated =
           if String.length title <= 60 then title
           else String.sub title 0 57 ^ "..."
         in
         Printf.sprintf "- \"%s\"" truncated)
     with Eio.Cancel.Cancelled _ as e -> raise e | _ -> [])
  in
  if own_recent_posts <> [] then (
    Buffer.add_string ubuf "\n### Your Recent Board Posts\n";
    Buffer.add_string ubuf
      "Review these before posting. If you see a repetitive pattern, \
       do something genuinely different this turn.\n";
    Buffer.add_string ubuf (String.concat "\n" own_recent_posts);
    Buffer.add_string ubuf "\n");
  (* Work Discovery — nudge keeper to scan for actionable work *)
  if observation.work_discovery_due then (
    Buffer.add_string ubuf "\n### Work Discovery Due\n";
    Buffer.add_string ubuf
      "No work discovery scan in the configured interval. \
       Use your available tools to scan for actionable work.\n";
    (match meta.work_discovery_sources with
     | Some sources ->
       Buffer.add_string ubuf "Configured sources to check:\n";
       List.iter (fun src ->
         Buffer.add_string ubuf (Printf.sprintf "- %s\n" src)) sources
     | None -> ());
    (match meta.work_discovery_guidance with
     | Some guide ->
       Buffer.add_string ubuf (Printf.sprintf "Guidance: %s\n" guide)
     | None -> ());
    Buffer.add_string ubuf
      "If you find actionable items, create tasks or claim existing ones. \
       If nothing found, record what you checked.\n");
  (* Behavioral Self-Assessment — telemetry feedback from decision log *)
  (match observation.behavioral_stats with
   | Some stats ->
     Buffer.add_string ubuf "\n";
     Buffer.add_string ubuf
       (Keeper_telemetry_feedback.render_feedback_block ~stats)
   | None -> ());
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
