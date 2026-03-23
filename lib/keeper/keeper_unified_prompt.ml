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

let autonomy_level_description (level : string) : string =
  match String.lowercase_ascii (String.trim level) with
  | "l1_reactive" -> "L1 Reactive: respond to mentions only"
  | "l2_suggestive" -> "L2 Suggestive: generate suggestions, post to board"
  | "l3_guided" -> "L3 Guided: auto-execute safe actions (read-only + board)"
  | "l4_autonomous" -> "L4 Autonomous: auto-execute most actions including bash"
  | "l5_independent" -> "L5 Independent: full autonomy, all tools available"
  | other -> Printf.sprintf "%s: custom autonomy level" other

let build_prompt ~(meta : Keeper_types.keeper_meta)
    ~(observation : Keeper_world_observation.world_observation) : string * string
    =
  let buf = Buffer.create 2048 in
  (* Identity *)
  Buffer.add_string buf
    (Printf.sprintf "You are %s, a resident keeper agent.\n" meta.name);
  (* Soul profile *)
  if meta.soul_profile <> "" then
    Buffer.add_string buf
      (Printf.sprintf "Soul profile: %s\n" meta.soul_profile);
  (* Will / Needs / Desires *)
  if meta.will <> "" then
    Buffer.add_string buf (Printf.sprintf "Will: %s\n" meta.will);
  if meta.needs <> "" then
    Buffer.add_string buf (Printf.sprintf "Needs: %s\n" meta.needs);
  if meta.desires <> "" then
    Buffer.add_string buf (Printf.sprintf "Desires: %s\n" meta.desires);
  (* Instructions *)
  if meta.instructions <> "" then
    Buffer.add_string buf
      (Printf.sprintf "\nInstructions:\n%s\n" meta.instructions);
  (* Goal horizons *)
  Buffer.add_string buf "\n";
  if meta.goal <> "" then
    Buffer.add_string buf (Printf.sprintf "Primary goal: %s\n" meta.goal);
  if meta.short_goal <> "" && meta.short_goal <> meta.goal then
    Buffer.add_string buf
      (Printf.sprintf "Short-term goal: %s\n" meta.short_goal);
  if meta.mid_goal <> "" && meta.mid_goal <> meta.goal then
    Buffer.add_string buf
      (Printf.sprintf "Mid-term goal: %s\n" meta.mid_goal);
  if meta.long_goal <> "" && meta.long_goal <> meta.goal then
    Buffer.add_string buf
      (Printf.sprintf "Long-term goal: %s\n" meta.long_goal);
  (* Autonomy *)
  Buffer.add_string buf
    (Printf.sprintf "\nAutonomy: %s\n"
       (autonomy_level_description observation.autonomy_level));
  (* Behavioral guidance *)
  Buffer.add_string buf
    "\n\
     ## Behavior\n\
     You have tools available. Use them when appropriate.\n\
     Decide what to do based on the current world state below.\n\
     Possible actions:\n\
     - Reply to pending mentions (use room broadcast tools)\n\
     - Work on active goals (use planning/execution tools)\n\
     - Proactive observation (post findings to board)\n\
     - Search knowledge library (keeper_library_search/read) for research references\n\
     - Do nothing if the situation warrants it (respond with brief reasoning)\n\n\
     When making claims or decisions, search the library first if relevant documents may exist.\n\
     Do NOT explain your decision-making process at length.\n\
     Act directly or state briefly why you chose not to act.\n";
  let system_prompt = Buffer.contents buf in
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
  (* Triage triggers *)
  let tt = String.trim observation.triage_triggers in
  if tt <> "" && not (String.length tt >= 5 && String.sub tt 0 5 = "skip:")
  then (
    Buffer.add_string ubuf
      (Printf.sprintf "\n### Triage Triggers\n%s\n" tt));
  let user_message = Buffer.contents ubuf in
  (system_prompt, user_message)
