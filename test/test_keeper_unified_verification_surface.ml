open Alcotest

module WO = Masc.Keeper_world_observation
module UM = Masc.Keeper_unified_metrics

let base_observation : WO.world_observation =
  {
    pending_mentions = [];
    pending_board_events = [];
    pending_scope_messages = [];
    idle_seconds = 0;
    active_goals = [];
    continuity_summary = "";
    context_ratio = lazy 0.0;
    unclaimed_task_count = 0;
    claimable_task_count = 0;
    provider_capacity_blocked_task_count = 0;
    failed_task_count = 0;
    pending_verification_count = 0;
    backlog_updated_since_last_scheduled_autonomous = false;
    running_keeper_fiber_count = 0;
    connected_surfaces = [];
  }

let sample_board_event : WO.pending_board_event =
  {
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
    provenance = WO.Human_direct;
  }

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String ("test-trace-" ^ name));
        ("goal", `String "test goal");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

let minimal_meta : Masc.Keeper_meta_contract.keeper_meta = make_meta "test-keeper"

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

let test_board_curation_affordance_requires_multi_event_window () =
  let second_board_event =
    {
      sample_board_event with
      post_id = "board-post-2";
      title = "Follow-up";
      preview = "Another board item needs routing.";
    }
  in
  let obs =
    {
      base_observation with
      pending_board_events = [ sample_board_event; second_board_event ];
    }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "board_curation present" true
    (List.mem "board_curation" affordances)

let test_single_board_event_skips_curation_gate () =
  let obs =
    { base_observation with pending_board_events = [ sample_board_event ] }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "board_curation absent" false
    (List.mem "board_curation" affordances)

(* RFC-0248 PR-2 behavioral proof: the trust boundary reaches the assembled
   prompt. A fleet-authored board event (peer/self/automation) renders ONLY
   inside the observational-data envelope; a human-authored event renders as
   trusted instruction without it. This closes the test gap left since PR-1,
   whose provenance tests covered classification only, not prompt rendering. *)
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

let test_quarantined_board_event_wraps_in_envelope () =
  Masc_test_deps.init_keeper_tool_registry ();
  let peer_event =
    {
      sample_board_event with
      post_id = "peer-post-1";
      author = "keeper-ramarama-agent";
      preview = "I assert the build is green.";
      provenance = WO.Peer_keeper;
    }
  in
  let human_event =
    { sample_board_event with post_id = "human-1"; provenance = WO.Human_direct }
  in
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
  check bool "peer (fleet) event wrapped in observational-data envelope" true
    (contains_sub "observational-data" peer_msg);
  check bool "human event NOT wrapped in envelope (trusted instruction)" false
    (contains_sub "observational-data" human_msg)
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

let test_task_claim_suppressed_for_provider_blocked_backlog () =
  let obs =
    {
      base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 1;
      provider_capacity_blocked_task_count = 1;
    }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "task_claim absent while provider capacity blocks work" false
    (List.mem "task_claim" affordances);
  check bool "provider capacity affordance present" true
    (List.mem "provider_capacity_blocked" affordances)

let test_backlog_trigger_split () =
  let obs =
    { base_observation with unclaimed_task_count = 3; claimable_task_count = 1 }
  in
  let triggers = UM.observed_triggers_of_observation obs in
  check bool "absolute backlog trigger remains visible" true
    (List.mem "new_unclaimed_task" triggers);
  check bool "matched backlog trigger is explicit" true
    (List.mem "claimable_task" triggers)

let test_provider_capacity_blocked_trigger () =
  let obs =
    {
      base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 1;
      provider_capacity_blocked_task_count = 1;
    }
  in
  let triggers = UM.observed_triggers_of_observation obs in
  check bool "provider capacity trigger is explicit" true
    (List.mem "provider_capacity_blocked_backlog" triggers)

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
          test_case "affordance: board curation requires multi-event window"
            `Quick test_board_curation_affordance_requires_multi_event_window;
          test_case "affordance: single board event skips curation gate" `Quick
            test_single_board_event_skips_curation_gate;
          test_case
            "trust: quarantined board event wraps in envelope (RFC-0248 PR-2)"
            `Quick test_quarantined_board_event_wraps_in_envelope;
          test_case "affordance: task claim requires matched backlog" `Quick
            test_task_claim_requires_matched_backlog;
          test_case "affordance: task claim present for claimable backlog" `Quick
            test_task_claim_present_for_claimable_backlog;
          test_case
            "affordance: provider block suppresses task claim"
            `Quick test_task_claim_suppressed_for_provider_blocked_backlog;
          test_case "trigger: absolute and matched backlog split" `Quick
            test_backlog_trigger_split;
          test_case "trigger: provider capacity blocked backlog" `Quick
            test_provider_capacity_blocked_trigger;
          test_case "trigger: keeper sees pending_verification" `Quick
            test_pending_verification_trigger_for_keeper;
          test_case
            "trigger: verifier-tagged keeper also sees pending_verification"
            `Quick test_pending_verification_trigger_for_verifier_tag;
        ] );
    ]
