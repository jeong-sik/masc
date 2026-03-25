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

let line_block label value =
  if value = "" then ""
  else Printf.sprintf "%s: %s\n" label value

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
          ("identity_header", Printf.sprintf "You are %s, a resident keeper agent." meta.name);
          ("trait_lines", trait_lines);
          ("instructions_block", instructions_block);
          ("goal_lines", goal_lines);
        ]
    with
    | Ok value -> value
    | Error _ -> Prompt_registry.get_prompt "keeper.unified.system"
  in
  let turn_intent_block =
    match observation.autonomy_trigger with
    | Some "mention_reactive" ->
        "This is a reactive turn caused by a direct mention.\n\
         You must either reply directly, take one outward action, or emit `SKIP: <reason>` if action is impossible."
    | Some "board_reactive" ->
        "This is a reactive turn caused by relevant board activity.\n\
         You must engage the board item, advance a related task, or emit `SKIP: <reason>` if action is impossible."
    | Some "task_reactive" ->
        "This is a reactive turn caused by task pressure.\n\
         You must claim, inspect, broadcast a concrete next step, or emit `SKIP: <reason>` if action is impossible."
    | Some "proactive_idle" ->
        "This is a proactive idle-recovery turn.\n\
         Advance a goal, publish a concise check-in, or report a concrete blocker. Avoid generic status chatter."
    | Some other ->
        Printf.sprintf
          "This autonomous turn was triggered by `%s`.\n\
           Take one concrete next step or emit `SKIP: <reason>` if action is impossible."
          other
    | None ->
        "No autonomous trigger is active. If no concrete action is justified, keep the turn minimal."
  in
  let system_prompt =
    Printf.sprintf "%s\n\n## Turn Intent\n%s" base_system_prompt turn_intent_block
  in
  (* User message: structured world observation *)
  let ubuf = Buffer.create 1024 in
  Buffer.add_string ubuf "## Current World State\n\n";
  (match observation.autonomy_trigger with
   | Some trigger ->
       Buffer.add_string ubuf
         (Printf.sprintf "### Autonomous Trigger\n- %s\n- No-op allowed: %s\n\n"
            trigger
            (if observation.allow_noop then "yes" else "no"))
   | None -> ());
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
    List.iter
      (fun event -> Buffer.add_string ubuf (Printf.sprintf "- %s\n" event))
      observation.pending_board_events;
    Buffer.add_string ubuf "\n");
  (* Context health *)
  Buffer.add_string ubuf
    (Printf.sprintf "### Context\n- Utilization: %.0f%%\n- Idle: %ds\n"
       (observation.context_ratio *. 100.0)
       observation.idle_seconds);
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
  (* Triage triggers — when present, signal urgency to the model *)
  let tt = String.trim observation.triage_triggers in
  if tt <> "" && not (String.length tt >= 5 && String.sub tt 0 5 = "skip:")
  then (
    let trigger_list =
      String.split_on_char ',' tt
      |> List.map String.trim
      |> List.filter (fun s -> s <> "")
    in
    Buffer.add_string ubuf "\n### Action Triggers (triage)\n";
    Buffer.add_string ubuf "The following conditions require your attention:\n";
    List.iter (fun t ->
      Buffer.add_string ubuf (Printf.sprintf "- %s\n" t)
    ) trigger_list;
    Buffer.add_string ubuf "Prioritize responding to these before passive observation.\n");
  let user_message = Buffer.contents ubuf in
  (system_prompt, user_message)
