open Alcotest

let file_contains_pattern file_rel pattern =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        let rec loop idx =
          let remaining = String.length content - idx in
          let plen = String.length pattern in
          remaining >= plen
          && (String.sub content idx plen = pattern || loop (idx + 1))
        in
        if String.length pattern = 0 then true else loop 0)

let test_lodge_memory_no_agent_activities_query () =
  check bool "agentActivities query removed"
    false (file_contains_pattern "lib/lodge_memory.ml" "agentActivities(")

let test_lodge_memory_no_create_lodge_activity_mutation () =
  check bool "createLodgeActivity mutation removed"
    false (file_contains_pattern "lib/lodge_memory.ml" "createLodgeActivity(")

let test_lodge_heartbeat_no_profile_shellout () =
  check bool "profile shellout removed"
    false
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       {|Process_eio.run_argv ~timeout_sec:30.0 [sb; "graphql"; "agent"; agent_name]|})

let test_lodge_heartbeat_uses_decision_prompt () =
  check bool "structured decision prompt used"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "Lodge_decision.batch_decision_prompt");
  check bool "decision phase traced"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" {|phase:"lodge_decision"|});
  check bool "structured batch parser used"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "Lodge_decision.parse_batch_outcome")

let test_lodge_heartbeat_updates_self_summary () =
  check bool "reflection updates self summary"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "Lodge_reaction.update_self_summary")

let test_lodge_heartbeat_uses_tom_context () =
  check bool "ToM context used"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "Lodge_tom.predict_top_k")

let test_lodge_heartbeat_post_fallback_policy () =
  check bool "scheduled trigger can fallback to post"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "| Scheduled | ManualTrigger -> true");
  check bool "content alerts do not fallback to post"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "| ContentAlert _ | Mentioned _ -> false");
  check bool "batch parse failures become explicit decision error"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       {|reason = "decision error: " ^ reason|});
  check bool "post gating still enforced through allow_post"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       "~allow_post:(trigger_allows_post trigger)")

let test_lodge_heartbeat_hidden_fallbacks_removed () =
  check bool "reaction batch prompt removed"
    false
    (file_contains_pattern "lib/lodge_heartbeat.ml" "Lodge_reaction.batch_reaction_prompt");
  check bool "comment generation no longer auto-upvotes"
    false
    (file_contains_pattern "lib/lodge_heartbeat.ml" {|None -> ActionUpvote|});
  check bool "scheduled fallback helper removed"
    false
    (file_contains_pattern "lib/lodge_heartbeat.ml" "maybe_post_action");
  check bool "legacy NoAction fallback removed"
    false
    (file_contains_pattern "lib/lodge_heartbeat.ml" "NoAction");
  check bool "comment rate limit enforced explicitly"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" {|Skipped "comment_rate_limited"|});
  check bool "post rate limit enforced explicitly"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" {|Skipped "post_rate_limited"|});
  check bool "decision failure reason tracked"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "decision_failure_reason")

let test_lodge_heartbeat_public_memory_helpers_removed () =
  check bool "load_agent_memories removed from mli"
    false
    (file_contains_pattern "lib/lodge_heartbeat.mli" "val load_agent_memories");
  check bool "record_agent_memory removed from mli"
    false
    (file_contains_pattern "lib/lodge_heartbeat.mli" "val record_agent_memory");
  check bool "ActionCode removed from mli"
    false
    (file_contains_pattern "lib/lodge_heartbeat.mli" "ActionCode");
  check bool "ActionPropose removed from mli"
    false
    (file_contains_pattern "lib/lodge_heartbeat.mli" "ActionPropose")

let () =
  run "Lodge heartbeat cleanup coverage"
    [
      ("source", [
          test_case "agentActivities recall removed" `Quick test_lodge_memory_no_agent_activities_query;
          test_case "createLodgeActivity store removed" `Quick test_lodge_memory_no_create_lodge_activity_mutation;
          test_case "profile shellout removed" `Quick test_lodge_heartbeat_no_profile_shellout;
          test_case "decision prompt mainline" `Quick test_lodge_heartbeat_uses_decision_prompt;
          test_case "reflection updates self summary" `Quick test_lodge_heartbeat_updates_self_summary;
          test_case "ToM context used" `Quick test_lodge_heartbeat_uses_tom_context;
          test_case "post fallback policy locked" `Quick test_lodge_heartbeat_post_fallback_policy;
          test_case "hidden fallbacks removed" `Quick test_lodge_heartbeat_hidden_fallbacks_removed;
          test_case "legacy public surface removed" `Quick test_lodge_heartbeat_public_memory_helpers_removed;
        ]);
    ]
