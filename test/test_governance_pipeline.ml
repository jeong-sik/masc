(** Tests for Governance_pipeline — risk assessment and governance level policies. *)

module Gp = Masc.Governance_pipeline
module Workspace = Masc.Workspace
module Tool_dispatch = Tool_dispatch
module Tool_result = Tool_result

let explicit_claim_tool = "keeper_task_claim"
let generic_transition_tool = "masc_transition"
let transition_claim_input = `Assoc [("action", `String "claim")]
let transition_start_input = `Assoc [("action", `String "start")]
let transition_done_input = `Assoc [("action", `String "done"); ("notes", `String "Completed task implementation and verified correctness")]
let goal_transition_request_complete_input =
  `Assoc [("action", `String "request_complete")]

let goal_transition_drop_input = `Assoc [("action", `String "drop")]
let goal_transition_operator_block_input = `Assoc [("action", `String "operator_block")]
let no_args = `Null

let tool_ok ?(tool_name = "") message =
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String message) ()
;;

(* ── Helpers ────────────────────────────────────────────────── *)

let make_tmpdir () =
  let tmpdir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-gov-test-%d-%d"
       (Unix.getpid ()) (Random.bits ())) in
  Unix.mkdir tmpdir 0o755;
  tmpdir

let cleanup_tmpdir dir =
  (* Best-effort cleanup of .masc/ subdirectory and tmpdir itself *)
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name))
        (Sys.readdir path);
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
    end else
      (try Sys.remove path with Sys_error _ -> ())
  in
  rm_rf dir

(* ── Risk Assessment Tests ──────────────────────────────────── *)

let test_risk_critical_delete () =
  let risk = Gp.assess_risk ~tool_name:"masc_delete_workspace" ~input:no_args in
  Alcotest.(check string) "delete is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_critical_force () =
  let risk = Gp.assess_risk ~tool_name:"masc_force_push" ~input:no_args in
  Alcotest.(check string) "force is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_critical_drop () =
  let risk = Gp.assess_risk ~tool_name:"masc_drop_task" ~input:no_args in
  Alcotest.(check string) "drop is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_critical_kill () =
  let risk = Gp.assess_risk ~tool_name:"masc_kill_session" ~input:no_args in
  Alcotest.(check string) "kill is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_critical_reset () =
  let risk = Gp.assess_risk ~tool_name:"masc_reset_state" ~input:no_args in
  Alcotest.(check string) "reset is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_critical_remove () =
  let risk = Gp.assess_risk ~tool_name:"masc_remove_agent" ~input:no_args in
  Alcotest.(check string) "remove is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_critical_destroy () =
  let risk = Gp.assess_risk ~tool_name:"masc_destroy_workspace" ~input:no_args in
  Alcotest.(check string) "destroy is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_critical_purge () =
  let risk = Gp.assess_risk ~tool_name:"masc_purge_logs" ~input:no_args in
  Alcotest.(check string) "purge is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_high_create () =
  let risk = Gp.assess_risk ~tool_name:"masc_create_workspace" ~input:no_args in
  Alcotest.(check string) "create is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_high_update () =
  let risk = Gp.assess_risk ~tool_name:"masc_update_task" ~input:no_args in
  Alcotest.(check string) "update is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_high_deploy () =
  let risk = Gp.assess_risk ~tool_name:"masc_deploy_worker" ~input:no_args in
  Alcotest.(check string) "deploy is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_high_push () =
  let risk = Gp.assess_risk ~tool_name:"masc_push_config" ~input:no_args in
  Alcotest.(check string) "push is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_high_merge () =
  let risk = Gp.assess_risk ~tool_name:"masc_merge_branch" ~input:no_args in
  Alcotest.(check string) "merge is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_high_send () =
  let risk = Gp.assess_risk ~tool_name:"masc_send_message" ~input:no_args in
  Alcotest.(check string) "send is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_high_spawn () =
  let risk = Gp.assess_risk ~tool_name:"masc_spawn_worker" ~input:no_args in
  Alcotest.(check string) "spawn is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_medium_claim_next () =
  let risk = Gp.assess_risk ~tool_name:explicit_claim_tool ~input:no_args in
  Alcotest.(check string) "claim_next is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_medium_transition_claim () =
  let risk =
    Gp.assess_risk ~tool_name:generic_transition_tool ~input:transition_claim_input
  in
  Alcotest.(check string) "transition claim is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_medium_join () =
  let risk = Gp.assess_risk ~tool_name:"masc_bind" ~input:no_args in
  Alcotest.(check string) "join is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_medium_leave () =
  let risk = Gp.assess_risk ~tool_name:"masc_unbind" ~input:no_args in
  Alcotest.(check string) "leave is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_medium_start () =
  let risk = Gp.assess_risk ~tool_name:"masc_start_session" ~input:no_args in
  Alcotest.(check string) "start is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_medium_stop () =
  let risk = Gp.assess_risk ~tool_name:"masc_stop_session" ~input:no_args in
  Alcotest.(check string) "stop is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_medium_pause () =
  let risk = Gp.assess_risk ~tool_name:"masc_pause_workspace" ~input:no_args in
  Alcotest.(check string) "pause is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_medium_resume () =
  let risk = Gp.assess_risk ~tool_name:"masc_resume_workspace" ~input:no_args in
  Alcotest.(check string) "resume is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_low_status () =
  let risk = Gp.assess_risk ~tool_name:"masc_status" ~input:no_args in
  Alcotest.(check string) "status is low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_low_list () =
  let risk = Gp.assess_risk ~tool_name:"masc_tasks" ~input:no_args in
  Alcotest.(check string) "list is low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_low_query () =
  let risk = Gp.assess_risk ~tool_name:"masc_query_agents" ~input:no_args in
  Alcotest.(check string) "query is low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_low_transition () =
  let risk = Gp.assess_risk ~tool_name:generic_transition_tool ~input:no_args in
  Alcotest.(check string) "transition without action is low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_low_transition_done () =
  let risk =
    Gp.assess_risk ~tool_name:generic_transition_tool ~input:transition_done_input
  in
  Alcotest.(check string) "transition done is low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_medium_goal_upsert () =
  let risk = Gp.assess_risk ~tool_name:"masc_goal_upsert" ~input:no_args in
  Alcotest.(check string) "goal_upsert is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_medium_goal_transition_request_complete () =
  let risk =
    Gp.assess_risk
      ~tool_name:"masc_goal_transition"
      ~input:goal_transition_request_complete_input
  in
  Alcotest.(check string) "goal_transition request_complete is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_high_goal_transition_missing_action () =
  let risk = Gp.assess_risk ~tool_name:"masc_goal_transition" ~input:no_args in
  Alcotest.(check string) "goal_transition without action is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_high_goal_transition_drop () =
  let risk =
    Gp.assess_risk
      ~tool_name:"masc_goal_transition"
      ~input:goal_transition_drop_input
  in
  Alcotest.(check string) "goal_transition drop is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_high_goal_transition_operator_block () =
  let risk =
    Gp.assess_risk
      ~tool_name:"masc_goal_transition"
      ~input:goal_transition_operator_block_input
  in
  Alcotest.(check string) "goal_transition operator_block is high"
    "high" (Gp.risk_level_to_string risk)

let test_risk_medium_goal_verify () =
  let risk = Gp.assess_risk ~tool_name:"masc_goal_verify" ~input:no_args in
  Alcotest.(check string) "goal_verify is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_low_keeper_msg () =
  let risk = Gp.assess_risk ~tool_name:"masc_keeper_msg" ~input:no_args in
  Alcotest.(check string) "keeper_msg is low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_critical_tool_execute_default () =
  let risk = Gp.assess_risk ~tool_name:"tool_execute" ~input:no_args in
  Alcotest.(check string) "tool_execute defaults to critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_medium_keeper_task_create () =
  let risk = Gp.assess_risk ~tool_name:"keeper_task_create" ~input:no_args in
  Alcotest.(check string) "keeper_task_create is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_low_keeper_memory_write () =
  let risk = Gp.assess_risk ~tool_name:"keeper_memory_write" ~input:no_args in
  Alcotest.(check string) "keeper_memory_write is low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_medium_transition_start () =
  let risk =
    Gp.assess_risk ~tool_name:generic_transition_tool ~input:transition_start_input
  in
  Alcotest.(check string) "transition start is medium"
    "medium" (Gp.risk_level_to_string risk)

(* ── PR-J: payload severity discrimination ──────────────────── *)
(* Background: pre-PR-J, [classify_with_payload] used a single
   [Eval_gate.detect_destructive] check that conflated canonical
   destructive substrings (rm -rf, drop table) with evasion-only
   indicators (command substitution `$(...)`, hex escapes).  Every
   tool_execute payload that used [$(date ...)] tripped the evasion
   regex and was escalated to Critical, blocking benign helpers like
   `echo "ts: $(date)" && pwd` (see masc-improver evidence
   2026-04-25T18:33Z).  These regression tests pin the new behavior:
   - destructive substring → Critical
   - evasion-only meta-pattern → Medium (not Critical)
   - clean payload → fall back to tool-name baseline *)

let test_risk_payload_destructive_rm_rf () =
  let input = `Assoc [ ("cmd", `String "rm -rf /tmp/x") ] in
  let risk = Gp.assess_risk ~tool_name:"tool_execute" ~input in
  Alcotest.(check string) "rm -rf payload remains critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_payload_evasion_only_command_substitution () =
  let input =
    `Assoc
      [
        ("cmd", `String "echo \"ts: $(date -u +%FT%TZ)\" && pwd");
      ]
  in
  let risk = Gp.assess_risk ~tool_name:"tool_execute" ~input in
  Alcotest.(check string)
    "command-substitution evasion alone is medium, not critical"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_payload_evasion_only_hex_escape () =
  let input = `Assoc [ ("cmd", `String "printf '\\x72\\x6d'") ] in
  let risk = Gp.assess_risk ~tool_name:"tool_execute" ~input in
  Alcotest.(check string) "hex escape evasion alone is medium"
    "medium" (Gp.risk_level_to_string risk)

let test_risk_payload_destructive_inside_substitution () =
  (* Even though `$(...)` triggers evasion, the inner `rm -rf` substring
     remains visible to detect_destructive after normalize_command, so
     the result must still escalate to Critical. *)
  let input = `Assoc [ ("cmd", `String "echo $(rm -rf /)") ] in
  let risk = Gp.assess_risk ~tool_name:"tool_execute" ~input in
  Alcotest.(check string) "destructive inside $(...) stays critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_low_unknown () =
  let risk = Gp.assess_risk ~tool_name:"masc_foobar" ~input:no_args in
  Alcotest.(check string) "unknown is low"
    "low" (Gp.risk_level_to_string risk)

(* Critical > High precedence: "force_create" has both "force" (Critical)
   and "create" (High). Critical patterns are checked first. *)
let test_risk_precedence_critical_over_high () =
  let risk = Gp.assess_risk ~tool_name:"masc_force_create" ~input:no_args in
  Alcotest.(check string) "force_create is critical (force wins)"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_metadata_admin_cleanup_override () =
  (* masc_admin_cleanup removed in RFC-0182; assess_risk for unknown tool
     defaults to low. *)
  let risk = Gp.assess_risk ~tool_name:"masc_admin_cleanup" ~input:no_args in
  Alcotest.(check string) "admin_cleanup unknown defaults to low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_metadata_pg_query_override () =
  (* masc_pg_query removed — no handler, no catalog metadata.
     assess_risk for unknown tool defaults to low. *)
  let risk = Gp.assess_risk ~tool_name:"masc_pg_query" ~input:no_args in
  Alcotest.(check string) "pg_query (removed) defaults to low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_payload_empty_overwrite () =
  let risk =
    Gp.assess_risk ~tool_name:"tool_write_file"
      ~input:
        (`Assoc
          [
            ("path", `String ".worktrees/agent-task/demo.txt");
            ("content", `String "");
          ])
  in
  Alcotest.(check string) "empty overwrite payload is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_payload_destructive_content () =
  let risk =
    Gp.assess_risk ~tool_name:"tool_edit_file"
      ~input:
        (`Assoc
          [
            ("path", `String ".worktrees/agent-task/demo.sql");
            ("old_string", `String "SELECT 1;");
            ("new_string", `String "DROP TABLE production_users");
          ])
  in
  Alcotest.(check string) "destructive payload content is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_payload_destructive_nested_string () =
  let risk =
    Gp.assess_risk ~tool_name:"masc_status"
      ~input:
        (`Assoc
          [
            ( "payload",
              `Assoc
                [
                  ("note", `String "DROP TABLE production_users");
                ] );
          ])
  in
  Alcotest.(check string) "nested destructive payload is critical"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_payload_safe_write_inherits_destructive_metadata () =
  let risk =
    Gp.assess_risk ~tool_name:"tool_write_file"
      ~input:
        (`Assoc
          [
            ("path", `String ".worktrees/agent-task/demo.ml");
            ("content", `String "let answer = 42\n");
          ])
  in
  Alcotest.(check string) "safe write inherits destructive metadata"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_payload_safe_nested_string_remains_low () =
  let risk =
    Gp.assess_risk ~tool_name:"masc_status"
      ~input:
        (`Assoc
          [
            ( "payload",
              `Assoc
                [
                  ("note", `String "temporary scratch directory");
                ] );
          ])
  in
  Alcotest.(check string) "safe nested payload stays low"
    "low" (Gp.risk_level_to_string risk)

let test_risk_contract_risk_from_delivery_contract () =
  let risk =
    Gp.assess_risk ~tool_name:"masc_operator_action"
      ~input:
        (`Assoc
          [
            ( "delivery_contract",
              `Assoc
                [
                  ("contract_id", `String "contract-risk-001");
                  ("summary", `String "high risk execution");
                  ( "required_artifacts",
                    `List
                      [
                        `String "a";
                        `String "b";
                        `String "c";
                        `String "d";
                        `String "e";
                      ] );
                  ("repair_budget", `Int 0);
                ] );
            ("tool_names", `List [ `String "tool_execute"; `String "tool_search_files" ]);
          ])
  in
  Alcotest.(check string) "delivery contract drives critical risk"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_invalid_delivery_contract_falls_back_to_heuristic () =
  let risk =
    Gp.assess_risk ~tool_name:"masc_create_workspace"
      ~input:
        (`Assoc
          [
            ( "delivery_contract",
              `Assoc
                [
                  ("summary", `String "missing contract id");
                  ("repair_budget", `Int 0);
                ] );
            ("tool_names", `List [ `Int 1 ]);
          ])
  in
  Alcotest.(check string) "invalid contract falls back to heuristic"
    "high" (Gp.risk_level_to_string risk)

let test_risk_contract_risk_non_object_input_falls_back_to_heuristic () =
  let risk =
    Gp.assess_risk ~tool_name:"masc_create_workspace"
      ~input:(`List [ `String "delivery_contract"; `String "ignored" ])
  in
  Alcotest.(check string) "non-object input keeps heuristic risk"
    "high" (Gp.risk_level_to_string risk)

let test_risk_contract_risk_does_not_downgrade_heuristic () =
  let risk =
    Gp.assess_risk ~tool_name:"masc_create_workspace"
      ~input:
        (`Assoc
          [
            ( "delivery_contract",
              `Assoc
                [
                  ("contract_id", `String "contract-risk-004");
                  ("summary", `String "benign contract");
                  ("required_artifacts", `List [ `String "report.md" ]);
                  ("repair_budget", `Int 5);
                ] );
          ])
  in
  Alcotest.(check string) "contract risk cannot downgrade high heuristic"
    "high" (Gp.risk_level_to_string risk)

let test_risk_payload_beats_contract_risk () =
  let risk =
    Gp.assess_risk ~tool_name:"masc_operator_action"
      ~input:
        (`Assoc
          [
            ( "delivery_contract",
              `Assoc
                [
                  ("contract_id", `String "contract-risk-005");
                  ("summary", `String "medium contract");
                  ( "required_artifacts",
                    `List [ `String "report.md"; `String "test.xml" ] );
                  ("repair_budget", `Int 3);
                ] );
            ("tool_names", `List [ `String "tool_edit_file" ]);
            ("note", `String "rm -rf /tmp/demo");
          ])
  in
  Alcotest.(check string) "payload risk beats contract risk"
    "critical" (Gp.risk_level_to_string risk)

let test_risk_payload_beats_low_override () =
  let risk =
    Gp.assess_risk ~tool_name:"masc_a2a_query_skill"
      ~input:(`Assoc [ ("note", `String "rm -rf /tmp/demo") ])
  in
  Alcotest.(check string) "payload risk beats low override"
    "critical" (Gp.risk_level_to_string risk)

(* test_risk_contract_beats_low_override removed:
   Contract_risk module was deleted — classify_with_contract_risk always
   returns None, so contract risk can no longer escalate past the
   baseline heuristic. *)

(* ── Governance Level Decision Tests ────────────────────────── *)

let test_development_confirms_critical () =
  (* Hard-forbidden gate is unconditional: even development must confirm
     Critical-risk tools rather than allowing silent auto-approval. *)
  let d = Gp.decide ~governance_level:"development"
    ~tool_name:"masc_delete_workspace" ~input:`Null in
  (match d.action with
   | `Require_confirm _ -> ()
   | `Allow -> Alcotest.fail "development should require confirm for critical"
   | `Deny _ -> Alcotest.fail "development should require confirm, not deny");
  Alcotest.(check string) "risk" "critical" (Gp.risk_level_to_string d.risk)

let test_development_allows_low () =
  let d = Gp.decide ~governance_level:"development"
    ~tool_name:"masc_status" ~input:`Null in
  (match d.action with
   | `Allow -> ()
   | _ -> Alcotest.fail "development should allow low")

let test_production_allows_low () =
  let d = Gp.decide ~governance_level:"production"
    ~tool_name:"masc_status" ~input:`Null in
  (match d.action with
   | `Allow -> ()
   | _ -> Alcotest.fail "production should allow low")

let test_production_allows_medium () =
  let d = Gp.decide ~governance_level:"production"
    ~tool_name:"masc_bind" ~input:`Null in
  (match d.action with
   | `Allow -> ()
   | _ -> Alcotest.fail "production should allow medium")

let test_production_allows_high () =
  let d = Gp.decide ~governance_level:"production"
    ~tool_name:"masc_create_workspace" ~input:`Null in
  (match d.action with
   | `Allow -> ()
   | _ -> Alcotest.fail "production should allow high")

let test_production_confirms_critical () =
  let d = Gp.decide ~governance_level:"production"
    ~tool_name:"masc_delete_workspace" ~input:`Null in
  (match d.action with
   | `Require_confirm reason ->
       Alcotest.(check bool) "reason non-empty"
         true (String.length reason > 0)
   | `Allow -> Alcotest.fail "production should require confirm for critical"
   | `Deny _ -> Alcotest.fail "production should require confirm, not deny")

let test_enterprise_allows_low () =
  let d = Gp.decide ~governance_level:"enterprise"
    ~tool_name:"masc_status" ~input:`Null in
  (match d.action with
   | `Allow -> ()
   | _ -> Alcotest.fail "enterprise should allow low")

let test_enterprise_allows_medium () =
  let d = Gp.decide ~governance_level:"enterprise"
    ~tool_name:"masc_bind" ~input:`Null in
  (match d.action with
   | `Allow -> ()
   | _ -> Alcotest.fail "enterprise should allow medium")

let test_enterprise_confirms_high () =
  let d = Gp.decide ~governance_level:"enterprise"
    ~tool_name:"masc_create_workspace" ~input:`Null in
  (match d.action with
   | `Require_confirm _ -> ()
   | `Allow -> Alcotest.fail "enterprise should require confirm for high"
   | `Deny _ -> Alcotest.fail "enterprise should require confirm, not deny")

let test_enterprise_confirms_critical () =
  let d = Gp.decide ~governance_level:"enterprise"
    ~tool_name:"masc_delete_workspace" ~input:`Null in
  (match d.action with
   | `Require_confirm _ -> ()
   | `Allow -> Alcotest.fail "enterprise should require confirm for critical"
   | `Deny _ -> Alcotest.fail "enterprise should require confirm, not deny")

let test_paranoid_allows_low () =
  let d = Gp.decide ~governance_level:"paranoid"
    ~tool_name:"masc_status" ~input:`Null in
  (match d.action with
   | `Allow -> ()
   | _ -> Alcotest.fail "paranoid should allow low")

let test_paranoid_confirms_medium () =
  let d = Gp.decide ~governance_level:"paranoid"
    ~tool_name:"masc_bind" ~input:`Null in
  (match d.action with
   | `Require_confirm _ -> ()
   | `Allow -> Alcotest.fail "paranoid should require confirm for medium"
   | `Deny _ -> Alcotest.fail "paranoid should require confirm, not deny")

let test_paranoid_confirms_high () =
  let d = Gp.decide ~governance_level:"paranoid"
    ~tool_name:"masc_create_workspace" ~input:`Null in
  (match d.action with
   | `Require_confirm _ -> ()
   | `Allow -> Alcotest.fail "paranoid should require confirm for high"
   | `Deny _ -> Alcotest.fail "paranoid should require confirm, not deny")

let test_paranoid_confirms_critical () =
  let d = Gp.decide ~governance_level:"paranoid"
    ~tool_name:"masc_delete_workspace" ~input:`Null in
  (match d.action with
   | `Require_confirm _ -> ()
   | `Allow -> Alcotest.fail "paranoid should require confirm for critical"
   | `Deny _ -> Alcotest.fail "paranoid should require confirm, not deny")

(* ── Trace ID Tests ─────────────────────────────────────────── *)

let test_decision_has_trace_id () =
  let d = Gp.decide ~governance_level:"development"
    ~tool_name:"masc_status" ~input:`Null in
  Alcotest.(check bool) "trace_id starts with gov_"
    true (String.length d.trace_id > 4
          && String.sub d.trace_id 0 4 = "gov_")

let test_trace_ids_unique () =
  let d1 = Gp.decide ~governance_level:"development"
    ~tool_name:"masc_status" ~input:`Null in
  let d2 = Gp.decide ~governance_level:"development"
    ~tool_name:"masc_status" ~input:`Null in
  Alcotest.(check bool) "trace_ids differ"
    true (d1.trace_id <> d2.trace_id)

(* ── Pre-Hook Integration Tests ─────────────────────────────── *)

(* Pre-hook tests need Eio context because Audit_log uses Eio.Mutex internally
   via Dated_jsonl. Wrap each test in Eio_main.run. *)

let setup () =
  Tool_dispatch.clear_hooks ()

let test_hook_development_blocks_critical () =
  (* The front-door pre_hook uses decide without keeper meta, but the
     unconditional hard-forbidden gate still blocks Critical risk. *)
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  setup ();
  Tool_dispatch.register
    ~tool_name:"__gov_test_delete"
    ~handler:(fun ~name:_ ~args:_ -> Some (tool_ok "ok"));
  let tmpdir = make_tmpdir () in
  let config = Workspace.default_config tmpdir in
  let hook = Gp.make_pre_hook ~config ~governance_level:"development" in
  let result = hook ~name:"__gov_test_delete" ~args:`Null in
  (match result with
   | Tool_dispatch.Reject r ->
       Alcotest.(check bool) "blocked" false (Tool_result.is_success r);
       let status = Yojson.Safe.Util.((Tool_result.data r) |> member "status" |> to_string) in
       Alcotest.(check string) "awaiting_approval" "awaiting_approval" status
   | _ -> Alcotest.fail "development should block critical tool");
  cleanup_tmpdir tmpdir

let test_hook_production_blocks_critical () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  setup ();
  Tool_dispatch.register
    ~tool_name:"__gov_test_delete2"
    ~handler:(fun ~name:_ ~args:_ -> Some (tool_ok "should not reach"));
  let tmpdir = make_tmpdir () in
  let config = Workspace.default_config tmpdir in
  let hook = Gp.make_pre_hook ~config ~governance_level:"production" in
  let result = hook ~name:"__gov_test_delete2" ~args:`Null in
  (match result with
   | Tool_dispatch.Reject r ->
       Alcotest.(check bool) "blocked" false (Tool_result.is_success r);
       let status = Yojson.Safe.Util.((Tool_result.data r) |> member "status" |> to_string) in
       Alcotest.(check string) "awaiting_approval" "awaiting_approval" status;
       let trace = Yojson.Safe.Util.((Tool_result.data r) |> member "trace_id" |> to_string) in
       Alcotest.(check bool) "has trace_id" true (String.length trace > 0)
   | _ -> Alcotest.fail "production should block critical tool");
  cleanup_tmpdir tmpdir

let test_hook_production_allows_low () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  setup ();
  let tmpdir = make_tmpdir () in
  let config = Workspace.default_config tmpdir in
  let hook = Gp.make_pre_hook ~config ~governance_level:"production" in
  let result = hook ~name:"masc_status" ~args:`Null in
  (match result with
   | Tool_dispatch.Pass -> ()
   | _ -> Alcotest.fail "production should allow low risk");
  cleanup_tmpdir tmpdir

let test_hook_enterprise_blocks_high () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  setup ();
  let tmpdir = make_tmpdir () in
  let config = Workspace.default_config tmpdir in
  let hook = Gp.make_pre_hook ~config ~governance_level:"enterprise" in
  let result = hook ~name:"masc_create_workspace" ~args:`Null in
  (match result with
   | Tool_dispatch.Reject r ->
       Alcotest.(check bool) "blocked" false (Tool_result.is_success r);
       let status = Yojson.Safe.Util.((Tool_result.data r) |> member "status" |> to_string) in
       Alcotest.(check string) "awaiting_approval" "awaiting_approval" status
   | _ -> Alcotest.fail "enterprise should block high tool");
  cleanup_tmpdir tmpdir

let test_hook_paranoid_blocks_medium () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  setup ();
  let tmpdir = make_tmpdir () in
  let config = Workspace.default_config tmpdir in
  let hook = Gp.make_pre_hook ~config ~governance_level:"paranoid" in
  let result = hook ~name:"masc_bind" ~args:`Null in
  (match result with
   | Tool_dispatch.Reject r ->
       Alcotest.(check bool) "blocked" false (Tool_result.is_success r);
       let status = Yojson.Safe.Util.((Tool_result.data r) |> member "status" |> to_string) in
       Alcotest.(check string) "awaiting_approval" "awaiting_approval" status
   | _ -> Alcotest.fail "paranoid should block medium tool");
  cleanup_tmpdir tmpdir

(* ── Response structure tests ───────────────────────────────── *)

let test_blocked_response_structure () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmpdir = make_tmpdir () in
  let config = Workspace.default_config tmpdir in
  let hook = Gp.make_pre_hook ~config ~governance_level:"paranoid" in
  let result = hook ~name:generic_transition_tool ~args:transition_claim_input in
  (match result with
   | Tool_dispatch.Reject r ->
       let module U = Yojson.Safe.Util in
       let data = (Tool_result.data r) in
       let _status = data |> U.member "status" |> U.to_string in
       let _trace = data |> U.member "trace_id" |> U.to_string in
       let _risk = data |> U.member "risk_level" |> U.to_string in
       let _gov = data |> U.member "governance_level" |> U.to_string in
       let _reason = data |> U.member "reason" |> U.to_string in
       let _tool = data |> U.member "tool_name" |> U.to_string in
       Alcotest.(check string) "governance_level" "paranoid" _gov;
       Alcotest.(check string) "risk_level" "medium" _risk;
       Alcotest.(check string) "tool_name" generic_transition_tool _tool
   | _ -> Alcotest.fail "paranoid should block medium");
  cleanup_tmpdir tmpdir

let test_blocked_response_structure_claim_next () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmpdir = make_tmpdir () in
  let config = Workspace.default_config tmpdir in
  let hook = Gp.make_pre_hook ~config ~governance_level:"paranoid" in
  let result = hook ~name:explicit_claim_tool ~args:`Null in
  (match result with
   | Tool_dispatch.Reject r ->
       let module U = Yojson.Safe.Util in
       let data = (Tool_result.data r) in
       let _risk = data |> U.member "risk_level" |> U.to_string in
       let _tool = data |> U.member "tool_name" |> U.to_string in
       Alcotest.(check string) "risk_level" "medium" _risk;
       Alcotest.(check string) "tool_name" explicit_claim_tool _tool
   | _ -> Alcotest.fail "paranoid should block claim_next");
  cleanup_tmpdir tmpdir

(* ── Unknown governance level fail-CLOSED on critical (#7641) ──────── *)

let test_unknown_governance_level_fail_closed_on_critical () =
  (* Security gate: typo / unknown level no longer silently allows every tool.
     Mirrors fail-closed posture of audit_threshold. See #7641. *)
  let d = Gp.decide ~governance_level:"nonexistent"
    ~tool_name:"masc_delete_workspace" ~input:`Null in
  (match d.action with
   | `Require_confirm _ -> ()
   | _ -> Alcotest.fail "unknown governance level should require confirm on critical risk")

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.putenv key "")
    f

let test_hitl_enabled_by_default () =
  with_env "MASC_DISABLE_HITL" "" (fun () ->
    Alcotest.(check (option string)) "production threshold"
      (Some "critical")
      (Option.map Gp.risk_level_to_string (Gp.confirm_threshold "production"));
    Alcotest.(check (option string)) "keeper production threshold"
      (Some "high")
      (Option.map Gp.risk_level_to_string (Gp.keeper_confirm_threshold "production")))

let test_hitl_can_still_be_disabled_by_env () =
  with_env "MASC_DISABLE_HITL" "true" (fun () ->
    Alcotest.(check (option string)) "production threshold disabled"
      None
      (Option.map Gp.risk_level_to_string (Gp.confirm_threshold "production"));
    Alcotest.(check (option string)) "keeper production threshold disabled"
      None
      (Option.map Gp.risk_level_to_string (Gp.keeper_confirm_threshold "production")))

let test_hitl_disabled_still_confirms_critical () =
  with_env "MASC_DISABLE_HITL" "true" (fun () ->
    let d =
      Gp.decide
        ~governance_level:"production"
        ~tool_name:"masc_delete_workspace"
        ~input:`Null
    in
    match d.action with
    | `Require_confirm reason ->
      Alcotest.(check bool) "reason non-empty" true (String.length reason > 0)
    | `Allow -> Alcotest.fail "HITL disabled must not auto-approve critical risk"
    | `Deny _ -> Alcotest.fail "critical risk should require confirm, not deny")

let test_hitl_disabled_allows_noncritical_below_threshold () =
  with_env "MASC_DISABLE_HITL" "true" (fun () ->
    let d =
      Gp.decide
        ~governance_level:"production"
        ~tool_name:"masc_create_workspace"
        ~input:`Null
    in
    match d.action with
    | `Allow -> ()
    | `Require_confirm _ ->
      Alcotest.fail "HITL disabled should keep noncritical below-threshold calls allowed"
    | `Deny _ -> Alcotest.fail "high risk should not be denied by hard-forbidden gate")

(* ── Case-insensitive tool name matching ────────────────────── *)

let test_case_insensitive_matching () =
  let risk = Gp.assess_risk ~tool_name:"MASC_DELETE_WORKSPACE" ~input:`Null in
  Alcotest.(check string) "uppercase delete is critical"
    "critical" (Gp.risk_level_to_string risk)

(* ── Lethal Trifecta Tests ─────────────────────────────────── *)

let test_trifecta_all_three_classes () =
  let (count, ext, sens, state) =
    Gp.assess_trifecta ~active_tool_names:[
      "masc_web_search";     (* External_input *)
      "tool_read_file";      (* Sensitive_access *)
      "tool_edit_file";      (* State_modification *)
    ]
  in
  Alcotest.(check int) "3 classes" 3 count;
  Alcotest.(check bool) "has external" true ext;
  Alcotest.(check bool) "has sensitive" true sens;
  Alcotest.(check bool) "has state_mod" true state

let test_trifecta_two_classes_no_escalation () =
  let (count, _, _, _) =
    Gp.assess_trifecta ~active_tool_names:[
      "tool_read_file";      (* Sensitive_access *)
      "tool_edit_file";      (* State_modification *)
    ]
  in
  Alcotest.(check int) "2 classes" 2 count

let test_trifecta_one_class () =
  let (count, _, _, _) =
    Gp.assess_trifecta ~active_tool_names:[
      "tool_read_file";      (* Sensitive_access *)
      "keeper_memory_search"; (* Sensitive_access *)
    ]
  in
  Alcotest.(check int) "1 class" 1 count

let test_trifecta_empty () =
  let (count, _, _, _) =
    Gp.assess_trifecta ~active_tool_names:[]
  in
  Alcotest.(check int) "0 classes" 0 count

let test_trifecta_bash_spans_all () =
  (* tool_execute alone has all 3 classes *)
  let (count, ext, sens, state) =
    Gp.assess_trifecta ~active_tool_names:["tool_execute"]
  in
  Alcotest.(check int) "bash alone = 3 classes" 3 count;
  Alcotest.(check bool) "has external" true ext;
  Alcotest.(check bool) "has sensitive" true sens;
  Alcotest.(check bool) "has state_mod" true state

let test_trifecta_unclassified_tools_ignored () =
  let (count, _, _, _) =
    Gp.assess_trifecta ~active_tool_names:[
      "keeper_time_now";       (* not in classification *)
      "keeper_context_status"; (* not in classification *)
    ]
  in
  Alcotest.(check int) "unclassified = 0" 0 count

let test_escalation_state_mod_in_trifecta () =
  (* tool_edit_file is normally High (contains "modify"/"set" pattern).
     With trifecta, state_modification tools escalate to at least High. *)
  let escalated =
    Gp.combinatorial_risk_escalation
      ~trifecta_active:true
      ~tool_name:"tool_edit_file"
      ~base_risk:Gp.Medium
      ~input:`Null
  in
  Alcotest.(check string) "escalated to high"
    "high" (Gp.risk_level_to_string escalated)

let test_escalation_keeps_higher_risk () =
  (* If base_risk is already Critical, escalation doesn't downgrade *)
  let escalated =
    Gp.combinatorial_risk_escalation
      ~trifecta_active:true
      ~tool_name:"tool_edit_file"
      ~base_risk:Gp.Critical
      ~input:`Null
  in
  Alcotest.(check string) "stays critical"
    "critical" (Gp.risk_level_to_string escalated)

let test_escalation_no_trifecta_no_change () =
  let unchanged =
    Gp.combinatorial_risk_escalation
      ~trifecta_active:false
      ~tool_name:"tool_edit_file"
      ~base_risk:Gp.Low
      ~input:`Null
  in
  Alcotest.(check string) "stays low without trifecta"
    "low" (Gp.risk_level_to_string unchanged)

let test_escalation_non_state_mod_unchanged () =
  (* Non-state_modification tools are not escalated even in trifecta *)
  let unchanged =
    Gp.combinatorial_risk_escalation
      ~trifecta_active:true
      ~tool_name:"tool_read_file"
      ~base_risk:Gp.Low
      ~input:`Null
  in
  Alcotest.(check string) "read-only stays low"
    "low" (Gp.risk_level_to_string unchanged)

let test_tool_capabilities_known () =
  let caps = Gp.tool_capabilities "tool_execute" in
  Alcotest.(check int) "bash has 3 capabilities" 3 (List.length caps)

let test_tool_capabilities_unknown () =
  let caps = Gp.tool_capabilities "unknown_tool" in
  Alcotest.(check int) "unknown has 0 capabilities" 0 (List.length caps)

(* ── Runner ─────────────────────────────────────────────────── *)

let () =
  Unix.putenv "MASC_DISABLE_HITL" "false";
  Alcotest.run "Governance_pipeline" [
    "risk_assessment", [
      Alcotest.test_case "critical: delete" `Quick test_risk_critical_delete;
      Alcotest.test_case "critical: force" `Quick test_risk_critical_force;
      Alcotest.test_case "critical: drop" `Quick test_risk_critical_drop;
      Alcotest.test_case "critical: kill" `Quick test_risk_critical_kill;
      Alcotest.test_case "critical: reset" `Quick test_risk_critical_reset;
      Alcotest.test_case "critical: remove" `Quick test_risk_critical_remove;
      Alcotest.test_case "critical: destroy" `Quick test_risk_critical_destroy;
      Alcotest.test_case "critical: purge" `Quick test_risk_critical_purge;
      Alcotest.test_case "high: create" `Quick test_risk_high_create;
      Alcotest.test_case "high: update" `Quick test_risk_high_update;
      Alcotest.test_case "high: deploy" `Quick test_risk_high_deploy;
      Alcotest.test_case "high: push" `Quick test_risk_high_push;
      Alcotest.test_case "high: merge" `Quick test_risk_high_merge;
      Alcotest.test_case "high: send" `Quick test_risk_high_send;
      Alcotest.test_case "high: spawn" `Quick test_risk_high_spawn;
      Alcotest.test_case "medium: claim_next" `Quick test_risk_medium_claim_next;
      Alcotest.test_case "medium: transition claim" `Quick
        test_risk_medium_transition_claim;
      Alcotest.test_case "medium: join" `Quick test_risk_medium_join;
      Alcotest.test_case "medium: leave" `Quick test_risk_medium_leave;
      Alcotest.test_case "medium: start" `Quick test_risk_medium_start;
      Alcotest.test_case "medium: stop" `Quick test_risk_medium_stop;
      Alcotest.test_case "medium: pause" `Quick test_risk_medium_pause;
      Alcotest.test_case "medium: resume" `Quick test_risk_medium_resume;
      Alcotest.test_case "medium: transition start" `Quick
        test_risk_medium_transition_start;
      Alcotest.test_case "critical: tool_execute default" `Quick
        test_risk_critical_tool_execute_default;
      Alcotest.test_case "medium: keeper task create" `Quick
        test_risk_medium_keeper_task_create;
      Alcotest.test_case "low: keeper memory write" `Quick
        test_risk_low_keeper_memory_write;
      Alcotest.test_case "payload: rm -rf is critical" `Quick
        test_risk_payload_destructive_rm_rf;
      Alcotest.test_case "payload: $(date) is medium not critical" `Quick
        test_risk_payload_evasion_only_command_substitution;
      Alcotest.test_case "payload: hex escape alone is medium" `Quick
        test_risk_payload_evasion_only_hex_escape;
      Alcotest.test_case "payload: destructive inside $(...) is critical"
        `Quick test_risk_payload_destructive_inside_substitution;
      Alcotest.test_case "medium: goal upsert" `Quick
        test_risk_medium_goal_upsert;
      Alcotest.test_case "medium: goal transition request_complete" `Quick
        test_risk_medium_goal_transition_request_complete;
      Alcotest.test_case "medium: goal verify" `Quick
        test_risk_medium_goal_verify;
      Alcotest.test_case "high: goal transition missing action" `Quick
        test_risk_high_goal_transition_missing_action;
      Alcotest.test_case "high: goal transition drop" `Quick
        test_risk_high_goal_transition_drop;
      Alcotest.test_case "high: goal transition operator block" `Quick
        test_risk_high_goal_transition_operator_block;
      Alcotest.test_case "low: transition" `Quick test_risk_low_transition;
      Alcotest.test_case "low: transition done" `Quick test_risk_low_transition_done;
      Alcotest.test_case "low: keeper msg" `Quick test_risk_low_keeper_msg;
      Alcotest.test_case "low: status" `Quick test_risk_low_status;
      Alcotest.test_case "low: list" `Quick test_risk_low_list;
      Alcotest.test_case "low: query" `Quick test_risk_low_query;
      Alcotest.test_case "low: unknown" `Quick test_risk_low_unknown;
      Alcotest.test_case "precedence: critical > high" `Quick
        test_risk_precedence_critical_over_high;
      Alcotest.test_case "metadata: admin cleanup override" `Quick
        test_risk_metadata_admin_cleanup_override;
      Alcotest.test_case "metadata: pg query override" `Quick
        test_risk_metadata_pg_query_override;
      Alcotest.test_case "payload: empty overwrite" `Quick
        test_risk_payload_empty_overwrite;
      Alcotest.test_case "payload: destructive content" `Quick
        test_risk_payload_destructive_content;
      Alcotest.test_case "payload: destructive nested string" `Quick
        test_risk_payload_destructive_nested_string;
      Alcotest.test_case "payload: safe write inherits destructive metadata" `Quick
        test_risk_payload_safe_write_inherits_destructive_metadata;
      Alcotest.test_case "payload: safe nested string remains low" `Quick
        test_risk_payload_safe_nested_string_remains_low;
      Alcotest.test_case "contract risk: delivery contract" `Quick
        test_risk_contract_risk_from_delivery_contract;
      Alcotest.test_case "contract risk: invalid contract falls back" `Quick
        test_risk_invalid_delivery_contract_falls_back_to_heuristic;
      Alcotest.test_case "contract risk: non-object input falls back" `Quick
        test_risk_contract_risk_non_object_input_falls_back_to_heuristic;
      Alcotest.test_case "contract risk: does not downgrade heuristic" `Quick
        test_risk_contract_risk_does_not_downgrade_heuristic;
      Alcotest.test_case "payload beats contract risk" `Quick
        test_risk_payload_beats_contract_risk;
      Alcotest.test_case "payload beats low override" `Quick
        test_risk_payload_beats_low_override;
      (* contract beats low override: removed (Contract_risk deleted) *)
      Alcotest.test_case "case insensitive" `Quick test_case_insensitive_matching;
    ];
    "lethal_trifecta", [
      Alcotest.test_case "all 3 classes detected" `Quick
        test_trifecta_all_three_classes;
      Alcotest.test_case "2 classes no escalation" `Quick
        test_trifecta_two_classes_no_escalation;
      Alcotest.test_case "1 class only" `Quick test_trifecta_one_class;
      Alcotest.test_case "empty tool set" `Quick test_trifecta_empty;
      Alcotest.test_case "bash spans all 3" `Quick test_trifecta_bash_spans_all;
      Alcotest.test_case "unclassified tools ignored" `Quick
        test_trifecta_unclassified_tools_ignored;
      Alcotest.test_case "escalation: state_mod in trifecta" `Quick
        test_escalation_state_mod_in_trifecta;
      Alcotest.test_case "escalation: keeps higher risk" `Quick
        test_escalation_keeps_higher_risk;
      Alcotest.test_case "escalation: no trifecta no change" `Quick
        test_escalation_no_trifecta_no_change;
      Alcotest.test_case "escalation: non-state_mod unchanged" `Quick
        test_escalation_non_state_mod_unchanged;
      Alcotest.test_case "capabilities: known tool" `Quick
        test_tool_capabilities_known;
      Alcotest.test_case "capabilities: unknown tool" `Quick
        test_tool_capabilities_unknown;
    ];
    "governance_levels", [
      Alcotest.test_case "development confirms critical" `Quick
        test_development_confirms_critical;
      Alcotest.test_case "development allows low" `Quick
        test_development_allows_low;
      Alcotest.test_case "production allows low" `Quick
        test_production_allows_low;
      Alcotest.test_case "production allows medium" `Quick
        test_production_allows_medium;
      Alcotest.test_case "production allows high" `Quick
        test_production_allows_high;
      Alcotest.test_case "production confirms critical" `Quick
        test_production_confirms_critical;
      Alcotest.test_case "enterprise allows low" `Quick
        test_enterprise_allows_low;
      Alcotest.test_case "enterprise allows medium" `Quick
        test_enterprise_allows_medium;
      Alcotest.test_case "enterprise confirms high" `Quick
        test_enterprise_confirms_high;
      Alcotest.test_case "enterprise confirms critical" `Quick
        test_enterprise_confirms_critical;
      Alcotest.test_case "paranoid allows low" `Quick
        test_paranoid_allows_low;
      Alcotest.test_case "paranoid confirms medium" `Quick
        test_paranoid_confirms_medium;
      Alcotest.test_case "paranoid confirms high" `Quick
        test_paranoid_confirms_high;
      Alcotest.test_case "paranoid confirms critical" `Quick
        test_paranoid_confirms_critical;
      Alcotest.test_case "HITL enabled by default" `Quick
        test_hitl_enabled_by_default;
      Alcotest.test_case "HITL disable env still disables gates" `Quick
        test_hitl_can_still_be_disabled_by_env;
      Alcotest.test_case "HITL disabled still confirms critical" `Quick
        test_hitl_disabled_still_confirms_critical;
      Alcotest.test_case "HITL disabled allows noncritical" `Quick
        test_hitl_disabled_allows_noncritical_below_threshold;
      Alcotest.test_case "unknown level fail-closed on critical (#7641)" `Quick
        test_unknown_governance_level_fail_closed_on_critical;
    ];
    "trace_id", [
      Alcotest.test_case "has gov_ prefix" `Quick test_decision_has_trace_id;
      Alcotest.test_case "unique per call" `Quick test_trace_ids_unique;
    ];
    "pre_hook_integration", [
      Alcotest.test_case "development blocks critical" `Quick
        test_hook_development_blocks_critical;
      Alcotest.test_case "production blocks critical" `Quick
        test_hook_production_blocks_critical;
      Alcotest.test_case "production allows low" `Quick
        test_hook_production_allows_low;
      Alcotest.test_case "enterprise blocks high" `Quick
        test_hook_enterprise_blocks_high;
      Alcotest.test_case "paranoid blocks medium" `Quick
        test_hook_paranoid_blocks_medium;
      Alcotest.test_case "blocked response structure" `Quick
        test_blocked_response_structure;
      Alcotest.test_case "blocked response structure: claim_next" `Quick
        test_blocked_response_structure_claim_next;
    ];
  ]
