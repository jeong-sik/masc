(** Keeper_unified_prompt — Build a single unified prompt from keeper identity
    and world observation.

    Sections removed in #6814: Available Tools (AGENT_CORE tool schema handles),
    Recent Tool Activity, Last Cycle Outcome, Tool Diversity Signal,
    Peer Keepers, Your Recent Board Posts,
    Behavioral Self-Assessment, Actionable Routes, Signal Interpretation.
    Telemetry for removed sections is preserved via decision_audit and
    independent storage paths.

    "Your Recent Board Posts" was later restored as the [Own_board_posts]
    context layer: raw observation rows (post_id, updated_at, title, preview)
    with no advisory wording. #6814 was right to remove the scolding text; the
    side effect was that a keeper could never see its own published posts
    in-prompt (board events are cursor-based and exclude self-authors), which
    produced near-duplicate posting loops in production.

    @since Unified Keeper Loop *)

type turn_prompt_parts = {
  system_prompt : string;
  world_state : string;
  user_message : string;
}

(* Ordinary user input for an autonomous continuation. The durable checkpoint
   carries this cue and the assistant/tool suffix in normal conversation order;
   the fresh observation frame alone rides [world_state] and stays ephemeral.

   This is the last resort behind the fleet setting. Nothing classifies a
   turn by matching
   this string -- autonomy is a typed property of the turn -- and nothing may
   start, because the operator can change it. *)
let autonomous_wake_marker = Env_config_keeper.KeeperAutonomous.default_wake_prompt

(* Every line the keeper reads comes from a fragment under config/prompts, so
   an operator rewords it without an OCaml change (RFC
   prompts-and-tool-definitions-outside-ocaml). A render can only fail when a
   template and its call disagree about variables, which is a build-time
   mistake; the failure is placed in the line rather than dropped, because a
   silently missing line reads as an absent condition rather than a broken
   one. A slot paragraph is already trimmed by the loader (and an override at
   validation), so the rendered text is used raw and the call site owns the
   joining newlines — byte-identical to the [Printf.sprintf]/[String.concat]
   assembly it replaces. *)
let render_fragment key vars =
  match Prompt_registry.render_prompt_template key vars with
  | Ok text -> text
  | Error detail -> key ^ ": " ^ detail
;;

(* The diagnostic attached to an [unavailable] Skill catalog row lives in
   keeper.md (one slot, two render sites: the current task and the other held
   tasks). A slot that does not render is logged, and the failure text
   becomes the property value — the same contract [render_fragment] above
   documents: the failure is placed in the row rather than dropped, because a
   silently missing key reads as an absent condition rather than a broken
   one. *)
let skills_unavailable_diagnostic_property () =
  match
    Prompt_registry.render_prompt_template
      Prompt_names.keeper_skills_unavailable_diagnostic
      []
  with
  | Ok text -> [ "diagnostic", `String text ]
  | Error detail ->
    Log.Misc.error
      "keeper skills-unavailable diagnostic prompt %s did not render: %s"
      Prompt_names.keeper_skills_unavailable_diagnostic
      detail;
    [ ( "diagnostic"
      , `String (Prompt_names.keeper_skills_unavailable_diagnostic ^ ": " ^ detail) )
    ]
;;

let format_pending_messages
      (messages : Keeper_world_observation_message_scope.pending_message list)
  : string
  =
  messages
  |> List.map (fun message ->
    match message.Keeper_world_observation_message_scope.kind with
    | Keeper_world_observation_message_scope.Mention ->
      render_fragment
        Prompt_names.keeper_world_pending_messages_mention_row
        [ "speaker", message.speaker; "content", message.content ]
    | Keeper_world_observation_message_scope.Scope ->
      render_fragment
        Prompt_names.keeper_world_pending_messages_scope_row
        [ "speaker", message.speaker; "content", message.content ])
  |> String.concat "\n"

let format_fleet_messages
      (messages : Keeper_world_observation_message_scope.fleet_message list)
  : string
  =
  messages
  |> List.map (fun (message : Keeper_world_observation_message_scope.fleet_message) ->
    render_fragment
      Prompt_names.keeper_world_fleet_messages_row
      [ "speaker", message.fleet_speaker; "content", message.fleet_content ])
  |> String.concat "\n"

(* The argument object rides on a refusal and not on a success, for the reason
   this module already gives for outputs: a call that landed is a fact, and
   "the returned body is where the bytes are". The request body is the same
   kind of bulk. What a keeper must not repeat is a refused call, and to
   recognise that one it has to read what it sent.

   The two are not the same size. Keeper [analyst], 2026-08-23: 1,312 calls
   succeeded carrying 538,743 bytes of arguments, 20 were refused carrying
   6,417. Replaying the successes put 120,951 bytes of this section into a
   131,072-byte model input and the keeper refused every turn for eight hours.

   This is a narrower section, not a truncated one -- no call disappears and
   no argument is cut mid-string. A keeper that needs the arguments of a call
   that succeeded is asking what it did, which is what the board, the task and
   the goal sections answer. *)
let format_own_recent_actions_turn (turn : Keeper_own_recent_actions.turn) : string =
  let turn_id = string_of_int turn.turn_id in
  turn.calls
  |> List.map (fun (call : Keeper_own_recent_actions.call) ->
    match call.outcome with
    | Keeper_own_recent_actions.Ok_call ->
      render_fragment
        Prompt_names.keeper_world_own_recent_actions_turn_ok_row
        [ "turn_id", turn_id; "tool", call.tool ]
    | Keeper_own_recent_actions.Failed_call None ->
      render_fragment
        Prompt_names.keeper_world_own_recent_actions_turn_rejected_row
        [ "turn_id", turn_id; "tool", call.tool; "input", call.input ]
    | Keeper_own_recent_actions.Failed_call (Some detail) ->
      render_fragment
        Prompt_names.keeper_world_own_recent_actions_turn_rejected_detail_row
        [ "turn_id", turn_id; "tool", call.tool; "input", call.input; "detail", detail ])
  |> String.concat "\n"
;;


(* What the prompt knows about one active goal. [phase] is [None] only when the
   id does not resolve in the store (a dangling assignment — kept visible, per
   [active_goal_summaries]). RFC-0387 stage 2 carries the phase so a [Verifying]
   goal is annotated rather than reading as ordinary open work — the gate must
   not make the goal disappear from the keeper's view (review P0-1). *)
type goal_summary =
  { summary_goal_id : string
  ; summary_title : string
  ; summary_phase : Goal_phase.t option
  }

(** Format active goals with their titles (RFC-0315). The only rendering of
    the Active Goals layer: a caller that resolves no summaries renders no
    layer, rather than falling back to a list this layer does not scope.
    A [Verifying] goal is annotated: completion is requested and the proof is
    being judged out-of-band, so the keeper keeps working the linked tasks
    instead of re-requesting completion. *)
let format_goal_summaries (summaries : goal_summary list) : string =
  String.concat "\n"
    (List.map
       (fun summary ->
          let base =
            if summary.summary_title = ""
            then
              render_fragment
                Prompt_names.keeper_world_active_goals_row_untitled
                [ "goal_id", summary.summary_goal_id ]
            else
              render_fragment
                Prompt_names.keeper_world_active_goals_row
                [ "goal_id", summary.summary_goal_id; "title", summary.summary_title ]
          in
          match summary.summary_phase with
          | Some Goal_phase.Verifying ->
            base
            ^ " "
            ^ render_fragment
                Prompt_names.keeper_world_active_goals_verifying_annotation
                []
          | Some (Goal_phase.Executing | Goal_phase.Completed | Goal_phase.Dropped) | None
            -> base)
       summaries)

let format_task_skills ?surfaces skills =
  let skill_surfaces =
    (match surfaces with
     | Some surfaces ->
       `List (List.map Keeper_skill_catalog.exact_surface_to_yojson surfaces)
     | None ->
       `List
         (List.map
            (fun reference ->
               `Assoc
                 ([ "reference", Skill_reference.to_yojson reference
                  ; "kind", `String "unavailable"
                  ]
                  @ skills_unavailable_diagnostic_property ()))
            skills))
    |> Yojson.Safe.to_string
  in
  match
    Prompt_registry.render_prompt_template
      Prompt_names.keeper_current_task_skills
      [ "skill_surfaces", skill_surfaces ]
  with
  | Ok text -> String.trim text
  | Error detail ->
    Log.Misc.error
      "keeper current-task skills prompt %s did not render, falling back to exact surfaces: %s"
      Prompt_names.keeper_current_task_skills
      detail;
    "- skill_surfaces=" ^ skill_surfaces
;;

(* The other held tasks' skills, one line each, under their own heading. The
   current task's block already names its skills; this covers a keeper that
   holds more than one task, where the reconciler keeps the earlier one
   current and the later claim's skills had no line at all (task-364).
   Heading and lines are prompt templates; a template that does not render
   is logged and falls back to the bare data, never to prose written here. *)
let format_held_task_skills
      ?(skill_surfaces_by_task = [])
      (held : Keeper_world_observation_inputs.held_task_skills list)
  : string option
  =
  match held with
  | [] -> None
  | held ->
    let render key vars ~fallback =
      match Prompt_registry.render_prompt_template key vars with
      | Ok text -> String.trim text
      | Error detail ->
        Log.Misc.error
          "keeper held-task skills prompt %s did not render, falling back to the bare data: %s"
          key
          detail;
        fallback
    in
    let heading =
      render Prompt_names.keeper_held_task_skills_heading [] ~fallback:""
    in
    let lines =
      List.map
        (fun (entry : Keeper_world_observation_inputs.held_task_skills) ->
           let skill_surfaces =
             let surfaces = List.assoc_opt entry.held_task_id skill_surfaces_by_task in
             match surfaces with
             | Some surfaces ->
               `List
                 (List.map Keeper_skill_catalog.exact_surface_to_yojson surfaces)
               |> Yojson.Safe.to_string
             | None ->
               `List
                 (List.map
                    (fun reference ->
                       `Assoc
                         ([ "reference", Skill_reference.to_yojson reference
                          ; "kind", `String "unavailable"
                          ]
                          @ skills_unavailable_diagnostic_property ()))
                    entry.held_skills)
               |> Yojson.Safe.to_string
           in
           render
             Prompt_names.keeper_held_task_skills
             [ "task_id", entry.held_task_id; "skill_surfaces", skill_surfaces ]
             ~fallback:(entry.held_task_id ^ ": " ^ skill_surfaces))
        held
    in
    Some (String.concat "\n" ((if String.equal heading "" then [] else [ heading ]) @ lines) ^ "\n\n")
;;

(** Render the keeper's own claimed task as standing context (RFC-0315).
    The scheduled cycle always runs when proactive lifecycle is enabled, and
    the model must see the work it is holding: id, title, status, and the prior
    owner's handoff summary when one exists. *)
let format_current_task_with_heading ?skill_surfaces ~heading
      (task : Masc_domain.task) : string =
  let status_line =
    match task.Masc_domain.task_status with
    | Masc_domain.Claimed { assignee; claimed_at } ->
      render_fragment
        Prompt_names.keeper_world_current_task_status_claimed
        [ "assignee", assignee; "claimed_at", claimed_at ]
    | Masc_domain.InProgress { assignee; started_at } ->
      render_fragment
        Prompt_names.keeper_world_current_task_status_in_progress
        [ "assignee", assignee; "started_at", started_at ]
    | Masc_domain.AwaitingVerification { submitted_at; _ } ->
      render_fragment
        Prompt_names.keeper_world_current_task_status_awaiting_verification
        [ "submitted_at", submitted_at ]
    | Masc_domain.Todo ->
      render_fragment Prompt_names.keeper_world_current_task_status_todo []
    | Masc_domain.Done _ ->
      render_fragment Prompt_names.keeper_world_current_task_status_done []
    | Masc_domain.Cancelled _ ->
      render_fragment Prompt_names.keeper_world_current_task_status_cancelled []
  in
  let buf = Buffer.create 256 in
  Buffer.add_string buf ("### " ^ heading ^ "\n");
  Buffer.add_string buf
    (render_fragment
       Prompt_names.keeper_world_current_task_row
       [ "task_id", task.Masc_domain.id
       ; "title", task.Masc_domain.title
       ; "status", status_line
       ]
     ^ "\n");
  (match task.Masc_domain.handoff_context with
   | Some h when h.Masc_domain.summary <> "" ->
       (* RFC-0365: a handoff can now come from a previous owner, so the note
          must say whose it is. Without this the model reads another agent's
          first-person account ("I already verified the spec") as its own
          recollection, which is worse than not showing the note at all. The
          author is stated even when it is the current holder — a keeper that
          has to compare cannot do so from a line that is sometimes attributed
          and sometimes not. *)
     let attribution =
       match h.Masc_domain.updated_by, h.Masc_domain.updated_at with
       | Some who, Some at ->
         " "
         ^ render_fragment
             Prompt_names.keeper_world_current_task_attribution_full
             [ "who", who; "at", at ]
       | Some who, None ->
         " "
         ^ render_fragment
             Prompt_names.keeper_world_current_task_attribution_who
             [ "who", who ]
       | None, Some at ->
         " "
         ^ render_fragment
             Prompt_names.keeper_world_current_task_attribution_at
             [ "at", at ]
       | None, None ->
         " " ^ render_fragment Prompt_names.keeper_world_current_task_attribution_none []
     in
     Buffer.add_string
       buf
       (render_fragment
          Prompt_names.keeper_world_current_task_handoff
          [ "attribution", attribution; "summary", h.Masc_domain.summary ]
        ^ "\n");
     (match h.Masc_domain.next_step with
      | Some step when step <> "" ->
        Buffer.add_string
          buf
          (render_fragment
             Prompt_names.keeper_world_current_task_handoff_next_step
             [ "step", step ]
           ^ "\n")
      | Some _ | None -> ());
     (* The refs are where the previous owner's work actually is. Dropping
          them leaves prose that points at an address the model never receives,
          and the artifact/board readers that resolve them are already
          model-visible. *)
     (match h.Masc_domain.evidence_refs with
      | [] -> ()
      | refs ->
        Buffer.add_string
          buf
          (render_fragment
             Prompt_names.keeper_world_current_task_handoff_evidence
             [ "refs", String.concat ", " refs ]
           ^ "\n"))
   | Some _ | None -> ());
  (* RFC skills-declared-not-discovered: the task names its skills, so this
     block does not list what is available and let the model match — there is
     nothing to choose between by the time the turn starts.

     Exact references, not the instruction itself. A skill body is written to
     be read whole and some run to tens of kilobytes (the published
     im-ai-copyeditor carries an 80 KB reference pack), which would land on
     every turn of the task rather than the one turn that uses it. The keeper
     already has [Read]; spending one call is cheaper than carrying the file.

     A task that names none adds no line, so the assembled prompt for every
     existing task is byte-identical to what it was before skills existed. *)
  (match task.Masc_domain.skills with
   | [] -> ()
   | skills ->
       Buffer.add_string buf (format_task_skills ?surfaces:skill_surfaces skills ^ "\n"));
  Buffer.add_string buf
    "\n";
  Buffer.contents buf

(* "held by you" is true of the two statuses that actually hold a claim slot.
   [Workspace_task.active_owned_task_ids_for_agent] counts [Claimed] and
   [InProgress] and returns [None] for [AwaitingVerification]; the scheduler
   states the same rule outright ("AwaitingVerification is still excluded: it is
   no longer active implementation work for the claimant").

   Under the old single heading a submitted task read as one the Keeper was
   still holding, and the only visible way out of holding something is to give
   it up. 10 of 56 cancellations in the live backlog are finished work cancelled
   with the deliverable written into the cancel reason -- task-032 says
   "useYupValidationResolver typed properly, tsc passes. Cancelling to free",
   naming the belief in the act of acting on it. The claim it was freeing itself
   for was never blocked.

   The heading is the whole fix: no new field, no new line, and the status was
   already on the row underneath. *)
let format_current_task ?skill_surfaces (task : Masc_domain.task) =
  let heading =
    match task.Masc_domain.task_status with
    | Masc_domain.AwaitingVerification _ ->
      render_fragment Prompt_names.keeper_world_current_task_heading_submitted []
    | Masc_domain.Claimed _
    | Masc_domain.InProgress _
    | Masc_domain.Todo
    | Masc_domain.Done _
    | Masc_domain.Cancelled _ ->
      render_fragment Prompt_names.keeper_world_current_task_heading_held []
  in
  format_current_task_with_heading ?skill_surfaces ~heading task

(** Format one conversation endpoint presence line. *)
let format_surface_presence (p : Gate_surface.surface_presence) : string =
  let endpoint =
    match p.surface with
    | Gate_surface.Dashboard -> "dashboard"
    | Gate_surface.Discord { channel_id = Some channel; _ } ->
        Printf.sprintf "discord #%s" channel
    | Gate_surface.Discord { channel_id = None; _ } -> "discord"
    | Gate_surface.Slack { channel_id = Some channel; _ } ->
        Printf.sprintf "slack #%s" channel
    | Gate_surface.Slack { channel_id = None; _ } -> "slack"
    | Gate_surface.Gate { channel; channel_id = Some channel_id } ->
        Printf.sprintf "%s #%s" channel channel_id
    | Gate_surface.Gate { channel; channel_id = None } -> channel
  in
  let state =
    render_fragment
      (if p.alive
       then Prompt_names.keeper_world_connected_surfaces_state_alive
       else Prompt_names.keeper_world_connected_surfaces_state_offline)
      []
  in
  Printf.sprintf "%s (%s)" endpoint state
;;

let board_event_kind_label = function
  | Keeper_world_observation.Board_post_created -> "post_created"
  | Keeper_world_observation.Board_comment_added -> "comment_added"
  | Keeper_world_observation.Board_reaction_changed _ -> "reaction_changed"
  | Keeper_world_observation.Board_vote_cast _ -> "vote_cast"
  | Keeper_world_observation.Fusion_completed -> "fusion_completed"
  | Keeper_world_observation.Schedule_due _ -> "schedule_due"
  | Keeper_world_observation.External_attention _ -> "external_attention"
  | Keeper_world_observation.Completion_authority_rejected _ ->
    "completion_authority_rejected"
  | Keeper_world_observation.Task_cancelled _ -> "task_cancelled"
  | Keeper_world_observation.Delegate_completed -> "keeper_delegate_completed"
  | Keeper_world_observation.Composition_completed ->
    "keeper_composition_completed"
  | Keeper_world_observation.Ask_answered_row -> "ask_answered"
;;

let quote_prompt_field value =
  let buf = Buffer.create (String.length value + 2) in
  Buffer.add_char buf '"';
  String.iter
    (function
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c -> Buffer.add_char buf c)
    value;
  Buffer.add_char buf '"';
  Buffer.contents buf

(* What a degraded observation permits the Keeper to conclude is prose, and it
   lives with the other prompt text under [config/prompts]. This module keeps
   the state detection and the task id.

   The data-only fallback is not a second source of truth: it exists because
   the fact that the current task is in a degraded state has to reach the
   prompt even if its sentence cannot be rendered, and losing the fact is worse
   than losing the wording. [test_prompt_templates_render] renders every
   registered key with its declared variables, so a broken template is a CI
   failure rather than something this branch quietly absorbs. *)
let observation_prose key vars ~fallback =
  match Prompt_registry.render_prompt_template key vars with
  | Ok text -> String.trim text ^ "\n\n"
  | Error detail ->
    Log.Misc.error
      "keeper observation prompt %s did not render, falling back to the bare \
       observation: %s"
      key
      detail;
    fallback
;;

let format_current_task_observation ?skill_surfaces = function
  | Keeper_world_observation_inputs.No_current_task -> None
  | Keeper_world_observation_inputs.Current_task task ->
    Some (format_current_task ?skill_surfaces task)
  | Keeper_world_observation_inputs.Recovered_current_task { task; recovery } ->
    Some
      (format_current_task_with_heading
         ?skill_surfaces
         ~heading:
           (render_fragment Prompt_names.keeper_world_current_task_heading_recovery [])
         task
       ^ observation_prose
           Prompt_names.keeper_observation_recovered_current_task
           []
           ~fallback:("- recovery_path=" ^ recovery.recovery_path ^ "\n\n"))
  | Keeper_world_observation_inputs.Current_task_missing { task_id; recovery = None } ->
    let task_id = Keeper_id.Task_id.to_string task_id in
    Some
      (observation_prose
         Prompt_names.keeper_observation_current_task_absent
         [ "task_id", task_id ]
         ~fallback:("### Current Task\n- task_id=" ^ task_id ^ "\n\n"))
  | Keeper_world_observation_inputs.Current_task_missing
      { task_id; recovery = Some recovery } ->
    let task_id = Keeper_id.Task_id.to_string task_id in
    Some
      (observation_prose
         Prompt_names.keeper_observation_current_task_absent_in_recovery
         [ "task_id", task_id ]
         ~fallback:
           ("### Current Task\n- task_id="
            ^ task_id
            ^ " recovery_path="
            ^ recovery.recovery_path
            ^ "\n\n"))
  | Keeper_world_observation_inputs.Current_task_unavailable { task_id; error = _ } ->
    let task_id = Keeper_id.Task_id.to_string task_id in
    Some
      (observation_prose
         Prompt_names.keeper_observation_current_task_unobservable
         [ "task_id", task_id ]
         ~fallback:("### Current Task\n- task_id=" ^ task_id ^ "\n\n"))
;;

let format_prompt_row fields =
  fields
  |> List.map (fun (name, value) -> name ^ "=" ^ quote_prompt_field value)
  |> String.concat " "
  |> ( ^ ) "- "
;;

let approval_observation_fields
      (approval : Keeper_world_observation.pending_approval_observation)
  =
  [ "approval_id", approval.approval_id
  ; "status", "pending"
  ; "tool", approval.tool_name
  ; "sequence", string_of_int approval.sequence
  ; ( "requested_at"
    , Masc_domain.iso8601_of_unix_seconds approval.requested_at )
  ]
  @ (match approval.task_id with
     | None -> []
     | Some task_id -> [ "task_id", task_id ])
  @ (match approval.goal_id with
     | None -> []
     | Some goal_id -> [ "goal_id", goal_id ])
;;

let format_approval_authority_observation
      (observation : Keeper_world_observation.approval_authority_observation)
  =
  let buffer = Buffer.create 512 in
  let revision = string_of_int observation.revision in
  let pending_count = string_of_int (List.length observation.pending) in
  Buffer.add_string buffer
    (render_fragment Prompt_names.keeper_context_approval_authority_heading []);
  Buffer.add_char buffer '\n';
  (match observation.state with
   | Keeper_world_observation.Approval_authority_complete ->
     Buffer.add_string buffer
       (render_fragment
          Prompt_names.keeper_context_approval_authority_state_complete
          [ "revision", revision; "pending_count", pending_count ])
   | Keeper_world_observation.Approval_authority_partial { read_error_count } ->
     Buffer.add_string buffer
       (render_fragment
          Prompt_names.keeper_context_approval_authority_state_partial
          [ "revision", revision
          ; "pending_count", pending_count
          ; "read_error_count", string_of_int read_error_count
          ])
   | Keeper_world_observation.Approval_authority_unavailable ->
     Buffer.add_string buffer
       (render_fragment
          Prompt_names.keeper_context_approval_authority_state_unavailable
          [ "revision", revision ]));
  Buffer.add_char buffer '\n';
  List.iter
    (fun approval ->
       Buffer.add_string buffer
         (format_prompt_row (approval_observation_fields approval));
       Buffer.add_char buffer '\n')
    observation.pending;
  Buffer.add_string buffer
    (render_fragment Prompt_names.keeper_context_approval_authority_footer []);
  Buffer.add_string buffer "\n\n";
  Buffer.contents buffer
;;

let board_reaction_fields
    (reaction : Keeper_world_observation.board_reaction_event) =
  [ "reaction", if reaction.reacted then "added" else "removed"
  ; ( "target"
    , Board.reaction_target_type_to_string reaction.target_type
      ^ ":"
      ^ reaction.target_id )
  ; "user", reaction.user_id
  ; "emoji", reaction.emoji
  ]
;;

(* Who voted which way on what. [author] on the row is already the voter
   (the signal's actor); [voter] is repeated here so the vote row reads on its
   own, the way the reaction row carries [user]. *)
let board_vote_fields (vote : Board_dispatch.board_vote_change) =
  [ "vote", Board.vote_direction_to_string vote.direction
  ; ( "target"
    , match vote.target with
      | Board_dispatch.Vote_on_post post_id -> "post:" ^ post_id
      | Board_dispatch.Vote_on_comment comment_id -> "comment:" ^ comment_id )
  ; "voter", vote.voter
  ]
;;

let board_event_note_fields = function
  | Keeper_world_observation.Board_reaction_changed reaction ->
    board_reaction_fields reaction
  | Keeper_world_observation.Board_vote_cast vote -> board_vote_fields vote
  | Keeper_world_observation.External_attention observation ->
    [ "external_origin"
    , Keeper_counterpart_observation.origin_to_string observation.origin
    ; "external_channel", observation.channel
    ; "external_authority"
    , Keeper_counterpart_observation.authority_to_string observation.authority
    ]
    @ (match observation.workspace_id with
       | None -> []
       | Some workspace_id -> [ "external_workspace_id", workspace_id ])
    @ (match observation.user_id with
       | None -> []
       | Some user_id -> [ "external_user_id", user_id ])
    @ (match observation.user_name with
       | None -> []
       | Some user_name -> [ "external_user_name", user_name ])
  | Keeper_world_observation.Board_post_created
  | Keeper_world_observation.Board_comment_added
  | Keeper_world_observation.Fusion_completed
  | Keeper_world_observation.Schedule_due _
  | Keeper_world_observation.Completion_authority_rejected _
  | Keeper_world_observation.Task_cancelled _
  | Keeper_world_observation.Delegate_completed
  (* The answer is the row's title and preview; there is no side fact to add. *)
  | Keeper_world_observation.Ask_answered_row
  | Keeper_world_observation.Composition_completed -> []
;;

let board_event_fields
    (event : Keeper_world_observation.pending_board_event) =
  let event_label = board_event_kind_label event.event_kind in
  let fields =
    [ "event", event_label
    ; "post_id", event.post_id
    ; "post_kind", Board.post_kind_to_string event.post_kind
    ; "title", Keeper_types_profile.short_preview ~max_len:80 event.title
    ; "author", event.author
    ]
  in
  let fields =
    match event.hearth with
    | Some hearth when String.trim hearth <> "" -> fields @ [ "hearth", hearth ]
    | _ -> fields
  in
  let fields =
    if event.explicit_mention then
      let mention_fields =
        match event.matched_targets with
        | [] -> []
        | xs -> [ "mention_targets", String.concat ", " xs ]
      in
      fields @ (("mention", "explicit") :: mention_fields)
    else fields
  in
  let fields = fields @ board_event_note_fields event.event_kind in
  (* [new_replies_since_own] counts replies that arrived after this Keeper's own
     comment, so it is stated only when there is an own comment to count from.
     The author of the post is the case that has none: [check_self_comment_status]
     answers [`Never], and the observation still fills
     [latest_external_author]/[latest_external_preview] with the commenter and
     what they said.

     Those two used to be gated on [self_commented] together with the count, so
     the author of a post learned that a comment existed and not one word of it
     — the wake #27288 added arrived empty, and reading it back cost a
     masc_board_post_get. The count keeps its condition because its name is only
     true under it; the two content fields follow the data instead. *)
  let fields =
    if event.self_commented && event.new_external_since > 0
    then fields @ [ "new_replies_since_own", string_of_int event.new_external_since ]
    else fields
  in
  let fields =
    match event.latest_external_author, event.latest_external_preview with
    | Some author, Some preview ->
      fields @ [ "latest_external_author", author; "latest_external_preview", preview ]
    | Some author, None -> fields @ [ "latest_external_author", author ]
    | None, _ -> fields
  in
  fields @ [ "preview", event.preview ]
;;

let format_board_event_text
    (event : Keeper_world_observation.pending_board_event) : string =
  format_prompt_row (board_event_fields event)
;;

let format_scheduled_automation_item
    (item : Keeper_world_observation.scheduled_automation_item) : string =
  let payload_kind =
    match item.payload_kind with
    | None -> "unknown"
    | Some kind -> kind
  in
  format_prompt_row
    [ "schedule_id", item.schedule_id
    ; "action", item.action
    ; "status", item.status
    ; "payload", payload_kind
    ; "recurrence", item.recurrence_summary
    ; "due_at", Masc_domain.iso8601_of_unix_seconds item.due_at
    ]
;;

let scheduled_wake_fields ~occurrence_id
    (wake : Keeper_event_queue.scheduled_wake) =
  let title_field =
    match wake.title with
    | None -> []
    | Some title -> [ "title", title ]
  in
  [ "schedule_id", wake.schedule_id
  ; "due_at_unix", Printf.sprintf "%.17g" wake.due_at
  ; "payload_digest", wake.payload_digest
  ; "occurrence_id", occurrence_id
  ]
  @ title_field
  @ [ "message", wake.message ]
;;

type scheduled_wake_group =
  { wake : Keeper_event_queue.scheduled_wake
  ; first_occurrence_id : string
  ; first_due_at : float
  ; last_occurrence_id : string
  ; last_due_at : float
  ; occurrence_count : int
  }

let same_scheduled_wake_series
      (left : Keeper_event_queue.scheduled_wake)
      (right : Keeper_event_queue.scheduled_wake)
  =
  String.equal left.schedule_id right.schedule_id
  && String.equal left.schedule_instance_id right.schedule_instance_id
  && String.equal left.payload_digest right.payload_digest
;;

let group_scheduled_wake_events events =
  let add_event groups (event : Keeper_world_observation.pending_board_event) =
    match event.event_kind with
    | Keeper_world_observation.Schedule_due wake ->
      let rec update prefix = function
        | [] ->
          List.rev_append
            prefix
            [ { wake
              ; first_occurrence_id = event.post_id
              ; first_due_at = wake.due_at
              ; last_occurrence_id = event.post_id
              ; last_due_at = wake.due_at
              ; occurrence_count = 1
              }
            ]
        | group :: rest when same_scheduled_wake_series group.wake wake ->
          let first_occurrence_id, first_due_at =
            if wake.due_at < group.first_due_at
            then event.post_id, wake.due_at
            else group.first_occurrence_id, group.first_due_at
          in
          let last_occurrence_id, last_due_at =
            if wake.due_at > group.last_due_at
            then event.post_id, wake.due_at
            else group.last_occurrence_id, group.last_due_at
          in
          List.rev_append
            prefix
            ({ group with
               first_occurrence_id
             ; first_due_at
             ; last_occurrence_id
             ; last_due_at
             ; occurrence_count = group.occurrence_count + 1
             }
             :: rest)
        | group :: rest -> update (group :: prefix) rest
      in
      update [] groups
    | Keeper_world_observation.Board_post_created
    | Keeper_world_observation.Board_comment_added
    | Keeper_world_observation.Board_reaction_changed _
    | Keeper_world_observation.Board_vote_cast _
    | Keeper_world_observation.Fusion_completed
    | Keeper_world_observation.External_attention _
    | Keeper_world_observation.Completion_authority_rejected _
    | Keeper_world_observation.Task_cancelled _
    | Keeper_world_observation.Delegate_completed
    | Keeper_world_observation.Ask_answered_row
    | Keeper_world_observation.Composition_completed -> groups
  in
  List.fold_left add_event [] events
;;

let scheduled_wake_group_fields group =
  if group.occurrence_count = 1
  then scheduled_wake_fields ~occurrence_id:group.first_occurrence_id group.wake
  else
    let title_field =
      match group.wake.title with
      | None -> []
      | Some title -> [ "title", title ]
    in
    [ "schedule_id", group.wake.schedule_id
    ; "occurrence_count", string_of_int group.occurrence_count
    ; "first_due_at_unix", Printf.sprintf "%.17g" group.first_due_at
    ; "last_due_at_unix", Printf.sprintf "%.17g" group.last_due_at
    ; "first_occurrence_id", group.first_occurrence_id
    ; "last_occurrence_id", group.last_occurrence_id
    ; "payload_digest", group.wake.payload_digest
    ]
    @ title_field
    @ [ "message", group.wake.message ]
;;

module For_testing = struct
  let board_event_fields = board_event_fields
  let scheduled_wake_fields = scheduled_wake_fields
end

let format_scheduled_automation_summary
    (summary : Keeper_world_observation.scheduled_automation_observation)
  : string option
  =
  let actionable = summary.due_ready_count > 0 in
  if (not actionable) && summary.active_count = 0
  then None
  else (
    let ubuf = Buffer.create 256 in
    Buffer.add_string ubuf
      (render_fragment Prompt_names.keeper_world_scheduled_automation_heading [] ^ "\n");
    Buffer.add_string
      ubuf
      (render_fragment
         Prompt_names.keeper_world_scheduled_automation_counts
         [ "active", string_of_int summary.active_count
         ; "ready", string_of_int summary.due_ready_count
         ]
       ^ "\n");
    (match summary.next_due_at with
     | None -> ()
     | Some due_at ->
       Buffer.add_string ubuf
         (render_fragment
            Prompt_names.keeper_world_scheduled_automation_next_due
            [ "due_at", Masc_domain.iso8601_of_unix_seconds due_at ]
          ^ "\n"));
    if summary.items <> []
    then (
      Buffer.add_string
        ubuf
        (render_fragment
           Prompt_names.keeper_world_scheduled_automation_attention_heading
           []
         ^ "\n");
      List.iter
        (fun item ->
           Buffer.add_string ubuf (format_scheduled_automation_item item);
           Buffer.add_char ubuf '\n')
        summary.items;
      Buffer.add_string
        ubuf
        (render_fragment Prompt_names.keeper_world_scheduled_automation_attention_note []
         ^ "\n"));
    Buffer.add_char ubuf '\n';
    Some (Buffer.contents ubuf))
;;

let format_scheduled_wake_observations
    (events : Keeper_world_observation.pending_board_event list) =
  if events = []
  then None
  else (
    let ubuf = Buffer.create 512 in
    let groups = group_scheduled_wake_events events in
    Buffer.add_string ubuf
      ((match events, groups with
        | [ _ ], [ _ ] ->
          render_fragment Prompt_names.keeper_world_scheduled_wake_heading_single []
        | _ ->
          render_fragment
            Prompt_names.keeper_world_scheduled_wake_heading_multi
            [ "events", string_of_int (List.length events)
            ; "series", string_of_int (List.length groups)
            ])
       ^ "\n");
    Buffer.add_string ubuf
      (render_fragment Prompt_names.keeper_world_scheduled_wake_intro [] ^ "\n");
    List.iter
      (fun group ->
         Buffer.add_string ubuf
           (format_prompt_row (scheduled_wake_group_fields group));
         Buffer.add_char ubuf '\n')
      groups;
    Buffer.add_char ubuf '\n';
    Some (Buffer.contents ubuf))
;;

let format_completion_authority_rejection_observations
    (events : Keeper_world_observation.pending_board_event list) =
  let rows =
    List.filter_map
      (fun (event : Keeper_world_observation.pending_board_event) ->
         match event.event_kind with
         | Keeper_world_observation.Completion_authority_rejected rejection ->
           Some
             (format_prompt_row
                [ "post_id", event.post_id
                ; "task_id", rejection.Keeper_event_queue.car_task_id
                ; "verification_id", rejection.car_verification_id
                ; ( "authority_kind"
                  , Masc_domain.completion_authority_kind rejection.car_authority )
                ; ( "authority_actor"
                  , Masc_domain.completion_authority_actor rejection.car_authority )
                ; "reason", rejection.car_reason
                ]
              ^ "\n")
         | Keeper_world_observation.Board_post_created
         | Keeper_world_observation.Board_comment_added
         | Keeper_world_observation.Board_reaction_changed _
         | Keeper_world_observation.Board_vote_cast _
         | Keeper_world_observation.Fusion_completed
         | Keeper_world_observation.Schedule_due _
         | Keeper_world_observation.External_attention _
         | Keeper_world_observation.Task_cancelled _
         | Keeper_world_observation.Delegate_completed
         | Keeper_world_observation.Ask_answered_row
         | Keeper_world_observation.Composition_completed -> None)
      events
  in
  match rows with
  | [] -> None
  | _ ->
    Some
      (render_fragment
         Prompt_names.keeper_world_completion_authority_heading
         [ "count", string_of_int (List.length rows) ]
       ^ "\n"
       ^ render_fragment Prompt_names.keeper_world_completion_authority_intro []
       ^ "\n"
       ^ String.concat "" rows
       ^ "\n")
;;

(* Cancellations of Tasks this Keeper authored. Rendered in their own section
   rather than under Board Activity: no Board post exists to point at, and the
   canceller's reason is the only account of why work the Keeper asked for
   stopped. The [reason] field is emitted only when the canceller gave one:
   collapsing [None] to the empty string would render "no reason was given"
   and "the reason given was empty" as the same row. *)
let format_task_cancellation_observations
    (events : Keeper_world_observation.pending_board_event list) =
  let rows =
    List.filter_map
      (fun (event : Keeper_world_observation.pending_board_event) ->
         match event.event_kind with
         | Keeper_world_observation.Task_cancelled cancellation ->
           let identity =
             [ "post_id", event.post_id
             ; "task_id", cancellation.Keeper_event_queue.tc_task_id
             ; "cancelled_by", cancellation.tc_cancelled_by
             ]
           in
           let fields =
             match cancellation.tc_reason with
             | None -> identity
             | Some reason -> identity @ [ "reason", reason ]
           in
           Some (format_prompt_row fields ^ "\n")
         | Keeper_world_observation.Board_post_created
         | Keeper_world_observation.Board_comment_added
         | Keeper_world_observation.Board_reaction_changed _
         | Keeper_world_observation.Board_vote_cast _
         | Keeper_world_observation.Fusion_completed
         | Keeper_world_observation.Schedule_due _
         | Keeper_world_observation.External_attention _
         | Keeper_world_observation.Completion_authority_rejected _
         | Keeper_world_observation.Delegate_completed
         | Keeper_world_observation.Ask_answered_row
         | Keeper_world_observation.Composition_completed -> None)
      events
  in
  match rows with
  | [] -> None
  | _ ->
    Some
      (render_fragment
         Prompt_names.keeper_world_task_cancellations_heading
         [ "count", string_of_int (List.length rows) ]
       ^ "\n"
       (* "another actor", not "another Keeper": the wake is enqueued for any
          canceller, and an operator cancelling a Task is routine. Naming the
          canceller a Keeper would assign an operator's decision to a peer and
          change how the author follows it up. The cancelled_by field on each
          row carries who it actually was. *)
       ^ render_fragment Prompt_names.keeper_world_task_cancellations_intro []
       ^ "\n"
       ^ String.concat "" rows
       ^ "\n")
;;

let combine_prompt_sections sections =
  match List.filter_map Fun.id sections with
  | [] -> None
  | values -> Some (String.concat "" values)
;;

(* Every Board row crosses one neutral observation boundary. Author, post kind,
   and exact-mention state remain source/routing context only; none of them
   grants instruction authority. Relevance and action remain model decisions,
   while external effects still cross the Gate. *)
(* Claimable Tasks are a discovery list rather than already-admitted durable
   input. Keep that projection bounded. Board Activity is intentionally not
   bounded here: all-ready Event Queue admission ACKs the whole batch on turn
   completion, so hiding any admitted row would claim the Keeper saw input that
   never reached its prompt. *)
let claimable_task_render_budget_rows = 10

let take n xs = List.filteri (fun i _ -> i < n) xs

let render_board_observations
      (events : Keeper_world_observation.pending_board_event list)
  : string
  =
  render_fragment Prompt_names.keeper_world_board_activity_intro []
  ^ "\n"
  ^ (events |> List.map format_board_event_text |> String.concat "\n")
;;

(* The keeper's own published posts, rendered as neutral observation rows.
   post_id is included so the model can fetch the full body via board get and
   judge for itself whether a new post would repeat earlier content. No
   advisory wording: the rows are data, not instructions. *)
let format_own_board_post_text (post : Board.post) : string =
  format_prompt_row
    [ "post_id", Board.Post_id.to_string post.id
    ; "updated_at", Masc_domain.iso8601_of_unix_seconds post.updated_at
      (* What the Board did with it. The record carries these; the row dropped
         them, so a Keeper reading its own posts could not tell an answered one
         from an ignored one. A new vote also arrives as a [vote_cast] Board
         Activity row the moment it lands; this row is the running total.
         Counts, not advice: the rows stay data. *)
    ; "replies", string_of_int post.reply_count
    ; "votes", Printf.sprintf "+%d/-%d" post.votes_up post.votes_down
    ; "title", Keeper_types_profile.short_preview ~max_len:80 post.title
    ; "preview", Keeper_types_profile.short_preview ~max_len:80 post.body
    ]
;;

let autonomous_trigger_lines
    ~(decision : Keeper_world_observation.keeper_cycle_decision) : string list =
  match decision.channel, decision.should_run with
  | Keeper_world_observation.Scheduled_autonomous, true ->
    let lines =
      [ Some
          (render_fragment
             Prompt_names.keeper_world_autonomous_trigger_scheduler_scheduled
             [])
      ; (match Keeper_world_observation.verdict_reasons_to_strings decision.verdict with
         | [] -> None
         | reasons ->
           Some
             (render_fragment
                Prompt_names.keeper_world_autonomous_trigger_reasons
                [ "reasons", String.concat ", " reasons ]))
      ; (match decision.since_last_scheduled_autonomous with
         | Some since_last ->
           Some
             (render_fragment
                Prompt_names.keeper_world_autonomous_trigger_since_last
                [ "seconds", string_of_int since_last ])
         | None -> None)
      ]
    in
    List.filter_map Fun.id lines
  | Keeper_world_observation.Reactive, true ->
      (* RFC-0315: when the scheduler's real decision is threaded in, a
         stimulus-driven turn states its wake reasons instead of rendering
         nothing. Reactive payloads (mentions, board events, scope messages)
         still render in their own layers; event-queue stimuli (bootstrap,
         no-progress recovery, schedule-due, connector attention) surface
         ONLY here — before this arm the model had no trace of why it woke. *)
    render_fragment Prompt_names.keeper_world_autonomous_trigger_scheduler_reactive []
    ::
    (match Keeper_world_observation.verdict_reasons_to_strings decision.verdict with
     | [] -> []
     | reasons ->
       [ render_fragment
           Prompt_names.keeper_world_autonomous_trigger_reasons
           [ "reasons", String.concat ", " reasons ]
       ])
  | _ -> []

let effective_instructions
    ~(meta : Keeper_meta_contract.keeper_meta)
    ?(profile_defaults : Keeper_types_profile.keeper_profile_defaults option)
    ()
  =
  (* DET-OK: total default between two known sources (RFC-0282). *)
  match profile_defaults with
  | Some d -> Option.value d.instructions ~default:meta.instructions
  | None -> meta.instructions
;;
(* Titles and phases for the Goals this turn's task is linked to, read from
   the store under the same phase predicate the world observation uses. The
   phase rides along so the Active Goals block can annotate a [Verifying]
   goal (RFC-0387 stage 2: the gate must not make the goal read as ordinary
   open work, nor disappear — review P0-1).

   A Goal is shared intent and names no keeper, so the store answers the same
   list for everyone. What makes it this turn's context is the task the
   keeper holds: the link registry says which Goals that task serves, and a
   turn with no task carries no Goals here — [masc_goal_list] answers the
   rest. *)
let active_goal_summaries_for_task
      ~(config : Workspace.config)
      ~(current_task : Keeper_world_observation_inputs.current_task_observation)
  =
  let task_id =
    match current_task with
    | Keeper_world_observation_inputs.Current_task task
    | Keeper_world_observation_inputs.Recovered_current_task { task; _ } ->
      Some task.Masc_domain.id
    | Keeper_world_observation_inputs.No_current_task
    | Keeper_world_observation_inputs.Current_task_missing _
    | Keeper_world_observation_inputs.Current_task_unavailable _ -> None
  in
  match task_id with
  | None -> []
  | Some task_id ->
    let linked =
      Workspace_goal_index.goals_for_task
        (Workspace_goal_index.build_task_goal_index_for_config config)
        ~task_id
    in
    List.filter_map
      (fun (goal : Goal_store.goal) ->
         if List.exists (String.equal goal.id) linked
            && Goal_phase.admits_self_directed_progress goal.phase
         then
           Some
             { summary_goal_id = goal.id
             ; summary_title = goal.title
             ; summary_phase = Some goal.phase
             }
         else None)
      (Goal_store.list_goals config ())
;;

let build_system_prompt ~(meta : Keeper_meta_contract.keeper_meta)
    ~(config : Workspace.config)
    ?(profile_defaults : Keeper_types_profile.keeper_profile_defaults option)
    ()
  =
  let instructions = effective_instructions ~meta ?profile_defaults () in
  let base_system_prompt =
    Keeper_prompt.build_keeper_system_prompt
      ~instructions
      ~keeper_name:meta.name
      ~workspace_root:(Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta)
      ()
  in
  (* A second prompt asset used to be appended here as [## Turn Intent] on
     every turn. It restated the capability catalog, the Task-claim rule and
     the work-placement rule that [keeper] already carries, and its
     in-binary fallback had drifted to hold continuity statements the asset
     itself had dropped — so a keeper was told its checkpoint survives across
     cycles only when prompt config was degraded. The permanent content now
     lives in [keeper]; nothing in it varied per turn. *)
  base_system_prompt
;;

(* The backlog read produces three distinct facts, and the Namespace State
   section must be able to state each one. "Readable and empty" used to be
   encoded as an omitted section, which a reader of the rendered text cannot
   tell apart from "not observed": the keeper was handed nothing rather than
   an empty board. Typed here rather than left as a boolean disjunction so a
   further backlog outcome forces an arm at the render site. *)
type backlog_statement =
  | Backlog_unreadable
    (* Neither primary nor recovery was a valid current backlog. The
       accompanying zero counts are not an observation. *)
  | Backlog_readable_empty
    (* Authoritative read that returned no unclaimed, claimable, or failed
       rows. *)
  | Backlog_readable_with_rows
    (* Authoritative read with at least one counted row; the per-count lines
       carry the numbers. *)

let backlog_statement_of_observation
      (observation : Keeper_world_observation.world_observation)
  : backlog_statement
  =
  match observation.backlog_revision with
  | None -> Backlog_unreadable
  | Some _ ->
    let claimable_task_count =
      Keeper_world_observation.claimable_task_count observation
    in
    if
      observation.unclaimed_task_count = 0
      && claimable_task_count = 0
      && observation.failed_task_count = 0
    then Backlog_readable_empty
    else Backlog_readable_with_rows
;;

(* The checkpoint carries the previous turn's calls; it does not carry the
   reason the runtime ended that turn. Without the reason, a keeper whose turn
   was cut by the repeated-call guard reads its own three identical calls as
   unfinished work and makes them again. Measured 2026-09-01 from
   turn-records: one live keeper ended 259 of 361 turns on the same
   repeated query, lane-smith 136 of 342, polisher 84 of 424, and each next
   turn repeated the call. The sentences live under [config/prompts] with the
   other prompt text and name the tool and the count so the model can match
   them against its history. A template that fails to render logs and
   contributes no line: the checkpoint still carries the calls themselves.
   The three yields that are not loop guards (a queued chat operation, a
   newer durable stimulus, an awaited approval) explain themselves through
   the stimulus that follows and render nothing here. *)
let previous_turn_stop_lines (stop : Keeper_turn_checkpoint_reason.t option) :
    string list =
  let line key vars =
    match String.trim (observation_prose key vars ~fallback:"") with
    | "" -> []
    | text -> [ text ]
  in
  match stop with
  | None -> []
  | Some (Keeper_turn_checkpoint_reason.Repeated_tool_call { tool_name; repeated_count })
    ->
      line
        Prompt_names.keeper_observation_previous_turn_stop_repeated_tool_call
        [ "tool_name", tool_name; "repeated_count", string_of_int repeated_count ]
  | Some (Keeper_turn_checkpoint_reason.Repeated_assistant_text { repeated_count }) ->
      line
        Prompt_names.keeper_observation_previous_turn_stop_repeated_assistant_text
        [ "repeated_count", string_of_int repeated_count ]
  | Some
      ( Keeper_turn_checkpoint_reason.Operation_queued
      | Keeper_turn_checkpoint_reason.Durable_stimulus_arrived ) -> []

let build_prompt_internal ~(meta : Keeper_meta_contract.keeper_meta)
    ~(config : Workspace.config)
    ?(profile_defaults : Keeper_types_profile.keeper_profile_defaults option)
    ~(turn_decision : Keeper_world_observation.keeper_cycle_decision option)
    ?(previous_turn_stop : Keeper_turn_checkpoint_reason.t option)
    ~(current_task : Keeper_world_observation_inputs.current_task_observation)
    ?(task_skill_surfaces :
        (string * Keeper_skill_catalog.exact_surface list) list = [])
    ?(active_goal_summaries : goal_summary list option)
    ?(repository_freshness : Keeper_sandbox_control.freshness_row list = [])
    ?(context_budget_bytes : int option)
    ~(observation : Keeper_world_observation.world_observation)
    () : turn_prompt_parts
  =
  let system_prompt =
    (* No goal list here: #32665 took the summaries out of the system prompt
       so a Keeper's stable contract stops restating a store the turn already
       carries. The value stays in scope because this function still renders
       it into the turn's own context below -- that is the half #32665 kept. *)
    build_system_prompt ~meta ~config ?profile_defaults ()
  in
  (* User message: structured world observation — reactive triggers + resource state only.
     Runtime telemetry remains on decision_audit and independent observation paths.

     The body is an ordered fold of typed context layers (Keeper_context_layers).
     [content_of] below is an exhaustive match on [layer_id], so adding a
     world-state signal fails to compile until this match renders it, and the
     section order is the module's declared [ordered] SSOT rather than the
     implicit order of buffer writes. Byte-identical to the prior imperative
     buffer: each arm carries its own header and trailing separators, and
     [assemble] concatenates the present layers in [ordered] order. *)
  (* Prefix-cache ordering rationale and per-layer notes live on the matching
     arms of [content_of] and in Keeper_context_layers.ordered. *)
  let connector_presence =
    List.filter
      (fun (p : Gate_surface.surface_presence) ->
        match p.surface with
        | Gate_surface.Dashboard -> false
        | Gate_surface.Discord _ | Gate_surface.Slack _ | Gate_surface.Gate _
          ->
            true)
      observation.connected_surfaces
  in
  let connector_presence_failures = observation.connected_surface_failures in
  let autonomous_trigger =
    (match turn_decision with
     | Some decision -> autonomous_trigger_lines ~decision
     | None -> [])
    @ previous_turn_stop_lines previous_turn_stop
  in
  (* A row is a whole turn: the heading counts turns, and half a turn would
     have the keeper read a partial record of what it did. *)
  let own_recent_actions_section : Keeper_context_layers.section option =
    match observation.own_recent_actions with
    | [] -> None
    | turns ->
      let failures = Keeper_own_recent_actions.digest_failures turns in
      let render kept =
        let ubuf = Buffer.create 1024 in
        Buffer.add_string ubuf
          (render_fragment
             Prompt_names.keeper_world_own_recent_actions_heading
             [ "count", string_of_int (List.length kept) ]
           ^ "\n");
        Buffer.add_string ubuf
          (render_fragment Prompt_names.keeper_world_own_recent_actions_intro [] ^ "\n");
        (* The digest is the section's reason to exist: refusals buried in a
           hundred one-line rows below are the calls the keeper repeats
           (2026-08-28: same nonexistent paths re-read every turn while the
           refusals sat inside this very window). Rendered ahead of the rows
           and outside the row budget, so trimming the history never trims
           the part that changes the next turn's behavior. *)
        (match failures with
         | [] -> ()
         | failures ->
           (* Both lines are model-facing prose, so they live in
              config/prompts assets (RFC prompts-and-tool-definitions-
              outside-ocaml); a registry failure degrades to the bare data,
              mirroring the held-task skills render above. *)
           let render key vars ~fallback =
             match Prompt_registry.render_prompt_template key vars with
             | Ok text -> String.trim text
             | Error detail ->
               Log.Misc.error
                 "keeper rejected-call digest prompt %s did not render, falling back to \
                  the bare data: %s"
                 key
                 detail;
               fallback
           in
           let heading =
             render Prompt_names.keeper_observation_rejected_digest_heading [] ~fallback:""
           in
           if not (String.equal heading "")
           then Buffer.add_string ubuf (heading ^ "\n");
           List.iter
             (fun (digest : Keeper_own_recent_actions.failure_digest) ->
               let detail_suffix =
                 match digest.failure_detail with
                 | None -> ""
                 | Some detail -> " — " ^ detail
               in
               let count = string_of_int digest.failure_count in
               let last_turn = string_of_int digest.failure_last_turn in
               let row =
                 render
                   Prompt_names.keeper_observation_rejected_digest_row
                   [ "tool", digest.failure_tool
                   ; "input", digest.failure_input
                   ; "count", count
                   ; "last_turn", last_turn
                   ; "detail_suffix", detail_suffix
                   ]
                   ~fallback:
                     (String.concat
                        " "
                        [ "-"
                        ; digest.failure_tool
                        ; digest.failure_input
                        ; "×" ^ count
                        ; "@" ^ last_turn ^ detail_suffix
                        ])
               in
               Buffer.add_string ubuf (row ^ "\n"))
             failures);
        Buffer.add_string ubuf (String.concat "\n" kept);
        Buffer.add_string ubuf "\n\n";
        Buffer.contents ubuf
      in
      Some
        (Keeper_context_layers.Rows
           { rows = List.map format_own_recent_actions_turn turns; render })
  in
  let text_of : Keeper_context_layers.layer_id -> string option = function
    (* 1. Active goals — stable turn context. Titles render when the caller
       resolved them (RFC-0315). The count and the list are read off the same
       list, so the heading can never claim goals the body does not show. *)
    | Keeper_context_layers.Active_goals ->
      let count, body =
        match active_goal_summaries with
        | Some summaries -> List.length summaries, format_goal_summaries summaries
        (* No goals, not every goal. The caller resolves the goals linked to
           this turn's task ({!active_goal_summaries_for_task}); a Keeper
           holding no task has none, and that is the answer. Reading
           [observation.active_goals] here answered with the workspace's whole
           open-goal list instead -- the same list #32665 took out of the
           system prompt, back in the turn context for anyone who omits the
           argument. *)
        | None -> 0, ""
      in
      if count = 0
      then None
      else
        Some
          (render_fragment
             Prompt_names.keeper_world_active_goals_heading
             [ "count", string_of_int count ]
           ^ "\n"
           ^ body
           ^ "\n\n")
    (* 1b. Current task — the claim that admitted this turn (RFC-0315).
       Standing context: changes on claim/release, not per cycle. *)
    | Keeper_context_layers.Current_task ->
      let current_task_skill_surfaces =
        match current_task with
        | Keeper_world_observation_inputs.Current_task task
        | Recovered_current_task { task; _ } ->
          List.assoc_opt task.id task_skill_surfaces
        | No_current_task
        | Current_task_missing _
        | Current_task_unavailable _ ->
          None
      in
      (match
         ( format_current_task_observation
             ?skill_surfaces:current_task_skill_surfaces
             current_task
         , format_held_task_skills
             ~skill_surfaces_by_task:task_skill_surfaces
             observation.held_task_skills )
       with
       | None, None -> None
       | Some block, None | None, Some block -> Some block
       | Some current, Some held -> Some (current ^ held))
    (* 1c. Current approval authority — a fresh typed Gate read on every turn.
       It is intentionally explicit when empty: omitting a readable zero lets
       a historical owner instruction keep an already-resolved approval alive
       in the conversation checkpoint. *)
    | Keeper_context_layers.Approval_authority ->
      Some
        (format_approval_authority_observation observation.approval_authority)
    (* 2. Connected surfaces — connector presence, changes only on bind/unbind
       or transport flaps (RFC-0223 P2). Omitted when only the implicit
       dashboard is attached: every keeper has the dashboard, so dashboard-only
       presence carries no signal. *)
    | Keeper_context_layers.Connected_surfaces ->
      if connector_presence <> [] || connector_presence_failures <> [] then (
        let ubuf = Buffer.create 256 in
        Buffer.add_string
          ubuf
          (render_fragment Prompt_names.keeper_world_connected_surfaces_heading [] ^ "\n");
        List.iter
          (fun p ->
            Buffer.add_string ubuf
              (Printf.sprintf "- %s\n" (format_surface_presence p)))
          observation.connected_surfaces;
        List.iter
          (fun (failure : Gate_surface.presence_failure) ->
             Buffer.add_string
               ubuf
               (render_fragment
                  Prompt_names.keeper_world_connected_surfaces_failure
                  [ "connector_id", failure.connector_id
                  ; ( "error"
                    , Channel_gate_binding_store.binding_store_error_to_string
                        failure.error )
                  ]
                ^ "\n"))
          connector_presence_failures;
        Buffer.add_char ubuf '\n';
        Buffer.add_char ubuf '\n';
        Some (Buffer.contents ubuf))
      else None
    (* 3. Namespace state — usually lower churn than inbox/board detail.
       Rendered on every turn: the backlog readability fact and the running
       fiber count are observed on every turn, and an omitted section states
       nothing about a backlog that was read and holds no rows. *)
    | Keeper_context_layers.Namespace_state ->
      Some
        (let ubuf = Buffer.create 256 in
         let claimable_task_count =
           Keeper_world_observation.claimable_task_count observation
         in
         Buffer.add_string
           ubuf
           (render_fragment Prompt_names.keeper_world_namespace_state_heading [] ^ "\n");
         (match backlog_statement_of_observation observation with
          | Backlog_unreadable ->
            Buffer.add_string
              ubuf
              (render_fragment
                 Prompt_names.keeper_world_namespace_state_backlog_unreadable
                 []
               ^ "\n")
          | Backlog_readable_empty ->
            Buffer.add_string
              ubuf
              (render_fragment Prompt_names.keeper_world_namespace_state_backlog_empty []
               ^ "\n")
          | Backlog_readable_with_rows -> ());
         (* The counts and ids below describe a set; they do not say whether it
           is the set the last turn described. A keeper that concluded "nothing
           actionable" reads "3 unclaimed" the same way whether those are the
           same three tasks or three different ones, so the conclusion outlives
           whatever made it true. A Keeper instructed to take
           unclaimed work on sight -- repeated one verbatim across every turn of
           a day while its stated reason, that the three were blocked, appeared
           nowhere in the backlog (#27629).

           The revision is what changes when the backlog does. It is an int the
           snapshot already carries and until now spent only on a presence check
           in [backlog_statement_of_observation], so nothing new is read and no
           keeper-authored text crosses into the frame. *)
         (match observation.backlog_revision with
          | None -> ()
          | Some revision ->
            Buffer.add_string
              ubuf
              (render_fragment
                 Prompt_names.keeper_world_namespace_state_backlog_revision
                 [ "revision", string_of_int revision ]
               ^ "\n"));
         if observation.unclaimed_task_count > 0
         then
           Buffer.add_string
             ubuf
             (render_fragment
                Prompt_names.keeper_world_namespace_state_unclaimed
                [ "count", string_of_int observation.unclaimed_task_count ]
              ^ "\n");
         if claimable_task_count > 0
         then (
           Buffer.add_string
             ubuf
             (render_fragment
                Prompt_names.keeper_world_namespace_state_claimable
                [ "count", string_of_int claimable_task_count ]
              ^ "\n");
           (* The count says work exists; these say which. Without them a keeper
             that wants to claim has to decide to spend a tool call first, and
             one spent 286 turns reasoning about which tasks were open from a
             12-hour-old memory rather than looking. The Goal blocks above name
             their rows for the same reason.

             Bounded like the Board activity render (#27369): a long backlog
             would otherwise push the rest of the frame out, and the heading
             says how many are shown against how many exist. *)
           match observation.claimable_tasks with
           | [] -> ()
           | summaries ->
             let shown = take claimable_task_render_budget_rows summaries in
             Buffer.add_string
               ubuf
               (String.concat
                  ""
                  (List.map
                     (fun (summary :
                            Keeper_world_observation_inputs.claimable_task_identity) ->
                        Printf.sprintf
                          "  - %s\n"
                          (Yojson.Safe.to_string
                             (`Assoc
                                 [ ( "task_id"
                                   , `String (Keeper_id.Task_id.to_string summary.task_id)
                                   )
                                 ])))
                     shown));
             if List.length summaries > List.length shown
             then
               Buffer.add_string
                 ubuf
                 (* The slot paragraph is trimmed at load, so the two-space
                   indent the budget line carries is re-added here. *)
                 ("  "
                  ^ render_fragment
                      Prompt_names.keeper_world_namespace_state_claimable_more
                      [ "count", string_of_int (List.length summaries - List.length shown)
                      ]
                  ^ "\n"));
         if observation.unclaimed_task_count > 0 && claimable_task_count = 0
         then
           Buffer.add_string
             ubuf
             (render_fragment
                Prompt_names.keeper_world_namespace_state_claimable
                [ "count", "0" ]
              ^ "\n");
         (* The difference is exactly two things: a Todo task still holding a
           verification verdict, and a Todo task this keeper wrote itself. No
           goal, tool, or keeper scope narrows the claim pool. *)
         let unclaimed_not_offered =
           max 0 (observation.unclaimed_task_count - claimable_task_count)
         in
         if unclaimed_not_offered > 0
         then
           Buffer.add_string
             ubuf
             (render_fragment
                Prompt_names.keeper_world_namespace_state_unclaimed_not_offered
                [ "count", string_of_int unclaimed_not_offered ]
              ^ "\n");
         if observation.failed_task_count > 0
         then
           Buffer.add_string
             ubuf
             (render_fragment
                Prompt_names.keeper_world_namespace_state_failed
                [ "count", string_of_int observation.failed_task_count ]
              ^ "\n");
         Buffer.add_string
           ubuf
           (render_fragment
              Prompt_names.keeper_world_namespace_state_running_fibers
              [ "count", string_of_int observation.running_keeper_fiber_count ]
            ^ "\n");
         Buffer.add_char ubuf '\n';
         Buffer.contents ubuf)
    (* Repository freshness — semi-stable standing context: it moves when the
       keeper commits or upstream advances, not per cycle. Projection only —
       it states where each checkout stands so the keeper can choose to
       fetch/rebase; nothing here schedules or forces that work. *)
    | Keeper_context_layers.Repository_freshness ->
      (match repository_freshness with
       | [] -> None
       | rows ->
         (* Measured rows render individually, drifted first — the layer
            exists to surface drift, and a current checkout is the least
            actionable line. Unmeasurable rows collapse into one count: a
            live playground answered 19 of 32 rows with the same
            budget-exhausted reason (2026-09-01 field probe), and repeating
            an identical failure line 19 times per turn is noise the
            keeper_status tool already carries in full. *)
         let measured, unmeasured =
           List.partition
             (fun (row : Keeper_sandbox_control.freshness_row) ->
               match row.Keeper_sandbox_control.row_freshness with
               | Keeper_sandbox_control.Freshness_unavailable _ -> false
               | Keeper_sandbox_control.Current _
               | Keeper_sandbox_control.Ahead _
               | Keeper_sandbox_control.Behind _
               | Keeper_sandbox_control.Diverged _ -> true)
             rows
         in
         let drift_rank (row : Keeper_sandbox_control.freshness_row) =
           match row.Keeper_sandbox_control.row_freshness with
           | Keeper_sandbox_control.Diverged _ -> 0
           | Keeper_sandbox_control.Behind _ -> 1
           | Keeper_sandbox_control.Ahead _ -> 2
           | Keeper_sandbox_control.Current _ -> 3
           | Keeper_sandbox_control.Freshness_unavailable _ -> 4
         in
         let measured =
           List.stable_sort
             (fun left right -> compare (drift_rank left) (drift_rank right))
             measured
         in
         let line (row : Keeper_sandbox_control.freshness_row) =
           let branch_part =
             match row.Keeper_sandbox_control.row_branch with
             | Some branch -> " branch=" ^ branch
             | None -> ""
           in
           let dirty_part =
             match row.Keeper_sandbox_control.row_changed_files with
             (* [Some 0] is a clean tree and [None] a failed status probe;
                neither earns a line of the keeper's attention here — a
                broken probe already surfaces as [Freshness_unavailable]. *)
             | Some 0 | None -> ""
             | Some changed -> Printf.sprintf " dirty_files=%d" changed
           in
           let standing =
             match row.Keeper_sandbox_control.row_freshness with
             | Keeper_sandbox_control.Current { target_ref; _ } ->
               render_fragment
                 Prompt_names.keeper_context_checkouts_standing_current
                 [ "target", target_ref ]
             | Keeper_sandbox_control.Ahead { target_ref; ahead; _ } ->
               render_fragment
                 Prompt_names.keeper_context_checkouts_standing_ahead
                 [ "target", target_ref; "ahead", string_of_int ahead ]
             | Keeper_sandbox_control.Behind { target_ref; behind; _ } ->
               render_fragment
                 Prompt_names.keeper_context_checkouts_standing_behind
                 [ "target", target_ref; "behind", string_of_int behind ]
             | Keeper_sandbox_control.Diverged { target_ref; ahead; behind; _ } ->
               render_fragment
                 Prompt_names.keeper_context_checkouts_standing_diverged
                 [ "target", target_ref
                 ; "behind", string_of_int behind
                 ; "ahead", string_of_int ahead
                 ]
             | Keeper_sandbox_control.Freshness_unavailable reason ->
               render_fragment
                 Prompt_names.keeper_context_checkouts_standing_unavailable
                 [ "reason", reason ]
           in
           render_fragment Prompt_names.keeper_context_checkouts_row
             [ "path", row.Keeper_sandbox_control.row_checkout_path
             ; "branch", branch_part
             ; "dirty", dirty_part
             ; "standing", standing
             ]
         in
         let unmeasured_line =
           match List.length unmeasured with
           | 0 -> []
           | count ->
             [ render_fragment Prompt_names.keeper_context_checkouts_unmeasured
                 [ "count", string_of_int count ]
             ]
         in
         Some
           (render_fragment Prompt_names.keeper_context_checkouts_section
              [ "count", string_of_int (List.length rows)
              ; ( "rows"
                , String.concat "\n" (List.map line measured @ unmeasured_line) )
              ]
            ^ "\n\n"))
    (* 4. Autonomous trigger — lower churn than reactive inboxes. *)
    | Keeper_context_layers.Autonomous_trigger ->
      if autonomous_trigger <> [] then
        Some
          ("\n"
           ^ render_fragment Prompt_names.keeper_world_autonomous_trigger_heading []
           ^ "\n"
           ^ String.concat "\n" autonomous_trigger
           ^ "\n")
      else None
    (* 5. Scheduled automation — durable MASC schedule store plus the exact
       message carried by a consumed Schedule_due stimulus. The request is work
       context, while effect authority remains exclusively Gate-owned. *)
    | Keeper_context_layers.Scheduled_automation ->
      combine_prompt_sections
        [ format_scheduled_automation_summary observation.scheduled_automation
        ; format_scheduled_wake_observations
            (List.filter
               Keeper_world_observation.is_scheduled_automation_event
               observation.pending_board_events)
        ]
    (* 5b. Completion-authority decisions — a distinct system LLM boundary.
       These rows are not Board activity and must not be routed through the
       scheduled-work renderer merely because they share the historical
       pending-event carrier. *)
    | Keeper_context_layers.Completion_authority ->
      format_completion_authority_rejection_observations
        observation.pending_board_events
    (* 6b. Cancellations of Tasks this Keeper authored — the author's only
       in-prompt account of why work it filed stopped. Not Board activity: the
       cancellation produces no post. *)
    | Keeper_context_layers.Task_cancellations ->
      format_task_cancellation_observations observation.pending_board_events
    (* Pending message rows are rendered once in exact source order. Mention and
       scope remain typed for wake metrics, but splitting them into two prompt
       sections would reorder interleaved arrivals. *)
    | Keeper_context_layers.Pending_mentions ->
      if observation.pending_messages <> [] then
        Some
          (render_fragment
             Prompt_names.keeper_world_pending_messages_heading
             [ "count", string_of_int (List.length observation.pending_messages) ]
           ^ "\n"
           ^ render_fragment Prompt_names.keeper_world_pending_messages_intro []
           ^ "\n"
           ^ format_pending_messages observation.pending_messages
           ^ "\n\n")
      else None
    | Keeper_context_layers.Scope_messages -> None
    (* 9b. Own recent board posts — the keeper's own published posts, newest
       first. Cursor-independent standing context: Board_activity only carries
       other authors' unseen posts, so this is the only in-prompt view of what
       the keeper itself has already said. Neutral rows, no advisory text. *)
    | Keeper_context_layers.Own_board_posts ->
      if observation.own_recent_board_posts <> [] then (
        let ubuf = Buffer.create 256 in
        Buffer.add_string ubuf
          (render_fragment
             Prompt_names.keeper_world_own_board_posts_heading
             [ "count", string_of_int (List.length observation.own_recent_board_posts) ]
           ^ "\n");
        Buffer.add_string ubuf
          (render_fragment Prompt_names.keeper_world_own_board_posts_intro [] ^ "\n");
        Buffer.add_string ubuf
          (observation.own_recent_board_posts
           |> List.map format_own_board_post_text
           |> String.concat "\n");
        Buffer.add_string ubuf "\n\n";
        Some (Buffer.contents ubuf))
      else None
    (* 10. Board activity — reactive trigger. All authors and post kinds share
       one neutral observation renderer. Exact mention remains routing context;
       it never promotes Board content to instruction authority. *)
    | Keeper_context_layers.Board_activity ->
      let board_events =
        List.filter
          Keeper_world_observation.is_board_activity_event
          observation.pending_board_events
      in
      if board_events <> [] then (
        let total = List.length board_events in
        let ubuf = Buffer.create 256 in
        Buffer.add_string ubuf
          (render_fragment
             Prompt_names.keeper_world_board_activity_heading
             [ "count", string_of_int total ]
           ^ "\n");
        Buffer.add_string ubuf (render_board_observations board_events);
        Buffer.add_string ubuf "\n\n";
        Some (Buffer.contents ubuf))
      else None
    (* 11. Fleet messages — what other keepers said, projected into this
       keeper's transcript. Cursor-independent standing context: the reactive
       lanes admit only rows addressed to this keeper, so without this section
       a fleet broadcast reaches the dashboard and never the prompt. Neutral
       rows, no advisory text; no watermark, so a keeper that never runs an
       autonomous turn accumulates nothing. *)
    (* What this keeper already did. Without it an autonomous turn re-claims a
       task it finished and repeats a call the tool just rejected, because the
       briefing describes the world and never the keeper's own history. Both
       outcomes are shown: the rejections are what the keeper must not repeat,
       the successes are what it must not redo. *)
    | Keeper_context_layers.Own_recent_actions ->
      Option.map Keeper_context_layers.section_text own_recent_actions_section
    | Keeper_context_layers.Fleet_messages ->
      if observation.fleet_messages <> [] then (
        let ubuf = Buffer.create 256 in
        Buffer.add_string ubuf
          (render_fragment
             Prompt_names.keeper_world_fleet_messages_heading
             [ "count", string_of_int (List.length observation.fleet_messages) ]
           ^ "\n");
        Buffer.add_string ubuf
          (render_fragment Prompt_names.keeper_world_fleet_messages_intro [] ^ "\n");
        Buffer.add_string ubuf (format_fleet_messages observation.fleet_messages);
        Buffer.add_string ubuf "\n\n";
        Some (Buffer.contents ubuf))
      else None
  in
  (* Exhaustive rather than a catch-all: a new layer must state whether it
     renders one indivisible block or rows the budget may withhold, and
     {!Keeper_context_layers.retention} must agree. A catch-all here would let
     a layer declare itself trimmable and silently never trim. *)
  let content_of : Keeper_context_layers.layer_id -> Keeper_context_layers.section option
    = function
    | Keeper_context_layers.Own_recent_actions -> own_recent_actions_section
    | ( Keeper_context_layers.Active_goals
      | Keeper_context_layers.Current_task
      | Keeper_context_layers.Approval_authority
      | Keeper_context_layers.Connected_surfaces
      | Keeper_context_layers.Namespace_state
      | Keeper_context_layers.Repository_freshness
      | Keeper_context_layers.Autonomous_trigger
      | Keeper_context_layers.Scheduled_automation
      | Keeper_context_layers.Completion_authority
      | Keeper_context_layers.Task_cancellations
      | Keeper_context_layers.Pending_mentions
      | Keeper_context_layers.Scope_messages
      | Keeper_context_layers.Own_board_posts
      | Keeper_context_layers.Board_activity
      | Keeper_context_layers.Fleet_messages ) as id ->
      Option.map (fun text -> Keeper_context_layers.Block text) (text_of id)
  in
  (* The frame is injected as ephemeral context. The turn call site passes an
     explicit [world_state_prompt] source to history persistence, so JSONL
     routing does not depend on any markdown wording below.

     The provenance line is what the sections underneath do not carry. A block
     headed "### Your Recent Board Posts" reads as something the keeper did,
     and nothing in the frame says the runtime assembled it, so a keeper that
     then reports "I checked the board" is misreading its own frame rather than
     inventing a tool call. Stating where the frame came from is what makes
     that distinction available to the model. *)
  let world_state =
    render_fragment Prompt_names.keeper_world_frame_frame []
    ^ "\n\n"
    ^ Keeper_context_layers.assemble ?budget_bytes:context_budget_bytes ~content_of ()
  in
  let user_message = Env_config_keeper.KeeperAutonomous.wake_prompt () in
  { system_prompt; world_state; user_message }
;;

let emit_prompt_metrics
      ~(meta : Keeper_meta_contract.keeper_meta)
      { system_prompt; world_state; user_message }
  =
  (* Tool names and availability come exclusively from the typed schemas sent
     with this turn. Prompt markdown describes behaviour rather than attempting
     to mirror that catalog. World-state observations remain byte-for-byte
     intact; unknown calls are rejected explicitly by typed dispatch. *)
  (* set_gauge only: a stray inc_counter here used to create this
     (name, labels) cell as Counter first, so the system_prompt series
     kept Counter kind, carried a non-monotonic byte length, and exported
     as masc_keeper_prompt_segment_bytes_total while user_message exported
     as the intended gauge. The store keys cells by (name, labels) and
     never retypes an existing cell. *)
  Otel_metric_store.set_gauge
    (Keeper_metrics.to_string PromptSegmentBytes)
    ~labels:[("keeper", meta.name); ("segment", "system_prompt")]
    (Float.of_int (String.length system_prompt));
  Otel_metric_store.set_gauge
    (Keeper_metrics.to_string PromptSegmentBytes)
    ~labels:[("keeper", meta.name); ("segment", "world_state")]
    (Float.of_int (String.length world_state));
  Otel_metric_store.set_gauge
    (Keeper_metrics.to_string PromptSegmentBytes)
    ~labels:[("keeper", meta.name); ("segment", "user_message")]
    (Float.of_int (String.length user_message));
  (* Instruction hash: emit a stable numeric fingerprint of the full prompt
     composition (system + user) so Grafana can detect when the instruction
     changes between turns without storing the prompt content itself.
     Uses first 8 hex chars of SHA-256 as an integer (32-bit). *)
  let prompt_hash =
    let combined = system_prompt ^ world_state ^ user_message in
    let hex =
      Digestif.SHA256.(to_hex (digest_string combined))
    in
    Int32.to_float (Int32.of_string ("0x" ^ String.sub hex 0 8))
  in
  Otel_metric_store.set_gauge
    (Keeper_metrics.to_string KeeperTurnInstructionHash)
    ~labels:[("keeper", meta.name)]
    prompt_hash
;;

let build_prompt
      ~meta
      ~config
      ?profile_defaults
      ~turn_decision
      ?previous_turn_stop
      ~current_task
      ?task_skill_surfaces
      ?active_goal_summaries
      ?repository_freshness
      ?context_budget_bytes
      ~observation
      ()
  =
  let prompt =
    build_prompt_internal
      ~meta
      ~config
      ?profile_defaults
      ~turn_decision:(Some turn_decision)
      ?previous_turn_stop
      ~current_task
      ?task_skill_surfaces
      ?active_goal_summaries
      ?repository_freshness
      ?context_budget_bytes
      ~observation
      ()
  in
  emit_prompt_metrics ~meta prompt;
  prompt
;;

let build_prompt_preview
      ~meta
      ~config
      ?profile_defaults
      ~current_task
      ?task_skill_surfaces
      ?active_goal_summaries
      ?repository_freshness
      ~observation
      ()
  =
  build_prompt_internal
    ~meta
    ~config
    ?profile_defaults
    ~turn_decision:None
    ~current_task
    ?task_skill_surfaces
    ?active_goal_summaries
    ?repository_freshness
    ~observation
    ()
;;
