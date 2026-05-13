(** Keeper_unified_prompt — Build a single unified prompt from keeper identity
    and world observation.

    Sections removed in #6814: Available Tools (OAS tool schema handles),
    Recent Tool Activity, Last Cycle Outcome, Tool Diversity Signal,
    Peer Keepers, Your Recent Board Posts, Work Discovery Due,
    Behavioral Self-Assessment, Actionable Routes, Signal Interpretation.
    Telemetry for removed sections is preserved via decision_audit and
    independent storage paths.

    @since Unified Keeper Loop *)

(** Format a list of (from_agent, content) mentions into a prompt section. *)
let format_mentions (mentions : (string * string) list) : string =
  String.concat "\n"
    (List.map
       (fun (from_agent, content) ->
         Printf.sprintf "- @%s: %s" from_agent
           (Keeper_types.short_preview ~max_len:200 content))
       mentions)

let scope_message_prompt_limit = 12
let scope_message_preview_len = 120

let take_last_with_omitted limit items =
  let len = List.length items in
  if len <= limit then (items, 0)
  else
    let rec drop n xs =
      if n <= 0 then xs
      else
        match xs with
        | [] -> []
        | _ :: rest -> drop (n - 1) rest
    in
    (drop (len - limit) items, len - limit)

(** Format active goals into a prompt section. *)
let format_goals (goal_ids : string list) : string =
  String.concat "\n"
    (List.map (fun gid -> Printf.sprintf "- %s" gid) goal_ids)

let format_scope_messages
    (messages : (string * string) list) : string =
  let shown_messages, omitted =
    take_last_with_omitted scope_message_prompt_limit messages
  in
  let omitted_line =
    if omitted <= 0 then []
    else
      [
        Printf.sprintf
          "- [omitted %d older scope messages; cursor still advances past the full batch]"
          omitted;
      ]
  in
  String.concat "\n"
    (omitted_line
     @ List.map
         (fun (from_agent, content) ->
           Printf.sprintf "- %s: %s"
             from_agent
             (Keeper_types.short_preview ~max_len:scope_message_preview_len content))
         shown_messages)

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

let state_block_instruction_text =
  "For non-direct keeper turns, end every response with a [STATE]...[/STATE] block unless a more specific turn-level output guard says continuity is runtime-managed:\n\
   DONE: what you accomplished this cycle\n\
   NEXT: what the next cycle should do\n\
   Goal: current active goal\n\
   Decisions: key decisions (semicolon-separated)"

let autonomous_trigger_lines
    ~(decision : Keeper_world_observation.keeper_cycle_decision)
    ~(observation : Keeper_world_observation.world_observation) : string list =
  match decision.channel, decision.should_run with
  | Keeper_world_observation.Scheduled_autonomous, true ->
      let lines =
        [
          Some "- Scheduler: scheduled autonomous keepalive turn.";
          (match Keeper_world_observation.verdict_reasons_to_strings decision.verdict with
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
             when observation.claimable_task_count > 0
                  || observation.failed_task_count > 0 ->
               Some
                 (Printf.sprintf
                    "- Backlog acceleration cooldown: %ds for claimable/failed tasks"
                    cooldown)
           | _ -> None);
        ]
      in
      List.filter_map Fun.id lines
  | _ -> []

let build_prompt ~(meta : Keeper_types.keeper_meta) ~(base_path : string)
    ~(observation : Keeper_world_observation.world_observation)
    () : string * string
    =
  ignore base_path;
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
  let allowed_tool_names = Keeper_tool_policy.keeper_allowed_tool_names meta in
  let tool_allowed name = List.mem name allowed_tool_names in
  let claim_tool_available = tool_allowed "keeper_task_claim" in
  let show_claim_guidance =
    observation.claimable_task_count > 0
    && claim_tool_available
    && not meta.paused
    && Option.is_none meta.current_task_id
  in
  let board_activity_guidance =
    if tool_allowed "keeper_board_get" && tool_allowed "keeper_board_comment" then
      "- See board activity? Read the full post with keeper_board_get, then comment with keeper_board_comment.\n"
    else
      ""
  in
  let board_post_guidance =
    if tool_allowed "keeper_board_post" then
      "- Have a finding or update? Call keeper_board_post.\n"
    else
      ""
  in
  let board_curation_guidance =
    if tool_allowed "keeper_board_curation_submit" then
      "- See enough board activity to summarize or route? Call keeper_board_curation_submit with a concise snapshot.\n"
    else
      ""
  in
  let broadcast_guidance =
    if tool_allowed "keeper_broadcast" then
      "- Need to share broadly? Call keeper_broadcast.\n"
    else
      ""
  in
  (* Turn intent body lives at config/prompts/keeper.turn_intent.md.
     The OCaml side only assembles the conditional guidance bullets and feeds
     them in as template variables; the prose itself (and any future edits)
     stay in the markdown file alongside the other keeper prompts. *)
  let claim_guidance_a =
    if show_claim_guidance then
      "- See unclaimed work and you do not already hold a task? Call keeper_task_claim with {}. \
       It auto-claims the next eligible task; you do not need task_id or keeper_tasks_list first.\n"
    else ""
  in
  let claim_guidance_b =
    if show_claim_guidance then
      "- Need GitHub or PR inspection via keeper_shell op=gh? Claim first. \
       gh repo context is derived from your active task worktree/current_task_id.\n"
    else ""
  in
  let turn_intent_substitutions =
    [
      ("board_activity_guidance", board_activity_guidance);
      ("claim_guidance_a", claim_guidance_a);
      ("claim_guidance_b", claim_guidance_b);
      ("board_post_guidance", board_post_guidance);
      ("board_curation_guidance", board_curation_guidance);
      ("broadcast_guidance", broadcast_guidance);
      ("state_block_instruction", state_block_instruction_text);
    ]
  in
  let turn_intent_block =
    match
      Prompt_registry.render_prompt_template Keeper_prompt_names.turn_intent
        turn_intent_substitutions
    with
    | Ok value -> String.trim value
    | Error _ ->
        String.trim
          (Prompt_registry.get_prompt Keeper_prompt_names.turn_intent)
  in
  let system_prompt =
    Printf.sprintf "%s\n\n## Turn Intent\n%s" base_system_prompt turn_intent_block
  in
  (* User message: structured world observation — reactive triggers + resource state only.
     Metacognition sections (tool activity, cycle outcome, diversity, behavioral stats)
     removed in #6814; telemetry preserved in decision_audit and independent paths. *)
  let ubuf = Buffer.create 1024 in
  Buffer.add_string ubuf "## Current World State\n\n";
  (* Prefix-cache ordering: emit larger, more stable sections first so
     providers can reuse a longer shared prefix across cycles. Highly
     volatile reactive signals stay later in the same user message. *)
  (* 1. Active goals — stable turn context *)
  if observation.active_goals <> [] then (
    Buffer.add_string ubuf
      (Printf.sprintf "### Active Goals (%d)\n"
         (List.length observation.active_goals));
    Buffer.add_string ubuf (format_goals observation.active_goals);
    Buffer.add_string ubuf "\n\n");
  (* 2. Namespace state — usually lower churn than inbox/board detail *)
  if
    observation.unclaimed_task_count > 0
    || observation.claimable_task_count > 0
    || observation.failed_task_count > 0
    || observation.active_agent_count > 0
  then (
    Buffer.add_string ubuf "### Namespace State\n";
    if observation.unclaimed_task_count > 0 then
      Buffer.add_string ubuf
        (Printf.sprintf "- Unclaimed tasks: %d\n"
           observation.unclaimed_task_count);
    if observation.claimable_task_count > 0 then
      Buffer.add_string ubuf
        (Printf.sprintf "- Claimable tasks for this keeper: %d\n"
           observation.claimable_task_count);
    if observation.unclaimed_task_count > 0
       && observation.claimable_task_count = 0
    then
      Buffer.add_string ubuf
        "- Claimable tasks for this keeper: 0\n";
    if observation.failed_task_count > 0 then
      Buffer.add_string ubuf
        (Printf.sprintf "- Failed tasks: %d\n" observation.failed_task_count);
    Buffer.add_string ubuf
      (Printf.sprintf "- Active agents: %d\n" observation.active_agent_count);
    Buffer.add_char ubuf '\n');
  (* 3. Context health — stable resource framing *)
  Buffer.add_string ubuf
    (Printf.sprintf "### Context\n- Utilization: %.0f%%\n- Idle: %ds\n"
       (observation.context_ratio *. 100.0)
       observation.idle_seconds);
  (match observation.last_turn_budget with
   | Some (used, total) when used > 0 ->
     Buffer.add_string ubuf
       (Printf.sprintf "- Previous turn budget: %d/%d used\n" used total)
   | _ -> ());
  (match observation.economic_pressure with
   | Agent_economy.Normal -> ()
   | Frugal ->
       Buffer.add_string ubuf "- Economy: Frugal (reduce token usage)\n"
   | Hustle ->
        Buffer.add_string ubuf
          "- Economy: Hustle (minimize actions, conserve budget)\n");
  (* 4. Autonomous trigger — lower churn than reactive inboxes *)
  let turn_decision =
    Keeper_world_observation.keeper_cycle_decision ~meta observation
  in
  let autonomous_trigger =
    autonomous_trigger_lines ~decision:turn_decision ~observation
  in
  if autonomous_trigger <> [] then (
    Buffer.add_string ubuf "\n### Autonomous Trigger\n";
    Buffer.add_string ubuf (String.concat "\n" autonomous_trigger);
    Buffer.add_char ubuf '\n');
  (* 5. Continuity — usually large and moderately stable, so keep it
     before highly volatile reactive sections for better prefix reuse.
     Inject only forward-looking fields (Goal, Next plan, Next, OpenQuestions,
     Constraints). Backward-looking fields (Done, Progress, Decisions) are
     stripped to avoid a prose-level echo loop where the LLM re-reads its own
     prior narrative and reproduces a near-identical one. The full summary
     remains persisted in meta.continuity_summary for audit. *)
  let continuity_for_prompt =
    Keeper_memory_policy.filter_forward_looking_summary
      observation.continuity_summary
  in
  if
    continuity_for_prompt <> ""
    && observation.continuity_summary <> "No continuity snapshot available."
  then (
    Buffer.add_string ubuf "\n### Continuity\n";
    Buffer.add_string ubuf
      "- Advisory only: ignore prior silence/wait directives until you re-verify them against the live world state.\n";
    Buffer.add_string ubuf
      "- If this turn was still scheduled or backlog/worktree signals remain, investigate that mismatch instead of echoing the prior idle conclusion.\n";
    Buffer.add_string ubuf continuity_for_prompt;
    Buffer.add_char ubuf '\n');
  (* 6. Pending mentions — reactive trigger *)
  if observation.pending_mentions <> [] then (
    Buffer.add_string ubuf
      (Printf.sprintf "### Pending Mentions (%d)\n"
         (List.length observation.pending_mentions));
    Buffer.add_string ubuf (format_mentions observation.pending_mentions);
    Buffer.add_string ubuf "\n\n");
  (* 7. Scope messages — reactive trigger *)
  if observation.pending_scope_messages <> [] then (
    Buffer.add_string ubuf
      (Printf.sprintf "### Scope Messages (%d recent)\n"
         (List.length observation.pending_scope_messages));
    Buffer.add_string ubuf
      (format_scope_messages observation.pending_scope_messages);
    Buffer.add_string ubuf "\n\n");
  (* 8. Immediate task move — reactive operational guidance *)
  if show_claim_guidance then (
    Buffer.add_string ubuf "### Immediate Task Move\n";
    Buffer.add_string ubuf
      "- Call keeper_task_claim with {} to claim the next eligible unclaimed task.\n";
    Buffer.add_string ubuf
      "- Do not wait for keeper_tasks_list unless the claim call says no eligible task.\n";
    Buffer.add_string ubuf
      "- Prefer keeper_task_claim before keeper_board_list or keeper_shell when you have no claimed task.\n";
    Buffer.add_string ubuf
      "- If you need keeper_shell op=gh, claim first so gh can derive repo context from your active task worktree/current_task_id.\n\n");
  (* 9. Board activity — reactive trigger *)
  if observation.pending_board_events <> [] then (
    Buffer.add_string ubuf
      (Printf.sprintf "### Board Activity (%d new)\n"
         (List.length observation.pending_board_events));
    Buffer.add_string ubuf (format_board_events observation.pending_board_events);
    if
      tool_allowed "keeper_board_curation_submit"
      && List.length observation.pending_board_events >= 2
    then
      Buffer.add_string ubuf
        "\n- Curation due: after reading enough context, call keeper_board_curation_submit with a concise snapshot for this board window.";
    Buffer.add_string ubuf "\n\n");
  (* 10. Live worktree delta — actionable change signal *)
  (match observation.worktree_change_summary with
   | Some summary when String.trim summary <> "" ->
       Buffer.add_string ubuf "\n### Live Worktree Delta\n";
       Buffer.add_string ubuf summary;
       Buffer.add_char ubuf '\n'
   | _ -> ());
  let user_message =
    Buffer.contents ubuf
  in
  (system_prompt, user_message)
