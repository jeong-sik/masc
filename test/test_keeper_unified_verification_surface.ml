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
    pending_verification_count = 0;
    scheduled_automation = WO.empty_scheduled_automation_observation;
    backlog_updated_since_last_scheduled_autonomous = false;
    running_keeper_fiber_count = 0;
    connected_surfaces = [];
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
        ; keeper_next_tool = Some "masc_schedule_get"
        ; keeper_next_action =
            "Inspect the schedule if needed and monitor dispatch; do not create a duplicate schedule."
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

let test_task_verify_affordance_for_keeper () =
  let meta = { minimal_meta with mention_targets = [ "analyst" ] } in
  let obs = { base_observation with pending_verification_count = 3 } in
  let affordances = UM.observed_affordances_of_observation ~meta obs in
  check bool "task_verify present for keeper" true
    (List.mem "task_verify" affordances)

let test_task_verify_affordance_for_verifier_tag () =
  let meta = { minimal_meta with mention_targets = [ "verifier" ] } in
  let obs = { base_observation with pending_verification_count = 3 } in
  let affordances = UM.observed_affordances_of_observation ~meta obs in
  check bool "task_verify present for verifier-tagged keeper" true
    (List.mem "task_verify" affordances)

let test_task_verify_affordance_without_meta () =
  let obs = { base_observation with pending_verification_count = 2 } in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "task_verify present without meta" true
    (List.mem "task_verify" affordances)

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
  let _, peer_msg =
    Masc.Keeper_unified_prompt.build_prompt ~meta:minimal_meta ~base_path:"/tmp"
      ~observation:obs_peer ()
  in
  let _, human_msg =
    Masc.Keeper_unified_prompt.build_prompt ~meta:minimal_meta ~base_path:"/tmp"
      ~observation:obs_human ()
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
  let _, user_msg =
    Masc.Keeper_unified_prompt.build_prompt ~meta:minimal_meta ~base_path:"/tmp"
      ~observation:obs ()
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
  let _, user_msg =
    Masc.Keeper_unified_prompt.build_prompt ~meta:minimal_meta ~base_path:"/tmp"
      ~observation:obs ()
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

let test_pending_verification_trigger_for_keeper () =
  let meta = { minimal_meta with mention_targets = [ "scholar" ] } in
  let obs = { base_observation with pending_verification_count = 5 } in
  let triggers = UM.observed_triggers_of_observation ~meta obs in
  check bool "pending_verification present for keeper" true
    (List.mem "pending_verification" triggers)

let test_pending_verification_trigger_for_verifier_tag () =
  let meta = { minimal_meta with mention_targets = [ "검증자" ] } in
  let obs = { base_observation with pending_verification_count = 1 } in
  let triggers = UM.observed_triggers_of_observation ~meta obs in
  check bool "pending_verification present for verifier-tagged keeper" true
    (List.mem "pending_verification" triggers)

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
  let _, user_msg =
    Masc.Keeper_unified_prompt.build_prompt ~meta:minimal_meta ~base_path:"/tmp"
      ~observation:obs ()
  in
  check bool "prompt includes schedule section" true
    (contains_sub "### Scheduled Automation" user_msg);
  check bool "prompt includes ready schedule id" true
    (contains_sub "schedule_id=sched-ready" user_msg);
  check bool "prompt points to schedule detail tool" true
    (contains_sub "masc_schedule_get" user_msg);
  check bool "prompt includes ready next action" true
    (contains_sub "do not create a duplicate schedule" user_msg)

let () =
  run "keeper_unified_verification_surface"
    [
      ( "verification_surface",
        [
          test_case "affordance: keeper sees task_verify when pending>0" `Quick
            test_task_verify_affordance_for_keeper;
          test_case "affordance: verifier-tagged keeper also sees task_verify"
            `Quick test_task_verify_affordance_for_verifier_tag;
          test_case "affordance: no meta keeps legacy surface-to-all" `Quick
            test_task_verify_affordance_without_meta;
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
          test_case "trigger: keeper sees pending_verification" `Quick
            test_pending_verification_trigger_for_keeper;
          test_case
            "trigger: verifier-tagged keeper also sees pending_verification"
            `Quick test_pending_verification_trigger_for_verifier_tag;
          test_case
            "trigger: scheduled automation attention is observable"
            `Quick test_scheduled_automation_triggers_and_affordances;
          test_case
            "prompt: scheduled automation section renders attention items"
            `Quick test_scheduled_automation_prompt_section;
        ] );
    ]
