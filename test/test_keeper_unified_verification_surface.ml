open Alcotest

module WO = Masc.Keeper_world_observation
module UM = Masc.Keeper_unified_metrics

let base_observation : WO.world_observation =
  {
    pending_messages = [];
    pending_board_events = [];
    idle_seconds = 0;
    active_goals = [];
    unclaimed_task_count = 0;
    claimable_task_count = 0;
    failed_task_count = 0;
    scheduled_automation = WO.empty_scheduled_automation_observation;
    backlog_updated_since_last_scheduled_autonomous = false;
    backlog_revision = Some 1;
    running_keeper_fiber_count = 0;
    connected_surfaces = [];
    connected_surface_failures = [];
    own_recent_board_posts = [];
  }

let sample_board_event : WO.pending_board_event =
  {
    event_kind = WO.Board_post_created;
    post_id = "board-post-1";
    author = "alice";
    title = "Need help";
    preview = "Please take a look.";
    hearth = Some "research";
    post_kind = Masc.Board.Human_post;
    updated_at = 0.0;
    explicit_mention = false;
    matched_targets = [];
    self_commented = false;
    new_external_since = 0;
    latest_external_author = None;
    latest_external_preview = None;
  }

let sample_scheduled_wake : WO.pending_board_event =
  { sample_board_event with
    event_kind = WO.Schedule_due
  ; post_id = "schedule-occurrence:2026-07-28T06:22:07+09:00"
  ; author = "scheduled_automation"
  ; title = "Hourly research"
  ; preview =
      "Search the web for the latest OCaml release notes, then write a cited summary."
  ; post_kind = Masc.Board.System_post
  }
;;

let sample_completion_authority_rejection : WO.pending_board_event =
  let rejection : Keeper_event_queue.completion_authority_rejection =
    { car_task_id = "task-rejected"
    ; car_verification_id = "verification-rejected"
    ; car_reason = "evidence omitted the required deployment proof"
    ; car_authority = Masc_domain.System_llm_agent { agent_run_id = "system-agent-test" }
    }
  in
  { sample_board_event with
    event_kind = WO.Completion_authority_rejected rejection
  ; post_id = "completion-authority-rejected:task-rejected:verification-rejected"
  ; author = "system-agent-test"
  ; title = "Completion evidence rejected for task task-rejected"
  ; preview =
      "Task task-rejected verification verification-rejected was rejected by the system completion authority"
  ; post_kind = Masc.Board.System_post
  }
;;

let scheduled_automation_observation : WO.scheduled_automation_observation =
  { active_count = 1
  ; due_ready_count = 1
  ; next_due_at = Some 200.0
  ; items =
      [ { schedule_id = "sched-ready"
        ; action = "dispatch_ready"
        ; status = "due"
        ; payload_kind = Some "masc.board_post"
        ; recurrence_summary = "daily 09:00:00 Asia/Seoul"
        ; due_at = 200.0
        }
      ]
  }
;;

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String ("test-trace-" ^ name));
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

let minimal_meta : Masc.Keeper_meta_contract.keeper_meta = make_meta "test-keeper"

let build_prompt ~meta observation =
  let turn_decision =
    Masc.Keeper_world_observation.keeper_cycle_decision ~meta observation
  in
  Masc.Keeper_unified_prompt.build_prompt
    ~meta
    ~base_path:"/tmp"
    ~turn_decision
    ~current_task:Masc.Keeper_world_observation_inputs.No_current_task
    ~observation
    ()
;;

let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}
;;

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "keeper_schedule_observation_runtime_" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc runtime_toml);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e
;;

(* A verifier is not a Keeper. An AwaitingVerification obligation is decided by
   the completion authority (HITL confirmation / fusion judge), never through
   keeper tool surface, so no keeper — whatever its mention tags — is offered a
   task_verify affordance. Guards against a keeper named "verifier" re-acquiring
   approval authority. *)
let test_no_task_verify_affordance_for_any_keeper () =
  let tagged = { minimal_meta with mention_targets = [ "verifier" ] } in
  check bool "no task_verify for verifier-tagged keeper" false
    (List.mem "task_verify"
       (UM.observed_affordances_of_observation ~meta:tagged base_observation));
  check bool "no task_verify without meta" false
    (List.mem "task_verify" (UM.observed_affordances_of_observation base_observation))

let test_board_activity_exposes_curation_affordance_without_threshold () =
  let obs =
    { base_observation with pending_board_events = [ sample_board_event ] }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "board_curation present" true
    (List.mem "board_curation" affordances)

let test_no_board_activity_has_no_curation_affordance () =
  let affordances = UM.observed_affordances_of_observation base_observation in
  check bool "board_curation absent without Board activity" false
    (List.mem "board_curation" affordances)

let contains_sub sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  let rec aux i =
    if i + sub_len > s_len then false
    else if String.sub s i sub_len = sub then true
    else aux (i + 1)
  in
  if sub_len = 0 then true else aux 0
;;

let test_board_authors_share_one_neutral_observation_boundary () =
  Masc_test_deps.init_keeper_tool_registry ();
  let peer_event =
    {
      sample_board_event with
      post_id = "peer-post-1";
      author = "keeper-ramarama-agent";
      preview = "I assert the build is green.";
      post_kind = Masc.Board.Automation_post;
      explicit_mention = true;
      matched_targets = [ "test-keeper" ];
    }
  in
  let human_event = { sample_board_event with post_id = "human-1" } in
  let obs_peer = { base_observation with pending_board_events = [ peer_event ] } in
  let obs_human = { base_observation with pending_board_events = [ human_event ] } in
  let { Masc.Keeper_unified_prompt.world_state = peer_msg; _ } =
    build_prompt ~meta:minimal_meta obs_peer
  in
  let { Masc.Keeper_unified_prompt.world_state = human_msg; _ } =
    build_prompt ~meta:minimal_meta obs_human
  in
  let neutral_boundary = "Rows below are Board context." in
  check bool "automation event uses neutral boundary" true
    (contains_sub neutral_boundary peer_msg);
  check bool "human event uses the same neutral boundary" true
    (contains_sub neutral_boundary human_msg);
  check bool "metadata does not create a local authority ranking" true
    (contains_sub "not a local authority ranking" peer_msg
     && contains_sub "not a local authority ranking" human_msg);
  check bool "configured model judges content and context" true
    (contains_sub "Judge relevance and response from the content" peer_msg
     && contains_sub "Judge relevance and response from the content" human_msg);
  check bool "external effects stay behind the Gate" true
    (contains_sub "external effects cross the Gate" peer_msg
     && contains_sub "external effects cross the Gate" human_msg);
  check bool "automation post kind remains context" true
    (contains_sub "post_kind=automation" peer_msg);
  check bool "human post kind remains context" true
    (contains_sub "post_kind=direct" human_msg);
  check bool "exact mention remains context" true
    (contains_sub "[mentions test-keeper]" peer_msg)
;;

let test_board_reaction_event_renders_reaction_context () =
  Masc_test_deps.init_keeper_tool_registry ();
  let reaction_event =
    {
      sample_board_event with
      event_kind =
        WO.Board_reaction_changed
          {
            target_type = Masc.Board.Reaction_comment;
            target_id = "comment-1";
            user_id = "reactor";
            emoji = "👏";
            reacted = true;
          };
      post_id = "reaction-parent";
      author = "reactor";
    }
  in
  let obs = { base_observation with pending_board_events = [ reaction_event ] } in
  let { Masc.Keeper_unified_prompt.world_state = user_msg; _ } =
    build_prompt ~meta:minimal_meta obs
  in
  check bool "prompt labels reaction board event" true
    (contains_sub "event=reaction_changed" user_msg);
  check bool "prompt includes reaction target" true
    (contains_sub "target=comment:comment-1" user_msg);
  check bool "prompt includes reaction actor" true
    (contains_sub "user=reactor" user_msg);
  check bool "prompt includes reaction emoji" true
    (contains_sub "emoji=\"👏\"" user_msg)
;;

(* Structured world-state values are observations, not tool instructions. A
   diagnostic token must survive prompt assembly verbatim; the instruction
   token scanner is intentionally not allowed to rewrite this surface. *)
let test_observation_tool_names_are_preserved () =
  Masc_test_deps.init_keeper_tool_registry ();
  let event =
    {
      sample_board_event with
      post_id = "diagnostic-observation-1";
      preview = "keeper_turn_id=turn-1 masc_oas_error=provider-timeout";
    }
  in
  let obs = { base_observation with pending_board_events = [ event ] } in
  let { Masc.Keeper_unified_prompt.world_state = user_msg; _ } =
    build_prompt ~meta:minimal_meta obs
  in
  check bool "keeper diagnostic token remains in observation" true
    (contains_sub "keeper_turn_id=turn-1" user_msg);
  check bool "OAS diagnostic token remains in observation" true
    (contains_sub "masc_oas_error=provider-timeout" user_msg);
  check bool "observation remains intact" true
    (contains_sub event.preview user_msg)
;;

let test_task_claim_requires_matched_backlog () =
  let obs =
    { base_observation with unclaimed_task_count = 3; claimable_task_count = 0 }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "task_claim absent for unclaimable backlog" false
    (List.mem "task_claim" affordances)

let test_task_claim_present_for_claimable_backlog () =
  let obs =
    { base_observation with unclaimed_task_count = 3; claimable_task_count = 1 }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "task_claim present for matched backlog" true
    (List.mem "task_claim" affordances)

let test_backlog_trigger_split () =
  let obs =
    { base_observation with unclaimed_task_count = 3; claimable_task_count = 1 }
  in
  let triggers = UM.observed_triggers_of_observation obs in
  check bool "claimable backlog trigger remains visible" true
    (List.mem "new_unclaimed_task" triggers);
  check bool "matched backlog trigger is explicit" true
    (List.mem "claimable_task" triggers)

let test_unclaimable_backlog_is_not_a_claim_trigger () =
  let obs =
    { base_observation with unclaimed_task_count = 3; claimable_task_count = 0 }
  in
  let triggers = UM.observed_triggers_of_observation obs in
  check bool "unclaimable backlog is not a new task trigger" false
    (List.mem "new_unclaimed_task" triggers);
  check bool "unclaimable backlog is not a claimable task trigger" false
    (List.mem "claimable_task" triggers)

(* Same boundary as the affordance guard above, at the wake-trigger layer: an
   AwaitingVerification obligation is not a keeper wake signal. *)
let test_no_pending_verification_trigger_for_any_keeper () =
  let tagged = { minimal_meta with mention_targets = [ "검증자" ] } in
  check bool "no pending_verification trigger for verifier-tagged keeper" false
    (List.mem "pending_verification"
       (UM.observed_triggers_of_observation ~meta:tagged base_observation));
  check bool "no pending_verification trigger without meta" false
    (List.mem "pending_verification"
       (UM.observed_triggers_of_observation base_observation))

let test_scheduled_automation_triggers_and_affordances () =
  let obs =
    { base_observation with scheduled_automation = scheduled_automation_observation }
  in
  let triggers = UM.observed_triggers_of_observation obs in
  check bool "due-ready schedule trigger present" true
    (List.mem "scheduled_automation_due_ready" triggers);
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "dispatch monitor affordance present" true
    (List.mem "schedule_dispatch_monitor" affordances)

let test_scheduled_automation_prompt_section () =
  Masc_test_deps.init_keeper_tool_registry ();
  init_runtime_default_for_tests ();
  let obs =
    { base_observation with scheduled_automation = scheduled_automation_observation }
  in
  let { Masc.Keeper_unified_prompt.world_state = user_msg; _ } =
    build_prompt ~meta:minimal_meta obs
  in
  check bool "prompt includes schedule section" true
    (contains_sub "### Scheduled Automation" user_msg);
  check bool "prompt includes ready schedule id" true
    (contains_sub "schedule_id=sched-ready" user_msg)

let test_scheduled_wake_is_not_rendered_as_board_activity () =
  Masc_test_deps.init_keeper_tool_registry ();
  init_runtime_default_for_tests ();
  let obs =
    { base_observation with
      pending_board_events = [ sample_board_event; sample_scheduled_wake ]
    }
  in
  let { Masc.Keeper_unified_prompt.world_state; _ } =
    build_prompt ~meta:minimal_meta obs
  in
  check bool "scheduled wake has dedicated section" true
    (contains_sub "### Scheduled Wake (1 due)" world_state);
  check bool "scheduled message remains complete" true
    (contains_sub sample_scheduled_wake.preview world_state);
  check bool "occurrence is explicitly not a Board post" true
    (contains_sub "never pass it to a Board tool" world_state);
  let board_section =
    match
      String.split_on_char '#' world_state
      |> List.find_opt (contains_sub "Board Activity")
    with
    | Some section -> section
    | None -> fail "expected Board Activity section"
  in
  check bool "real Board row remains present" true
    (contains_sub sample_board_event.post_id board_section);
  check bool "scheduled occurrence absent from Board section" false
    (contains_sub sample_scheduled_wake.post_id board_section);
  let schedule_only_observation =
    { base_observation with pending_board_events = [ sample_scheduled_wake ] }
  in
  check bool "scheduled work is not typed as Board activity" false
    (WO.has_pending_board_activity schedule_only_observation);
  let triggers = UM.observed_triggers_of_observation schedule_only_observation in
  check bool "scheduled work emits no Board trigger" false
    (List.mem "board_activity" triggers);
  let affordances =
    UM.observed_affordances_of_observation schedule_only_observation
  in
  check bool "scheduled work emits no Board response affordance" false
    (List.mem "board_post_or_comment" affordances);
  check bool "scheduled work emits no Board curation affordance" false
    (List.mem "board_curation" affordances)
;;

let test_scheduled_wake_preserves_complete_message () =
  let exact_message = String.make 520 'x' ^ "SCHEDULE-TAIL-TOKEN" in
  let wake : Keeper_event_queue.scheduled_wake =
    { schedule_id = "sched-long-message"
    ; due_at = 200.0
    ; payload_digest = "digest-long-message"
    ; title = Some "Long scheduled work"
    ; message = exact_message
    }
  in
  let event =
    WO.pending_board_event_of_scheduled_wake
      ~meta:minimal_meta
      ~post_id:"schedule-occurrence:long-message"
      ~arrived_at:200.0
      wake
  in
  check string "scheduled work message is not truncated" exact_message event.preview
;;

let test_completion_authority_rejection_has_own_prompt_layer () =
  Masc_test_deps.init_keeper_tool_registry ();
  init_runtime_default_for_tests ();
  let obs =
    { base_observation with
      pending_board_events =
        [ sample_board_event; sample_completion_authority_rejection ]
    }
  in
  let { Masc.Keeper_unified_prompt.world_state; _ } =
    build_prompt ~meta:minimal_meta obs
  in
  check bool "system authority section is present" true
    (contains_sub "### Completion Authority Decisions (1)" world_state);
  check bool "typed rejection reason is preserved" true
    (contains_sub "evidence omitted the required deployment proof" world_state);
  check bool "system LLM provenance is preserved" true
    (contains_sub "authority_kind=system_llm_agent" world_state);
  check bool "rejection is not rendered as Board activity" false
    (contains_sub
       sample_completion_authority_rejection.post_id
       (match
          String.split_on_char '#' world_state
          |> List.find_opt (contains_sub "Board Activity")
        with
        | Some section -> section
        | None -> ""));
  check bool "rejection is not rendered as scheduled work" false
    (contains_sub "### Scheduled Wake" world_state);
  check bool "rejection does not count as Board activity" false
    (WO.has_pending_board_activity
       { base_observation with
         pending_board_events = [ sample_completion_authority_rejection ] })
;;

let test_completion_authority_rejection_preserves_human_provenance () =
  Masc_test_deps.init_keeper_tool_registry ();
  init_runtime_default_for_tests ();
  let rejection : Keeper_event_queue.completion_authority_rejection =
    { car_task_id = "task-human-rejected"
    ; car_verification_id = "verification-human-rejected"
    ; car_reason = "operator requires another artifact"
    ; car_authority = Masc_domain.Human_operator { operator_id = "operator-test" }
    }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.completion_authority_rejection_post_id rejection
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = 42.0
    ; payload = Keeper_event_queue.Completion_authority_rejected rejection
    }
  in
  let event =
    match WO.pending_board_event_of_stimulus ~meta:minimal_meta stimulus with
    | Ok (Some event) -> event
    | Ok None -> fail "completion authority rejection must produce an event"
    | Error _ -> fail "completion authority rejection must not read Board state"
  in
  let { Masc.Keeper_unified_prompt.world_state; _ } =
    build_prompt
      ~meta:minimal_meta
      { base_observation with pending_board_events = [ event ] }
  in
  check bool "human authority kind is preserved" true
    (contains_sub "authority_kind=human_operator" world_state);
  check bool "human rejection is not relabeled as system authority" false
    (contains_sub "system completion authority" world_state)
;;

(* Feedback-loop invariant (#25193): the observation frame must ride the
   ephemeral [world_state] channel, never the persisted [user_message].
   Under the pre-split behaviour (frame concatenated into the user message)
   both checks below go red: the marker check because the user message
   started with "## Current World State", and the containment check because
   the frame text was present in the persisted channel. *)
let test_world_state_never_in_persisted_user_message () =
  let obs = { base_observation with pending_board_events = [ sample_board_event ] } in
  let { Masc.Keeper_unified_prompt.world_state; user_message; _ } =
    build_prompt ~meta:minimal_meta obs
  in
  check bool "world_state carries the frame header" true
    (contains_sub "## Current World State" world_state);
  check bool "persisted user message is the wake marker" true
    (String.equal user_message
       Masc.Keeper_unified_prompt.autonomous_wake_marker);
  check bool "persisted user message carries no frame header" false
    (contains_sub "## Current World State" user_message);
  check bool "persisted user message carries no board observation" false
    (contains_sub "### Board Activity" user_message)

(* RFC-0351 section 5 / #25462: splitting the frame out of the user message
   (above) left the marker itself still being recorded once per wake, so the
   duplication moved from bytes to message count — one keeper accumulated 359
   copies of the same 147B constant, part of a 25.7% exact-dup transcript
   share. A bare wake now skips the transcript entirely; only a turn carrying a
   HITL resolution is recorded. *)
let test_bare_autonomous_wake_is_not_recorded () =
  check bool "bare autonomous wake skips the transcript" true
    (Masc.Keeper_run_prompt.user_turn_record_of_hitl_resolution None
     = Masc.Keeper_run_prompt.Skip_uninformative_wake);
  check bool "a turn carrying a HITL resolution is recorded" true
    (Masc.Keeper_run_prompt.user_turn_record_of_hitl_resolution (Some ())
     = Masc.Keeper_run_prompt.Record_user_turn)

(* One execution-fact decision now owns both replay persistence and librarian
   extraction. A routed continuation is meaningful without a tool call; idle
   model prose on a scheduled bare wake is not. *)
let test_turn_effect_record () =
  let decide ~user_turn_record ~tool_calls_made ~external_delivery_routed =
    Masc.Keeper_run_prompt.turn_effect_record_of_turn
      ~user_turn_record ~tool_calls_made ~external_delivery_routed
  in
  check bool "bare wake with no effect is inert" true
    (decide
       ~user_turn_record:Masc.Keeper_run_prompt.Skip_uninformative_wake
       ~tool_calls_made:false
       ~external_delivery_routed:false
     = Masc.Keeper_run_prompt.Inert_autonomous_turn);
  check bool "bare wake that ran a tool is meaningful" true
    (decide
       ~user_turn_record:Masc.Keeper_run_prompt.Skip_uninformative_wake
       ~tool_calls_made:true
       ~external_delivery_routed:false
     = Masc.Keeper_run_prompt.Meaningful_turn);
  check bool "routed continuation is meaningful without a tool" true
    (decide
       ~user_turn_record:Masc.Keeper_run_prompt.Skip_uninformative_wake
       ~tool_calls_made:false
       ~external_delivery_routed:true
     = Masc.Keeper_run_prompt.Meaningful_turn);
  check bool "operator/HITL input is meaningful without a tool" true
    (decide
       ~user_turn_record:Masc.Keeper_run_prompt.Record_user_turn
       ~tool_calls_made:false
       ~external_delivery_routed:false
     = Masc.Keeper_run_prompt.Meaningful_turn);
  check bool "operator/HITL input with a tool call is meaningful" true
    (decide
       ~user_turn_record:Masc.Keeper_run_prompt.Record_user_turn
       ~tool_calls_made:true
       ~external_delivery_routed:true
     = Masc.Keeper_run_prompt.Meaningful_turn)

let post_id_exn s =
  match Masc.Board.Post_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.fail (Printf.sprintf "invalid post_id fixture: %s" s)

let agent_id_exn s =
  match Masc.Board.Agent_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.fail (Printf.sprintf "invalid agent_id fixture: %s" s)

let sample_own_post : Masc.Board.post =
  { id = post_id_exn "own-post-1"
  ; author = agent_id_exn "test-keeper"
  ; title = "My earlier review"
  ; body = "Already said this exact thing."
  ; content = "Already said this exact thing."
  ; post_kind = Masc.Board.Human_post
  ; meta_json = None
  ; visibility = Masc.Board.Public
  ; created_at = 1_753_300_000.0
  ; updated_at = 1_753_300_100.0
  ; expires_at = 1_753_400_000.0
  ; votes_up = 0
  ; votes_down = 0
  ; reply_count = 0
  ; pinned = false
  ; hearth = None
  ; thread_id = None
  ; origin = None
  }

let test_own_recent_board_posts_render_in_world_state () =
  let obs = { base_observation with own_recent_board_posts = [ sample_own_post ] } in
  let { Masc.Keeper_unified_prompt.world_state; _ } =
    build_prompt ~meta:minimal_meta obs
  in
  check bool "own posts section present" true
    (contains_sub "### Your Recent Board Posts (1)" world_state);
  check bool "own post id rendered for board get follow-up" true
    (contains_sub "own-post-1" world_state);
  check bool "own post title rendered" true
    (contains_sub "My earlier review" world_state)

let test_no_own_recent_board_posts_renders_no_section () =
  let { Masc.Keeper_unified_prompt.world_state; _ } =
    build_prompt ~meta:minimal_meta base_observation
  in
  check bool "own posts section absent when empty" false
    (contains_sub "Your Recent Board Posts" world_state)

let () =
  run "keeper_unified_verification_surface"
    [
      ( "verification_surface",
        [
          test_case "affordance: no keeper is offered task_verify" `Quick
            test_no_task_verify_affordance_for_any_keeper;
          test_case "affordance: Board activity exposes curation without threshold"
            `Quick test_board_activity_exposes_curation_affordance_without_threshold;
          test_case "affordance: no Board activity has no curation affordance" `Quick
            test_no_board_activity_has_no_curation_affordance;
          test_case
            "prompt: all Board authors share one neutral observation boundary"
            `Quick test_board_authors_share_one_neutral_observation_boundary;
          test_case
            "prompt: board reaction event renders reaction context"
            `Quick test_board_reaction_event_renders_reaction_context;
          test_case
            "prompt: observation tool names remain immutable"
            `Quick test_observation_tool_names_are_preserved;
          test_case "affordance: task claim requires matched backlog" `Quick
            test_task_claim_requires_matched_backlog;
          test_case "affordance: task claim present for claimable backlog" `Quick
            test_task_claim_present_for_claimable_backlog;
          test_case "trigger: absolute and matched backlog split" `Quick
            test_backlog_trigger_split;
          test_case "trigger: unclaimable backlog is not claimable work" `Quick
            test_unclaimable_backlog_is_not_a_claim_trigger;
          test_case "trigger: no keeper wakes on pending_verification" `Quick
            test_no_pending_verification_trigger_for_any_keeper;
          test_case
            "trigger: scheduled automation attention is observable"
            `Quick test_scheduled_automation_triggers_and_affordances;
          test_case
            "prompt: scheduled automation section renders attention items"
            `Quick test_scheduled_automation_prompt_section;
          test_case
            "prompt: scheduled wake is not rendered as board activity"
            `Quick test_scheduled_wake_is_not_rendered_as_board_activity;
          test_case
            "prompt: scheduled wake preserves complete message"
            `Quick test_scheduled_wake_preserves_complete_message;
          test_case
            "prompt: completion authority rejection has its own layer"
            `Quick test_completion_authority_rejection_has_own_prompt_layer;
          test_case
            "prompt: completion authority rejection preserves human provenance"
            `Quick test_completion_authority_rejection_preserves_human_provenance;
          test_case
            "prompt: own recent board posts render as neutral observation rows"
            `Quick test_own_recent_board_posts_render_in_world_state;
          test_case
            "prompt: no own recent board posts renders no section"
            `Quick test_no_own_recent_board_posts_renders_no_section;
          test_case
            "invariant: world-state frame never enters the persisted user message"
            `Quick test_world_state_never_in_persisted_user_message;
          test_case
            "invariant: a bare autonomous wake is not recorded in the transcript"
            `Quick test_bare_autonomous_wake_is_not_recorded;
          test_case
            "invariant: one turn-effect record owns replay and librarian"
            `Quick test_turn_effect_record;
        ] );
    ]
