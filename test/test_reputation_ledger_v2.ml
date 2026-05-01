(** Tests for Reputation_ledger_v2 — append-only event ledger. *)

open Alcotest
open Masc_mcp

let temp_dir () =
  let path =
    Filename.temp_file ~temp_dir:(Filename.get_temp_dir_name ())
      "test_reputation_ledger_v2_" ""
  in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None ->
      (* Repo convention: use an empty env value as the portable unset
         approximation; see the same pattern in env-config tests. *)
      Unix.putenv name ""

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with _ -> ()

let with_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  let saved_pg = Sys.getenv_opt "MASC_POSTGRES_URL" in
  let saved_sb = Sys.getenv_opt "SB_PG_URL" in
  Unix.putenv "MASC_POSTGRES_URL" "";
  Unix.putenv "SB_PG_URL" "";
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_POSTGRES_URL" saved_pg;
      restore_env "SB_PG_URL" saved_sb;
      cleanup_dir dir)
    (fun () ->
      let config = Coord.default_config dir in
      ignore (Coord.init config ~agent_name:(Some "test-agent"));
      f config)

(* ── Tool outcome emit / read ─────────────────────────────────────── *)

let test_emit_and_read_tool_outcome () =
  with_room (fun config ->
    Reputation_ledger_v2.emit_tool_outcome config
      ~agent_id:"agent-alpha"
      ~tool_name:"keeper_bash"
      ~success:true
      ();
    Reputation_ledger_v2.emit_tool_outcome config
      ~agent_id:"agent-alpha"
      ~tool_name:"masc_board_post"
      ~success:false
      ~error_kind:(Reputation_ledger_v2.error_kind_of_string "validation_error")
      ~raw_trace_run_id:"run-001"
      ();
    let events =
      Reputation_ledger_v2.read_events_for_agent config
        ~agent_id:"agent-alpha" ~window_days:30
    in
    check int "two events" 2 (List.length events);
    let successes =
      List.filter
        (function
          | Reputation_ledger_v2.Tool_outcome e -> e.success
          | _ -> false)
        events
    in
    check int "one success" 1 (List.length successes))

let test_emit_goal_completion () =
  with_room (fun config ->
    Reputation_ledger_v2.emit_goal_completion config
      ~agent_id:"agent-beta"
      ~task_id:"task-001"
      ~task_title:"Fix CI"
      ~completed_within_budget:true
      ~on_topic:true
      ();
    Reputation_ledger_v2.emit_goal_completion config
      ~agent_id:"agent-beta"
      ~task_id:"task-002"
      ~task_title:"Write docs"
      ~completed_within_budget:false
      ~on_topic:true
      ~raw_trace_run_id:"run-002"
      ();
    let events =
      Reputation_ledger_v2.read_events_for_agent config
        ~agent_id:"agent-beta" ~window_days:30
    in
    check int "two goal events" 2 (List.length events))

let test_emit_safety_violation () =
  with_room (fun config ->
    Reputation_ledger_v2.emit_safety_violation config
      ~agent_id:"agent-gamma"
      ~violation_kind:"scope_violation"
      ~tool_name:"keeper_exec"
      ();
    let events =
      Reputation_ledger_v2.read_events_for_agent config
        ~agent_id:"agent-gamma" ~window_days:30
    in
    check int "one violation" 1 (List.length events);
    (match List.hd events with
     | Reputation_ledger_v2.Safety_violation e ->
       check string "violation kind" "scope_violation" e.violation_kind;
       check (option string) "tool name" (Some "keeper_exec") e.tool_name
     | _ -> fail "expected Safety_violation"))

let test_empty_agent_id_is_no_op () =
  with_room (fun config ->
    (* An empty agent_id must not crash and must not write to the ledger. *)
    Reputation_ledger_v2.emit_tool_outcome config
      ~agent_id:"" ~tool_name:"some_tool" ~success:true ();
    let events =
      Reputation_ledger_v2.read_events_for_agent config
        ~agent_id:"" ~window_days:30
    in
    check int "no events for empty agent" 0 (List.length events))

let test_agent_isolation () =
  with_room (fun config ->
    Reputation_ledger_v2.emit_tool_outcome config
      ~agent_id:"agent-a" ~tool_name:"tool1" ~success:true ();
    Reputation_ledger_v2.emit_tool_outcome config
      ~agent_id:"agent-b" ~tool_name:"tool2" ~success:false ();
    let events_a =
      Reputation_ledger_v2.read_events_for_agent config
        ~agent_id:"agent-a" ~window_days:30
    in
    let events_b =
      Reputation_ledger_v2.read_events_for_agent config
        ~agent_id:"agent-b" ~window_days:30
    in
    check int "only a's events" 1 (List.length events_a);
    check int "only b's events" 1 (List.length events_b))

(* ── Aggregate metrics ───────────────────────────────────────────── *)

let test_default_metrics_neutral () =
  let m = Reputation_ledger_v2.default_ledger_metrics in
  check (float 0.0001) "execution_reliability neutral" 1.0 m.execution_reliability;
  check (float 0.0001) "goal_adherence neutral" 1.0 m.goal_adherence;
  check (float 0.0001) "safety_compliance neutral" 1.0 m.safety_compliance

let test_compute_metrics_all_success () =
  with_room (fun config ->
    for _ = 1 to 5 do
      Reputation_ledger_v2.emit_tool_outcome config
        ~agent_id:"perfect-agent" ~tool_name:"tool" ~success:true ()
    done;
    Reputation_ledger_v2.emit_goal_completion config
      ~agent_id:"perfect-agent" ~task_id:"t1" ~task_title:"Goal"
      ~completed_within_budget:true ~on_topic:true ();
    let m =
      Reputation_ledger_v2.compute_ledger_metrics config
        ~agent_id:"perfect-agent" ~window_days:30
    in
    check int "tool calls" 5 m.tool_calls;
    check int "tool successes" 5 m.tool_successes;
    check (float 0.0001) "execution_reliability" 1.0 m.execution_reliability;
    check int "goal completions" 1 m.goal_completions;
    check int "goal adherent" 1 m.goal_adherent_completions;
    check (float 0.0001) "goal_adherence" 1.0 m.goal_adherence;
    check (float 0.0001) "safety_compliance" 1.0 m.safety_compliance)

let test_compute_metrics_partial_failure () =
  with_room (fun config ->
    Reputation_ledger_v2.emit_tool_outcome config
      ~agent_id:"partial-agent" ~tool_name:"tool" ~success:true ();
    Reputation_ledger_v2.emit_tool_outcome config
      ~agent_id:"partial-agent" ~tool_name:"tool" ~success:true ();
    Reputation_ledger_v2.emit_tool_outcome config
      ~agent_id:"partial-agent" ~tool_name:"tool" ~success:false ();
    let m =
      Reputation_ledger_v2.compute_ledger_metrics config
        ~agent_id:"partial-agent" ~window_days:30
    in
    check int "tool calls" 3 m.tool_calls;
    check (float 0.0001) "execution_reliability" (2.0 /. 3.0)
      m.execution_reliability)

let test_safety_compliance_penalty () =
  with_room (fun config ->
    Reputation_ledger_v2.emit_safety_violation config
      ~agent_id:"violator" ~violation_kind:"scope_violation" ();
    Reputation_ledger_v2.emit_safety_violation config
      ~agent_id:"violator" ~violation_kind:"external_in_draft" ();
    let m =
      Reputation_ledger_v2.compute_ledger_metrics config
        ~agent_id:"violator" ~window_days:30
    in
    check int "safety violations" 2 m.safety_violations;
    (* 1.0 - 2 * 0.2 = 0.6 *)
    check (float 0.0001) "safety_compliance" 0.6 m.safety_compliance)

let test_safety_compliance_floors_at_zero () =
  with_room (fun config ->
    (* Emit 10 violations; penalty would be 2.0 but must clamp at 1.0. *)
    for _ = 1 to 10 do
      Reputation_ledger_v2.emit_safety_violation config
        ~agent_id:"many-violator" ~violation_kind:"scope_violation" ()
    done;
    let m =
      Reputation_ledger_v2.compute_ledger_metrics config
        ~agent_id:"many-violator" ~window_days:30
    in
    check (float 0.0001) "safety_compliance floors" 0.0 m.safety_compliance)

let () =
  run "Reputation_ledger_v2"
    [ ( "emit_read",
        [ test_case "emit and read tool outcome" `Quick
            test_emit_and_read_tool_outcome
        ; test_case "emit goal completion" `Quick
            test_emit_goal_completion
        ; test_case "emit safety violation" `Quick
            test_emit_safety_violation
        ; test_case "empty agent_id is no-op" `Quick
            test_empty_agent_id_is_no_op
        ; test_case "agent isolation" `Quick
            test_agent_isolation
        ] )
    ; ( "metrics",
        [ test_case "default metrics are neutral" `Quick
            test_default_metrics_neutral
        ; test_case "all success → reliability 1.0" `Quick
            test_compute_metrics_all_success
        ; test_case "partial failures reduce reliability" `Quick
            test_compute_metrics_partial_failure
        ; test_case "safety violations apply penalty" `Quick
            test_safety_compliance_penalty
        ; test_case "safety compliance floors at zero" `Quick
            test_safety_compliance_floors_at_zero
        ] )
    ]
