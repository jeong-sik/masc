(** Tests for Keeper_routine_allowlist — narrow auto-approval for keeper
    task lifecycle. *)

module RA = Masc_mcp.Keeper_routine_allowlist
module RL = Masc_mcp.Keeper_approval_queue

let transition_input action =
  `Assoc [ ("action", `String action); ("task_id", `String "task-1") ]

(* ── matches: masc_transition routine actions ──────────────── *)

let test_transition_claim_matches () =
  let input = transition_input "claim" in
  Alcotest.(check bool) "claim matches"
    true
    (RA.matches ~tool_name:"masc_transition" ~input ~risk_level:RL.Medium)

let test_transition_start_matches () =
  let input = transition_input "start" in
  Alcotest.(check bool) "start matches"
    true
    (RA.matches ~tool_name:"masc_transition" ~input ~risk_level:RL.Medium)

let test_transition_heartbeat_matches () =
  let input = transition_input "heartbeat" in
  Alcotest.(check bool) "heartbeat matches"
    true
    (RA.matches ~tool_name:"masc_transition" ~input ~risk_level:RL.Low)

let test_transition_done_matches () =
  let input = transition_input "done" in
  Alcotest.(check bool) "done matches"
    true
    (RA.matches ~tool_name:"masc_transition" ~input ~risk_level:RL.Low)

let test_transition_release_matches () =
  let input = transition_input "release" in
  Alcotest.(check bool) "release matches"
    true
    (RA.matches ~tool_name:"masc_transition" ~input ~risk_level:RL.Low)

(* ── matches: NOT allowlisted (still gated) ─────────────────── *)

let test_transition_cancel_not_matched () =
  let input = transition_input "cancel" in
  Alcotest.(check bool) "cancel does not match (gated)"
    false
    (RA.matches ~tool_name:"masc_transition" ~input ~risk_level:RL.Medium)

let test_transition_force_release_not_matched () =
  let input = transition_input "force_release" in
  Alcotest.(check bool) "force_release does not match"
    false
    (RA.matches ~tool_name:"masc_transition" ~input
       ~risk_level:RL.Critical)

let test_transition_force_done_not_matched () =
  let input = transition_input "force_done" in
  Alcotest.(check bool) "force_done does not match"
    false
    (RA.matches ~tool_name:"masc_transition" ~input
       ~risk_level:RL.Critical)

let test_transition_unknown_action_not_matched () =
  let input = transition_input "wibble" in
  Alcotest.(check bool) "unknown action does not match"
    false
    (RA.matches ~tool_name:"masc_transition" ~input ~risk_level:RL.Medium)

let test_transition_missing_action_not_matched () =
  let input = `Assoc [ ("task_id", `String "t-1") ] in
  Alcotest.(check bool) "missing action does not match"
    false
    (RA.matches ~tool_name:"masc_transition" ~input ~risk_level:RL.Low)

let test_case_insensitive_action () =
  let input = `Assoc [ ("action", `String "CLAIM") ] in
  Alcotest.(check bool) "uppercase CLAIM matches (lowercased)"
    true
    (RA.matches ~tool_name:"masc_transition" ~input ~risk_level:RL.Medium)

(* ── matches: keeper_board_post risk ceiling ────────────────── *)

let test_board_post_low_matches () =
  Alcotest.(check bool) "board_post Low matches"
    true
    (RA.matches ~tool_name:"keeper_board_post"
       ~input:(`Assoc [ ("body", `String "status update") ])
       ~risk_level:RL.Low)

let test_board_post_medium_matches () =
  Alcotest.(check bool) "board_post Medium matches"
    true
    (RA.matches ~tool_name:"keeper_board_post"
       ~input:(`Assoc [ ("body", `String "status update") ])
       ~risk_level:RL.Medium)

let test_board_post_high_does_not_match () =
  Alcotest.(check bool) "board_post High exceeds max_risk"
    false
    (RA.matches ~tool_name:"keeper_board_post"
       ~input:(`Assoc [ ("body", `String "alert") ])
       ~risk_level:RL.High)

let test_board_post_critical_does_not_match () =
  Alcotest.(check bool) "board_post Critical exceeds max_risk"
    false
    (RA.matches ~tool_name:"keeper_board_post"
       ~input:(`Assoc [])
       ~risk_level:RL.Critical)

(* ── matches: keeper task tool surface ──────────────────────── *)

let test_keeper_task_claim_matches () =
  Alcotest.(check bool) "keeper_task_claim matches"
    true
    (RA.matches ~tool_name:"keeper_task_claim"
       ~input:(`Assoc [ ("task_id", `String "t-1") ])
       ~risk_level:RL.Medium)

let test_keeper_task_done_matches () =
  Alcotest.(check bool) "keeper_task_done matches"
    true
    (RA.matches ~tool_name:"keeper_task_done"
       ~input:(`Assoc [])
       ~risk_level:RL.Medium)

let test_keeper_task_submit_for_verification_matches () =
  Alcotest.(check bool) "keeper_task_submit_for_verification matches"
    true
    (RA.matches ~tool_name:"keeper_task_submit_for_verification"
       ~input:(`Assoc [])
       ~risk_level:RL.Low)

(* ── matches: unrelated tools never match ──────────────────── *)

let test_keeper_shell_arbitrary_action_does_not_match () =
  (* The keeper_shell rule is intentionally narrow — only op=git_clone
     auto-approves.  A bare action="ls" (no op key) must NOT match. *)
  Alcotest.(check bool) "keeper_shell action=ls is not auto-approved"
    false
    (RA.matches ~tool_name:"keeper_shell"
       ~input:(`Assoc [ ("action", `String "ls") ])
       ~risk_level:RL.Low)

let test_keeper_shell_git_clone_matches () =
  (* PR-E (Plan v3 Leak 3): keeper_shell op=git_clone is the canonical
     keeper bootstrap action and must auto-approve at Medium risk. *)
  Alcotest.(check bool) "keeper_shell op=git_clone is auto-approved"
    true
    (RA.matches ~tool_name:"keeper_shell"
       ~input:(`Assoc [ ("op", `String "git_clone") ])
       ~risk_level:RL.Medium)

let test_keeper_shell_force_op_does_not_match () =
  (* allowed_actions=[git_clone] — anything else (including dangerous
     ops like force_push, sh, exec) must still go through operator
     approval. *)
  Alcotest.(check bool) "keeper_shell op=force_push is NOT auto-approved"
    false
    (RA.matches ~tool_name:"keeper_shell"
       ~input:(`Assoc [ ("op", `String "force_push") ])
       ~risk_level:RL.Medium)

let test_keeper_shell_op_takes_precedence_over_action () =
  (* Shell semantics come from [op].  A stale or spoofed action field
     must not hide a dangerous op and accidentally match git_clone. *)
  Alcotest.(check bool)
    "keeper_shell op=force_push wins over action=git_clone"
    false
    (RA.matches ~tool_name:"keeper_shell"
       ~input:
         (`Assoc
           [
             ("action", `String "git_clone");
             ("op", `String "force_push");
           ])
       ~risk_level:RL.Medium)

let test_keeper_shell_git_clone_above_max_risk_rejected () =
  (* Critical risk overrides routine — even a normally-allowlisted
     op must not auto-approve when risk has been escalated. *)
  Alcotest.(check bool)
    "keeper_shell op=git_clone at Critical does NOT auto-approve"
    false
    (RA.matches ~tool_name:"keeper_shell"
       ~input:(`Assoc [ ("op", `String "git_clone") ])
       ~risk_level:RL.Critical)

let test_keeper_fs_edit_does_not_match () =
  Alcotest.(check bool) "keeper_fs_edit never auto-approved"
    false
    (RA.matches ~tool_name:"keeper_fs_edit"
       ~input:(`Assoc [])
       ~risk_level:RL.Medium)

let test_unknown_tool_does_not_match () =
  Alcotest.(check bool) "unknown tool does not match"
    false
    (RA.matches ~tool_name:"random_tool_xyz"
       ~input:(`Assoc [])
       ~risk_level:RL.Low)

(* ── rule_label observability ──────────────────────────────── *)

let test_rule_label_for_claim () =
  let label =
    RA.rule_label ~tool_name:"masc_transition"
      ~input:(transition_input "claim")
      ~risk_level:RL.Medium
  in
  Alcotest.(check (option string)) "claim has routine label"
    (Some "keeper_routine.masc_transition") label

let test_rule_label_for_cancel_is_none () =
  let label =
    RA.rule_label ~tool_name:"masc_transition"
      ~input:(transition_input "cancel")
      ~risk_level:RL.Medium
  in
  Alcotest.(check (option string)) "cancel has no label" None label

(* ── rules_summary: stable JSON shape for dashboard ─────────── *)

let test_rules_summary_is_list () =
  let summary = RA.rules_summary () in
  match summary with
  | `List entries ->
      Alcotest.(check bool) "summary has at least the 5 expected rules"
        true
        (List.length entries >= 5)
  | _ -> Alcotest.fail "rules_summary should return `List"

let test_rules_summary_includes_masc_transition () =
  let summary = RA.rules_summary () in
  match summary with
  | `List entries ->
      let has_masc_transition =
        List.exists
          (function
            | `Assoc fields ->
                (match List.assoc_opt "tool" fields with
                 | Some (`String "masc_transition") -> true
                 | _ -> false)
            | _ -> false)
          entries
      in
      Alcotest.(check bool) "summary includes masc_transition"
        true has_masc_transition
  | _ -> Alcotest.fail "rules_summary should return `List"

(* ── Runner ───────────────────────────────────────────────── *)

let () =
  Alcotest.run "Keeper_routine_allowlist"
    [
      ( "transition_routine_actions",
        [
          Alcotest.test_case "claim auto-approves" `Quick
            test_transition_claim_matches;
          Alcotest.test_case "start auto-approves" `Quick
            test_transition_start_matches;
          Alcotest.test_case "heartbeat auto-approves" `Quick
            test_transition_heartbeat_matches;
          Alcotest.test_case "done auto-approves" `Quick
            test_transition_done_matches;
          Alcotest.test_case "release auto-approves" `Quick
            test_transition_release_matches;
          Alcotest.test_case "case-insensitive action" `Quick
            test_case_insensitive_action;
        ] );
      ( "transition_gated_actions",
        [
          Alcotest.test_case "cancel still gated" `Quick
            test_transition_cancel_not_matched;
          Alcotest.test_case "force_release still gated" `Quick
            test_transition_force_release_not_matched;
          Alcotest.test_case "force_done still gated" `Quick
            test_transition_force_done_not_matched;
          Alcotest.test_case "unknown action gated" `Quick
            test_transition_unknown_action_not_matched;
          Alcotest.test_case "missing action gated" `Quick
            test_transition_missing_action_not_matched;
        ] );
      ( "board_post_risk_ceiling",
        [
          Alcotest.test_case "Low passes" `Quick
            test_board_post_low_matches;
          Alcotest.test_case "Medium passes" `Quick
            test_board_post_medium_matches;
          Alcotest.test_case "High blocked" `Quick
            test_board_post_high_does_not_match;
          Alcotest.test_case "Critical blocked" `Quick
            test_board_post_critical_does_not_match;
        ] );
      ( "keeper_task_lifecycle",
        [
          Alcotest.test_case "keeper_task_claim" `Quick
            test_keeper_task_claim_matches;
          Alcotest.test_case "keeper_task_done" `Quick
            test_keeper_task_done_matches;
          Alcotest.test_case "keeper_task_submit_for_verification" `Quick
            test_keeper_task_submit_for_verification_matches;
        ] );
      ( "non_routine_tools_never_match",
        [
          Alcotest.test_case "keeper_shell action=ls" `Quick
            test_keeper_shell_arbitrary_action_does_not_match;
          Alcotest.test_case "keeper_fs_edit" `Quick
            test_keeper_fs_edit_does_not_match;
          Alcotest.test_case "unknown tool" `Quick
            test_unknown_tool_does_not_match;
        ] );
      ( "keeper_shell_git_clone_allowlist",
        [
          Alcotest.test_case "op=git_clone matches" `Quick
            test_keeper_shell_git_clone_matches;
          Alcotest.test_case "op=force_push rejected" `Quick
            test_keeper_shell_force_op_does_not_match;
          Alcotest.test_case "op takes precedence over action" `Quick
            test_keeper_shell_op_takes_precedence_over_action;
          Alcotest.test_case "Critical risk overrides routine" `Quick
            test_keeper_shell_git_clone_above_max_risk_rejected;
        ] );
      ( "rule_label",
        [
          Alcotest.test_case "claim has label" `Quick
            test_rule_label_for_claim;
          Alcotest.test_case "cancel has no label" `Quick
            test_rule_label_for_cancel_is_none;
        ] );
      ( "rules_summary",
        [
          Alcotest.test_case "is a list" `Quick test_rules_summary_is_list;
          Alcotest.test_case "includes masc_transition" `Quick
            test_rules_summary_includes_masc_transition;
        ] );
    ]
