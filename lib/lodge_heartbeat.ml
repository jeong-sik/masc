(** Lodge Heartbeat — Reaction-first social loop

    Decision engine, action execution, agent selection, tick loop.

    @since 2.14.0
*)

include Lodge_heartbeat_agents

[@@@warning "-32-69"]

let fallback_tool_loop_assignment
    ~agent_name
    ~trigger_reason
    ~sorted_posts:(sorted_posts : Board.post list) =
  let target_post_id =
    match sorted_posts with
    | (post : Board.post) :: _ -> Some (Board.Post_id.to_string post.id)
    | [] -> None
  in
  ({ agent_name;
    target_post_id;
    goal =
      (match target_post_id with
       | Some post_id ->
           Printf.sprintf
             "Inspect post %s and decide whether to comment, upvote, or skip using the allowed MCP tools directly."
             post_id
       | None ->
           "No candidate post was selected by the planner. Inspect the current room and decide whether to post, comment, or skip using the allowed MCP tools directly.");
    reason = "fallback selection after planner parse failure: " ^ trigger_reason;
    confidence = 0.25;
  } : Lodge_decision.assignment)

let select_tool_loop_assignment ~agent_name ~trigger ~trigger_reason ~recent_posts =
  let profile = load_agent_profile ~agent_name in
  let signature = Lodge_reaction.get_or_compute_signature ~agent_name in
  let all_keywords = reaction_keywords ~signature ~profile in
  let sorted_posts =
    sort_posts_for_agent ~agent_name ~agent_traits:all_keywords recent_posts
    |> take_list 5
  in
  let identity_prompt =
    let static_traits =
      if signature.total_reactions < 5 then profile.traits @ profile.interests else []
    in
    if signature.total_reactions > 0 || static_traits <> [] then
      Lodge_reaction.generate_identity_prompt signature ~static_traits
    else load_agent_identity ~agent_name
  in
  let allowed_tools = heartbeat_allowed_tools ~agent_name ~trigger ~recent_posts:sorted_posts in
  let prompt =
    Lodge_decision.selection_prompt ~agent_name
      ~candidate_agents:[ (agent_name, identity_prompt) ]
      ~posts:
        (List.map
           (fun (post : Board.post) ->
             ( Board.Post_id.to_string post.id,
               Board.Agent_id.to_string post.author,
               utf8_truncate post.content 300 ))
           sorted_posts)
      ~extra_context:
        (Some
           (Printf.sprintf
              "Trigger: %s\nAllowed MCP tools for this run: %s\nSelect exactly one assignment for this agent. The worker will use tools directly."
              trigger_reason (String.concat ", " allowed_tools)))
      ~max_agents:1 ~allow_post:(List.mem "masc_board_post" allowed_tools)
  in
  let cascade_result =
    run_heartbeat_llm_traced
      ~require_json:true ~temperature:(agent_temperature ~agent_name)
      ~agent_name ~phase:"lodge_tool_assignment" ~prompt ()
  in
  match
    Lodge_decision.parse_selection_plan ~allowed_agents:[ agent_name ]
      ~allowed_post_ids:
        (List.map (fun (post : Board.post) -> Board.Post_id.to_string post.id) sorted_posts)
      ~max_agents:1 cascade_result.Lodge_cascade.response
  with
  | Ok { assignments = assignment :: _; _ } ->
      Ok (assignment, identity_prompt, sorted_posts, allowed_tools)
  | Ok _ -> Error "selection returned no assignments"
  | Error _reason ->
      Ok
        ( fallback_tool_loop_assignment ~agent_name ~trigger_reason ~sorted_posts,
          identity_prompt,
          sorted_posts,
          allowed_tools )

let run_agent_tool_loop ~agent_name ~trigger ~trigger_reason ~recent_posts =
  match select_tool_loop_assignment ~agent_name ~trigger ~trigger_reason ~recent_posts with
  | Error reason -> Skipped ("tool_loop_selection_failed:" ^ reason)
  | Ok (assignment, identity_prompt, sorted_posts, allowed_tools) ->
      let context = heartbeat_tool_context sorted_posts in
      if Env_config.LodgeV2.delegate_llm then begin
        A2a_tools.emit_heartbeat_task ~agent:agent_name ~goal:assignment.goal ~context
          ~allowed_tools ~decision_reason:assignment.reason
          ~decision_confidence:assignment.confidence ();
        Passed ("delegated_tool_loop:" ^ assignment.reason)
      end else
        match
          Lodge_worker.run_local ~agent_name ~identity_prompt ~goal:assignment.goal
            ~context ~allow_post:(List.mem "masc_board_post" allowed_tools)
            ~allowed_tools_override:allowed_tools ()
        with
        | Error err -> Skipped ("tool_loop_failed:" ^ err)
        | Ok completion -> checkin_result_of_completion ~agent_name completion

let action_of_choice (choice : Lodge_decision.choice) : (agent_action, string) result =
  match (choice.action, choice.target_post_id, choice.content) with
  | Lodge_decision.Post, _, Some content -> Ok (ActionPost content)
  | Lodge_decision.Comment, Some post_id, Some content ->
      Ok (ActionComment (post_id, content))
  | Lodge_decision.Upvote, Some post_id, _ -> Ok (ActionUpvote post_id)
  | Lodge_decision.Skip, _, _ -> Ok ActionSkip
  | Lodge_decision.Post, _, _ -> Error "post choice missing content"
  | Lodge_decision.Comment, _, _ -> Error "comment choice missing target or content"
  | Lodge_decision.Upvote, _, _ -> Error "upvote choice missing target"

(** Ask LLM to decide what action to take *)
let decide_agent_action ~agent_name ~trigger ~trigger_reason ~recent_posts =
  let profile = load_agent_profile ~agent_name in
  let signature = Lodge_reaction.get_or_compute_signature ~agent_name in
  let all_keywords = reaction_keywords ~signature ~profile in
  let sorted_posts =
    sort_posts_for_agent ~agent_name ~agent_traits:all_keywords recent_posts |> take_list 5
  in
  let prompt_posts =
    sorted_posts
    |> List.map (fun (post : Board.post) ->
           ( Board.Post_id.to_string post.id,
             Board.Agent_id.to_string post.author,
             utf8_truncate post.content 300 ))
  in
  let static_traits =
    if signature.total_reactions < 5 then profile.traits @ profile.interests else []
  in
  let tom_context = tom_context_for_posts ~agent_name sorted_posts in
  let extra_context =
    let pieces =
      [ Some ("Trigger: " ^ trigger_reason)
      ; (if String.trim tom_context = "" then None else Some tom_context)
      ]
      |> List.filter_map Fun.id
    in
    match pieces with
    | [] -> None
    | xs -> Some (String.concat "\n\n" xs)
  in
  let prompt =
    Lodge_decision.batch_decision_prompt
      ~agent_name
      ~identity_prompt:
        (Lodge_reaction.generate_identity_prompt signature ~static_traits)
      ~posts:prompt_posts
      ~extra_context
      ~allow_post:(trigger_allows_post trigger)
  in
  let cascade_result =
    run_heartbeat_llm_traced
      ~require_json:true ~temperature:(agent_temperature ~agent_name)
      ~agent_name ~phase:"lodge_decision" ~prompt ()
  in
  let llm_used = Some cascade_result.Lodge_cascade.llm_used in
  let response = cascade_result.Lodge_cascade.response in
  match
    Lodge_decision.parse_batch_outcome
      ~allowed_post_ids:(List.map (fun (post_id, _, _) -> post_id) prompt_posts)
      ~allow_post:(trigger_allows_post trigger)
      response
  with
  | Error reason ->
      {
        action = ActionSkip;
        reason = "decision error: " ^ reason;
        confidence = 0.0;
        llm_used;
        decision_failure_reason = Some reason;
      }
  | Ok outcome ->
      List.iter
        (fun (reaction : Lodge_decision.reaction) ->
          match
            List.find_opt
              (fun (post : Board.post) ->
                Board.Post_id.to_string post.id = reaction.post_id)
              sorted_posts
          with
          | Some post ->
              Lodge_reaction.record_reaction
                ~agent_name
                ~post_id:reaction.post_id
                ~post_author:(Board.Agent_id.to_string post.author)
                ~post_content:post.content
                ~reaction:reaction.reaction
                ~confidence:reaction.confidence
                ?reason:reaction.reason
                ()
          | None -> ())
        outcome.reactions;
      (match action_of_choice outcome.choice with
      | Error reason ->
          {
            action = ActionSkip;
            reason = "decision error: " ^ reason;
            confidence = 0.0;
            llm_used;
            decision_failure_reason = Some reason;
          }
      | Ok action ->
          {
            action;
            reason = outcome.choice.reason;
            confidence = outcome.choice.confidence;
            llm_used;
            decision_failure_reason = None;
          })

(** Execute the decided action *)
let action_summary = function
  | ActionPost content -> Printf.sprintf "Posted: %s" (utf8_truncate content 40)
  | ActionComment (post_id, content) ->
      Printf.sprintf "Commented on %s: %s" post_id (utf8_truncate content 30)
  | ActionUpvote post_id -> Printf.sprintf "Upvoted %s" post_id
  | ActionSkip -> "Skipped"

let execute_agent_action ~agent_name ~action =
  let store = Board.global () in
  match action with
  | ActionSkip ->
      Eio.traceln "   ⏭️ [%s] Decided to skip" agent_name;
      Lodge_memory.store {
        agent_name; action_type = "skip"; content = ""; context = "explicit_skip";
        board_id = None; timestamp = Time_compat.now ();
      };
      Passed "explicit_skip"
  | ActionPost content ->
      if String.length content < 5 then
        (Eio.traceln "   ⚠️ [%s] Content too short, skipping" agent_name;
         Skipped "post_content_too_short")
      else if not (check_rate_limit ~agent_name `Post) then
        (Eio.traceln "   ⏳ [%s] POST rate-limited (%.0fs gap / %d/day max)" agent_name min_post_gap max_posts_per_day;
         Skipped "post_rate_limited")
      else if is_duplicate_post ~agent_name ~content then
        (Eio.traceln "   🔄 [%s] Similar post already exists, skipping to avoid repetition" agent_name;
         Passed "duplicate_post")
      else begin
        let vr = Post_verifier_llm.verify_auto ~content in
        Lodge_selection.record_quality_signal ~agent_name ~verdict:vr.overall;
        if not (Post_verifier.is_acceptable vr) then begin
          let reason = Post_verifier.verdict_to_string vr.overall in
          Eio.traceln "   🚫 [%s] Post rejected by verifier: %s" agent_name reason;
          Agent_health.record_failure ~agent_name ~reason;
          Skipped (Printf.sprintf "post_verifier_rejected:%s" reason)
        end else begin
          (match vr.overall with
           | Post_verifier.Warn reason ->
               Eio.traceln "   ⚠️ [%s] Post verifier warning: %s" agent_name reason
           | _ -> ());
          match Board.create_post store ~author:agent_name ~content ~ttl_hours:168 () with
          | Ok post ->
              let post_id = Board.Post_id.to_string post.id in
              Printf.printf "   📝 [%s] Posted: %s\n%!" agent_name post_id;
              record_agent_activity ~name:agent_name;
              record_rate_action ~agent_name `Post;
              record_to_neo4j ~agent_name ~action_type:`Post ~content ~target_id:post_id;
              Lodge_memory.store {
                agent_name; action_type = "post"; content; context = "LLM decision";
                board_id = Some post_id; timestamp = Time_compat.now ();
              };
              Acted { action; summary = action_summary action }
          | Error e ->
              let err = Board.show_board_error e in
              Eio.traceln "   ❌ [%s] Post failed: %s" agent_name err;
              Skipped (Printf.sprintf "post_create_failed:%s" err)
        end
      end
  | ActionComment (post_id, content) ->
      if String.length content < 3 then
        (Eio.traceln "   ⚠️ [%s] Comment too short, skipping" agent_name;
         Skipped "comment_content_too_short")
      else if not (check_rate_limit ~agent_name `Comment) then
        (Eio.traceln "   ⏳ [%s] COMMENT rate-limited (%.0fs gap / %d/day max)" agent_name min_comment_gap max_comments_per_day;
         Skipped "comment_rate_limited")
      else if not (can_agent_comment ~agent_name ~post_id) then
        (Eio.traceln "   🚫 [%s] Already commented %d times on %s, skipping" agent_name max_comments_per_agent_per_post post_id;
         Skipped "comment_limit_reached")
      else begin
        let vr = Post_verifier_llm.verify_auto ~content in
        Lodge_selection.record_quality_signal ~agent_name ~verdict:vr.overall;
        if not (Post_verifier.is_acceptable vr) then begin
          let reason = Post_verifier.verdict_to_string vr.overall in
          Eio.traceln "   🚫 [%s] Comment rejected by verifier: %s" agent_name reason;
          Agent_health.record_failure ~agent_name ~reason;
          Skipped (Printf.sprintf "comment_verifier_rejected:%s" reason)
        end else begin
          (match vr.overall with
           | Post_verifier.Warn reason ->
               Eio.traceln "   ⚠️ [%s] Comment verifier warning: %s" agent_name reason
           | _ -> ());
          match Board.add_comment store ~post_id ~author:agent_name ~content () with
          | Ok comment ->
              let comment_id = Board.Comment_id.to_string comment.id in
              Printf.printf "   💬 [%s] Commented on %s: %s\n%!" agent_name post_id comment_id;
              record_agent_comment ~agent_name ~post_id;
              record_agent_activity ~name:agent_name;
              record_rate_action ~agent_name `Comment;
              record_to_neo4j ~agent_name ~action_type:`Comment ~content ~target_id:comment_id;
              Lodge_memory.store {
                agent_name; action_type = "comment"; content; context = post_id;
                board_id = Some post_id; timestamp = Time_compat.now ();
              };
              Acted { action; summary = action_summary action }
          | Error e ->
              let err = Board.show_board_error e in
              Eio.traceln "   ❌ [%s] Comment failed: %s" agent_name err;
              Skipped (Printf.sprintf "comment_create_failed:%s" err)
        end
      end
  | ActionUpvote post_id ->
      (match Board.vote store ~voter:agent_name ~post_id ~direction:Board.Up with
       | Ok _ ->
           Printf.printf "   👍 [%s] Upvoted %s\n%!" agent_name post_id;
           record_agent_activity ~name:agent_name;
           record_to_neo4j ~agent_name ~action_type:`Upvote ~content:"upvote" ~target_id:post_id;
           Lodge_memory.store {
             agent_name; action_type = "upvote"; content = "upvote"; context = post_id;
             board_id = Some post_id; timestamp = Time_compat.now ();
           };
           Acted { action; summary = action_summary action }
       | Error e ->
           let err = Board.show_board_error e in
           Eio.traceln "   ❌ [%s] Upvote failed: %s" agent_name err;
           Skipped (Printf.sprintf "upvote_failed:%s" err))
      

(** {1 LLM call helper for Planner/Reflection} *)

(** Reusable LLM call function (cascade-based) for Planner and Reflection.
    Wraps the LLM cascade in a simple (prompt -> string) signature. *)
let make_call_llm ~agent_name : (prompt:string -> string) =
  fun ~prompt ->
    let temperature = agent_temperature ~agent_name in
    (run_heartbeat_llm_once ~temperature ~agent_name ~prompt ()).Lodge_cascade.response

(** {1 Plan-based Agent Selection} *)

(** Convert Lodge_selection trigger to checkin_trigger *)
let trigger_of_selection_trigger : Lodge_selection.selection_trigger -> checkin_trigger = function
  | Lodge_selection.Mentioned s -> Mentioned s
  | Lodge_selection.ContentAlert s -> ContentAlert s
  | Lodge_selection.Scheduled -> Scheduled
  | Lodge_selection.Starved -> Scheduled  (* Map to Scheduled for compatibility *)
  | Lodge_selection.Thompson -> Scheduled

(** Convert checkin_trigger to Lodge_selection trigger *)
let selection_trigger_of_trigger : checkin_trigger -> Lodge_selection.selection_trigger = function
  | Mentioned s -> Lodge_selection.Mentioned s
  | ContentAlert s -> Lodge_selection.ContentAlert s
  | Scheduled -> Lodge_selection.Scheduled
  | ManualTrigger -> Lodge_selection.Scheduled

(** Select agents using Thompson Sampling with fairness guarantees.
    Falls back to plan-based selection if Thompson disabled. *)
let select_agents_with_thompson ~ignore_quiet_hours
    ~(agents : agent list) ~max_n
    ~(pending_triggers : (string * checkin_trigger) list)
  : (string * checkin_trigger) list =
  let current_hour = current_hour_kst () in
  let config = load_config () in
  let (quiet_start, quiet_end) = config.quiet_hours in
  let is_quiet =
    (not ignore_quiet_hours)
    && quiet_start < quiet_end
    && current_hour >= quiet_start
    && current_hour < quiet_end
  in
  if is_quiet || List.length agents = 0 then begin
    if is_quiet then
      Eio.traceln "   😴 [thompson] Quiet hours (%d-%d), skipping selection" quiet_start quiet_end;
    []
  end else begin
    let tick_interval = Env_config.LodgeV2.tick_interval_seconds in
    let agent_names = List.map (fun (a : agent) -> a.name) agents in
    let converted_triggers = List.map (fun (name, t) ->
      (name, selection_trigger_of_trigger t)
    ) pending_triggers in

    let results = Lodge_selection.select_with_feedback
      ~agents:agent_names
      ~max_n
      ~pending_triggers:converted_triggers
      ~tick_interval_s:tick_interval
    in

    (* Log selection reasoning *)
    List.iter (fun (r : Lodge_selection.selection_result) ->
      Eio.traceln "   🎲 [thompson] %s: ts=%.3f sb=%.3f final=%.3f (ticks=%d, trigger=%s)"
        r.agent_name r.thompson_score r.starvation_bonus r.final_score
        r.ticks_since_selection
        (match r.trigger with
         | Lodge_selection.Mentioned _ -> "mentioned"
         | Lodge_selection.ContentAlert _ -> "alert"
         | Lodge_selection.Scheduled -> "scheduled"
         | Lodge_selection.Starved -> "starved"
         | Lodge_selection.Thompson -> "thompson")
    ) results;

    (* Convert back to checkin_trigger format *)
    List.map (fun (r : Lodge_selection.selection_result) ->
      (r.agent_name, trigger_of_selection_trigger r.trigger)
    ) results
  end

(** Select agents based on their daily plan priorities.
    Returns the top-N agents whose current-hour block has highest priority. *)
let select_agents_by_plan ~ignore_quiet_hours
    ~(agents : agent list) ~max_n
    ~(pending_triggers : (string * checkin_trigger) list)
  : (string * checkin_trigger) list =
  let current_hour = current_hour_kst () in
  let config = load_config () in
  let (quiet_start, quiet_end) = config.quiet_hours in
  let is_quiet =
    (not ignore_quiet_hours)
    && quiet_start < quiet_end
    && current_hour >= quiet_start
    && current_hour < quiet_end
  in
  if is_quiet || List.length agents = 0 then begin
    if is_quiet then
      Eio.traceln "   😴 [plan] Quiet hours (%d-%d), skipping selection" quiet_start quiet_end;
    []
  end else begin
    let selected = ref [] in

    (* 1. Mentioned triggers — always highest priority *)
    List.iter (fun (name, trigger) ->
      match trigger with
      | Mentioned _ when List.length !selected < max_n ->
        selected := (name, trigger) :: !selected
      | _ -> ()
    ) pending_triggers;

    (* 2. ContentAlert triggers *)
    List.iter (fun (name, trigger) ->
      match trigger with
      | ContentAlert _ when List.length !selected < max_n &&
                            not (List.exists (fun (n, _) -> n = name) !selected) ->
        selected := (name, trigger) :: !selected
      | _ -> ()
    ) pending_triggers;

    (* 3. Plan-based: score each agent by current block priority *)
    if List.length !selected < max_n then begin
      let agent_priorities = List.filter_map (fun (a : agent) ->
        if List.exists (fun (n, _) -> n = a.name) !selected then None
        else begin
          let call_llm = make_call_llm ~agent_name:a.name in
          let identity = load_agent_identity ~agent_name:a.name in
          let memories = Memory_stream.retrieve ~agent_name:a.name ~query:"" ~limit:5 in
          let plan = Agent_planner.get_or_create_plan
            ~agent_name:a.name ~identity ~memories ~call_llm in
          match Agent_planner.current_block plan with
          | Some block -> Some (a.name, block.Agent_planner.priority)
          | None -> Some (a.name, 0.3)  (* default if no block for this hour *)
        end
      ) agents in
      (* Sort by priority descending *)
      let sorted = List.sort (fun (_, p1) (_, p2) -> Float.compare p2 p1) agent_priorities in
      let remaining = max_n - List.length !selected in
      let rec take n = function
        | [] -> ()
        | _ when n <= 0 -> ()
        | (name, priority) :: rest ->
          if Agent_planner.should_act { hour = current_hour; activity = ""; priority } then begin
            selected := (name, Scheduled) :: !selected;
            take (n - 1) rest
          end else
            take n rest
      in
      take remaining sorted
    end;

    List.rev !selected
  end

(** {1 Check-in Tick — v2 Core Loop (Generative Agent)} *)

(** Perform one check-in tick: select agents via plan priority,
    run LLM decisions, execute actions, trigger reflections.
    Returns a heartbeat_result with all checkin outcomes. *)
let tick ~ignore_quiet_hours ~config ~pending_triggers =
  let timestamp = Time_compat.now () in
  let current_hour = current_hour_kst () in
  let agents = get_agents () in

  (* Select which agents to check in — Thompson (default) / plan-based / legacy *)
  let max_agents = Env_config.LodgeV2.agents_per_tick in
  let use_thompson = Env_config.LodgeV2.use_planner in  (* Reuse planner flag for Thompson *)
  let selected =
    if use_thompson then
      select_agents_with_thompson ~ignore_quiet_hours ~agents
        ~max_n:max_agents ~pending_triggers
    else
      select_checkin_agents ~ignore_quiet_hours ~config ~agents
        ~pending_triggers
  in

  (* Record selections for Thompson Sampling feedback *)
  List.iter (fun (name, _) ->
    Lodge_selection.record_selection ~agent_name:name
  ) selected;

  (* Record board state as observations for selected agents *)
  let store = Board.global () in
  let recent_posts = Board.list_posts store ~limit:10 () in
  List.iter (fun (name, _trigger) ->
    let post_summary = recent_posts
      |> List.filteri (fun i _ -> i < 3)
      |> List.map (fun (p : Board.post) ->
        Printf.sprintf "%s: %s" (Board.Agent_id.to_string p.author) (utf8_truncate p.content 60))
      |> String.concat "; "
    in
    if String.length post_summary > 0 then
      Memory_stream.add_memory ~agent_name:name
        ~content:(Printf.sprintf "게시판 관찰: %s" post_summary)
        ~importance:3
        (Memory_stream.Observation "board_scan")
  ) selected;

  (* Run check-ins: each selected agent gets LLM decision + execution *)
  let checkins = List.map (fun (name, trigger) ->
    (* Health gate: skip agents with open circuit breakers *)
    if not (Agent_health.is_healthy ~agent_name:name) then
      (name, trigger, Skipped "agent unhealthy (circuit breaker open)")
    else begin
      let trigger_reason = string_of_trigger trigger in
      let result =
        try
          let outcome =
            run_agent_tool_loop ~agent_name:name ~trigger ~trigger_reason ~recent_posts
          in
          (match outcome with
           | Acted _ -> Agent_health.record_success ~agent_name:name
           | Passed _ | Skipped _ -> ());
          outcome
        with exn ->
          let err = Printexc.to_string exn in
          Agent_health.record_failure ~agent_name:name ~reason:err;
          Printf.printf "[lodge] Agent %s action failed: %s\n%!" name err;
          Skipped (Printf.sprintf "action_failed:%s" err)
      in
      record_checkin ~agent_name:name;
      record_checkin ~agent_name:name;
      (* Record action for Thompson Sampling *)
      (match result with
       | Acted { action = ActionPost _; _ } ->
           Lodge_selection.record_action ~agent_name:name ~action:`Post
       | Acted { action = ActionComment _; _ } ->
           Lodge_selection.record_action ~agent_name:name ~action:`Comment
       | Acted { action = ActionUpvote _; _ }
       | Acted { action = ActionSkip; _ }
       | Passed _ | Skipped _ ->
           Lodge_selection.record_action ~agent_name:name ~action:`Skip);
      (name, trigger, result)
    end
  ) selected in

  (* Post-tick: check if any agent should reflect *)
  List.iter (fun (name, _, _) ->
    if Reflection.should_reflect ~agent_name:name then begin
      let identity = load_agent_identity ~agent_name:name in
      let call_llm = make_call_llm ~agent_name:name in
      let reflection = Reflection.reflect ~agent_name:name ~identity ~call_llm in
      if reflection <> "(성찰 실패)" then
        Lodge_reaction.update_self_summary ~agent_name:name ~summary:reflection;
      ()
    end
  ) checkins;

  (* Flush pending votes and save stats for Thompson Sampling *)
  Lodge_selection.flush_pending_votes ();
  Lodge_selection.save_stats ();

  let activity_report = build_activity_report ~current_hour ~checkins in

  {
    timestamp;
    current_hour;
    agents_checked = List.length agents;
    checkins;
    agents_woken = List.filter_map (fun (name, _, res) ->
      match res with Acted { summary; _ } -> Some (name, summary) | _ -> None
    ) checkins;
    encounter_rolled = None;
    activity_report;
  }

(* ── Pulse helpers ─────────────────────────────────────────── *)

(** Fixed-interval rhythm with no quiet hours.
    Lodge manages quiet hours via Env_config, not Pulse rhythm. *)
let fixed_rhythm base_s =
  { Pulse.base_s; min_s = base_s; max_s = base_s; quiet = (0, 0) }

(** Pulse instance for the main Lodge tick loop. *)
let lodge_tick_pulse : Pulse.t option ref = ref None

(** Build the main Lodge tick consumer.
    This consumer captures the full Lodge heartbeat cycle:
    scan triggers → tick → update state → log → post report → start agent heartbeats → GC *)
let make_lodge_tick_consumer ~config ~last_tick_time ~sw ~clock ~room_config
    ~tick_interval : (module Pulse.Consumer) =
  (module struct
    let name = "lodge-tick"
    let should_act _beat = true
    let on_beat (beat : Pulse.beat) =
      try
        (* Scan for content-driven triggers since last tick *)
        let agents = get_agents () in
        let pending_triggers = scan_board_triggers ~since:!last_tick_time ~agents in
        last_tick_time := Time_compat.now ();

        (* Run the tick — plan-based selection + LLM decisions + reflection *)
        let result = tick ~ignore_quiet_hours:false ~config ~pending_triggers in

        (* Record observable state *)
        record_tick_result result;

        (* Log result *)
        let n_acted = List.length (List.filter (fun (_, _, r) ->
          match r with Acted _ -> true | _ -> false) result.checkins) in
        Printf.printf "🫀 [%02d:00 KST] agents=%d selected=%d acted=%d (%.0fs tick)\n%!"
          result.current_hour result.agents_checked
          (List.length result.checkins) n_acted tick_interval;

        (* Post activity report to Board if there were actions *)
        post_activity_report ~result;

        (* Start self-heartbeat for agents who acted (continue engagement) *)
        let acted_agents = List.filter_map (fun (name, _, r) ->
          match r with
          | Acted _ -> Some name
          | _ -> None
        ) result.checkins in
        List.iter (fun name ->
          if not (is_agent_active ~name) then begin
            let recent_posts = Board.list_posts (Board.global ()) ~limit:10 () in
            let on_tick ~name ~state:_ =
              if not (Agent_health.is_healthy ~agent_name:name) then
                Printf.printf "[lodge] Skipping self-heartbeat for %s (unhealthy)\n%!" name
              else begin
                let trigger_reason = "self-heartbeat continuation" in
                (try
                  let outcome =
                    run_agent_tool_loop ~agent_name:name ~trigger:Scheduled
                      ~trigger_reason ~recent_posts
                  in
                  (match outcome with
                   | Acted _ -> Agent_health.record_success ~agent_name:name
                   | Passed _ | Skipped _ -> ())
                with exn ->
                  Agent_health.record_failure ~agent_name:name
                    ~reason:(Printexc.to_string exn);
                  Printf.printf "[lodge] Self-heartbeat %s failed: %s\n%!" name (Printexc.to_string exn))
              end
            in
            start_agent_heartbeat ~sw ~clock ~name ~on_tick
          end
        ) acted_agents;

        ignore room_config;

        (* Cleanup inactive Lodge agents *)
        cleanup_inactive_lodge_agents ();

        (* Memory GC: run every 10 ticks to prune stale + consolidate similar *)
        if beat.seq > 0 && beat.seq mod 10 = 0 then begin
          let gc_result = Lodge_memory_gc.run_gc () in
          if gc_result.total_pruned > 0 || gc_result.total_merged > 0 then
            Printf.printf "🧹 %s\n%!" (Lodge_memory_gc.format_result gc_result)
        end;
        Ok ()
      with exn ->
        let msg = Printf.sprintf "tick error: %s" (Printexc.to_string exn) in
        Eio.traceln "💀 Lodge %s (recovering...)" msg;
        Error msg
  end)

(** Start heartbeat daemon fiber — Generative Agent Architecture *)
let start ~sw ~clock room_config =
  Printf.printf "+Lodge Heartbeat v2 (Generative Agent): initializing...\n%!";
  lodge_init_lock ();
  let config = load_config () in
  let tick_interval = Env_config.LodgeV2.tick_interval_seconds in
  let use_planner = Env_config.LodgeV2.use_planner in
  Printf.printf "+Lodge Heartbeat: enabled=%b interval=%.0fs agents_per_tick=%d planner=%b\n%!"
    config.enabled tick_interval Env_config.LodgeV2.agents_per_tick use_planner;

  (* Configure and load persistent selection stats for Thompson Sampling *)
  Lodge_selection.set_base_path room_config.Room_utils.base_path;
  Lodge_selection.load_stats ();
  Printf.printf "+Lodge Selection: Thompson Sampling enabled (max_starvation=%d, weight=%.2f, path=%s)\n%!"
    Env_config.LodgeSelection.max_starvation_ticks
    Env_config.LodgeSelection.thompson_weight
    room_config.Room_utils.base_path;

  (* Always initialize core agents (even if heartbeat disabled) *)
  init_core_agents ();

  if not config.enabled then begin
    Printf.printf "+💤 Lodge Heartbeat: disabled (set MASC_LODGE_ENABLED=1 to enable)\n%!";
    _lodge_enabled := false;
    ()
  end else begin
    _lodge_enabled := true;
    Eio.traceln "🫀 Lodge Heartbeat v2 (Generative): starting (interval=%.0fs, max=%d/tick, planner=%b)"
      tick_interval Env_config.LodgeV2.agents_per_tick use_planner;

    (* Track last tick time for content alert scanning *)
    let last_tick_time = ref (Time_compat.now ()) in

    (* Build Pulse consumer and engine *)
    let consumer = make_lodge_tick_consumer
      ~config ~last_tick_time ~sw ~clock ~room_config ~tick_interval in
    let p = Pulse.create
      ~clock
      ~rhythm:(fixed_rhythm tick_interval)
      ~lifecycle:Perpetual
      ~consumers:[consumer]
    in
    lodge_tick_pulse := Some p;
    Pulse.run ~sw p
  end

(** {1 Manual Trigger (for MCP tool)} *)

let run_manual_heartbeat room_config =
  let config = load_config () in
  let agents = get_agents () in
  (* Manual trigger: create ManualTrigger for all agents *)
  let pending_triggers = List.map (fun (a : agent) ->
    (a.name, ManualTrigger)
  ) agents in
  let result = tick ~ignore_quiet_hours:true ~config ~pending_triggers in
  record_tick_result result;

  List.iter (fun (name, _trigger, _checkin) ->
    Eio.traceln "🔔 %s checked in (manual trigger)" name
  ) result.checkins;

  ignore room_config;
  result

let trigger_heartbeat room_config =
  if not (try_begin_manual_tick ()) then
    invalid_arg "manual heartbeat already running";
  Fun.protect
    ~finally:(fun () -> set_manual_tick_running false)
    (fun () -> run_manual_heartbeat room_config)

let trigger_heartbeat_async ~sw room_config =
  if not (try_begin_manual_tick ()) then
    `Already_running
  else begin
    Eio.Fiber.fork ~sw (fun () ->
      Fun.protect
        ~finally:(fun () -> set_manual_tick_running false)
        (fun () ->
          try
            ignore (run_manual_heartbeat room_config)
          with exn ->
            Eio.traceln "💀 Lodge manual trigger failed: %s"
              (Printexc.to_string exn)));
    `Started
  end

(** Broadcast content-aware routing is now in Lodge_broadcast module.
    See lib/lodge_broadcast.ml for the extracted code.
    @since 2.91.0 — Extracted to reduce lodge_heartbeat.ml size. *)
