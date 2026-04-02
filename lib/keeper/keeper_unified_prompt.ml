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

let format_board_events
    (events : Keeper_world_observation.pending_board_event list) : string =
  String.concat "\n"
    (List.map
       (fun (event : Keeper_world_observation.pending_board_event) ->
         let kind =
           match event.post_kind with
           | Board.Human_post -> "human"
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
        line_block "Soul profile" meta.soul_profile;
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
      Prompt_registry.render_prompt_template "keeper.unified.system"
        [
          ("identity_header", Printf.sprintf "You are %s, a keeper agent." meta.name);
          ("trait_lines", trait_lines);
          ("instructions_block", instructions_block);
          ("goal_lines", goal_lines);
        ]
    with
    | Ok value -> value
    | Error _ -> Prompt_registry.get_prompt "keeper.unified.system"
  in
  let turn_intent_block =
    "Use the world state below as raw context.\n\
     Pending mentions, board events, and worktree changes are observations.\n\
     Focus on one observation and one action per cycle. \
     Your checkpoint survives across cycles — do not rush to finish everything now.\n\
     Unclaimed tasks in the backlog are actionable work — if your skills match, \
     claim one with keeper_task_claim and work on it.\n\
     When you have findings, opinions, or status updates worth sharing, post them to the board \
     using keeper_board_post. When responding to board activity, use keeper_board_comment.\n\
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
  (* Active goals *)
  if observation.active_goals <> [] then (
    Buffer.add_string ubuf
      (Printf.sprintf "### Active Goals (%d)\n"
         (List.length observation.active_goals));
    Buffer.add_string ubuf (format_goals observation.active_goals);
    Buffer.add_string ubuf "\n\n");
  (* Room state *)
  if
    observation.unclaimed_task_count > 0
    || observation.failed_task_count > 0
    || observation.active_agent_count > 0
  then (
    Buffer.add_string ubuf "### Room State\n";
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
        Buffer.add_string ubuf "### Room Signal Interpretation\n";
        Buffer.add_string ubuf
          (Printf.sprintf "- room_signal_primary: %s\n"
             (format_room_signal_salience interpretation.primary_salience));
        (match interpretation.secondary_saliences with
         | [] -> ()
         | secondary ->
             Buffer.add_string ubuf
               (Printf.sprintf "- room_signal_secondary: %s\n"
                  (secondary
                  |> List.map format_room_signal_salience
                  |> String.concat ", ")));
        Buffer.add_string ubuf
          (Printf.sprintf "- room_signal_reason: %s\n" interpretation.reason);
        (match interpretation.target_id with
         | Some target_id ->
             Buffer.add_string ubuf
               (Printf.sprintf "- room_signal_target_id: %s\n" target_id)
         | None -> ());
        (match interpretation.evidence_refs with
         | [] -> ()
         | refs ->
             Buffer.add_string ubuf
               (Printf.sprintf "- room_signal_evidence_refs: %s\n"
                  (String.concat ", " refs)));
        (match observation.room_signal_digest_ref with
         | Some digest ->
             Buffer.add_string ubuf
               (Printf.sprintf "- room_digest_post_id: %s\n" digest.post_id);
             Buffer.add_string ubuf
               (Printf.sprintf "- room_digest_title: %s\n" digest.title)
         | None -> ());
        Buffer.add_string ubuf
          "- room_signal_guard: do not call keeper_board_post or keeper_task_claim from this derived signal alone; read at least one raw board item from room_signal_evidence_refs or room_digest_post_id first.\n\n"
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
  let user_message = Buffer.contents ubuf in
  (system_prompt, user_message)
