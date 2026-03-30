open Alcotest
open Masc_mcp

module Tool_improve_loop = Masc_mcp.Tool_improve_loop

let with_temp_dir prefix f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%06x" prefix (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let with_ctx base_path f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Room.default_config base_path in
  let ctx =
    {
      Tool_improve_loop.config;
      agent_name = "test-agent";
      sw = None;
      clock = None;
      proc_mgr = None; net = None;
    }
  in
  f ctx

let make_pr ?(head_ref_name = "feature/pr-1") ?(base_ref_name = Some "main")
    ?mergeable ?merge_state_status ?(failing_checks = []) ?(pending_checks = [])
    ?(is_draft = false) number title =
  {
    Tool_improve_loop.number;
    title;
    url = Some (Printf.sprintf "https://example.invalid/pr/%d" number);
    head_ref_name;
    base_ref_name;
    mergeable;
    merge_state_status;
    is_draft;
    failing_checks;
    pending_checks;
  }

let make_issue ?(labels = []) number title =
  {
    Tool_improve_loop.number;
    title;
    url = Some (Printf.sprintf "https://example.invalid/issues/%d" number);
    labels;
  }

let test_rank_conflicting_pr_before_failing_pr () =
  let prs =
    [
      make_pr 11 "failing" ~mergeable:"MERGEABLE"
        ~failing_checks:[ "Build and Test" ];
      make_pr 12 "conflicting" ~mergeable:"CONFLICTING"
        ~merge_state_status:"DIRTY";
    ]
  in
  let queue = Tool_improve_loop.rank_candidates ~prs ~issues:[] () in
  match queue with
  | first :: _ ->
      check string "conflict wins" "conflict_pr"
        (Tool_improve_loop.candidate_kind_to_string first.kind)
  | [] -> fail "expected ranked queue"

let test_rank_failing_pr_before_issue () =
  let prs =
    [ make_pr 21 "failing" ~mergeable:"MERGEABLE"
        ~failing_checks:[ "Contract Harness" ] ]
  in
  let issues = [ make_issue 31 "bug" ~labels:[ "bug" ] ] in
  let queue = Tool_improve_loop.rank_candidates ~prs ~issues () in
  match queue with
  | first :: _ ->
      check string "failing pr wins" "failing_pr"
        (Tool_improve_loop.candidate_kind_to_string first.kind)
  | [] -> fail "expected ranked queue"

let test_rank_skips_current_candidate () =
  let issue = Tool_improve_loop.candidate_of_issue (make_issue 41 "current") in
  let queue =
    Tool_improve_loop.rank_candidates
      ~skip_candidate_id:(Tool_improve_loop.candidate_id issue)
      ~prs:[] ~issues:[ make_issue 41 "current"; make_issue 42 "next" ] ()
  in
  match queue with
  | first :: _ -> check int "skipped current" 42 first.number
  | [] -> fail "expected queue"

let test_failure_counter_pauses_after_three () =
  let base = Tool_improve_loop.default_state () in
  let failed1 =
    Tool_improve_loop.mark_failure base ~now:1.0 "one"
  in
  let failed2 =
    Tool_improve_loop.mark_failure failed1 ~now:2.0 "two"
  in
  let failed3 =
    Tool_improve_loop.mark_failure failed2 ~now:3.0 "three"
  in
  check int "failure count" 3 failed3.consecutive_failures;
  check string "paused" "paused"
    (Tool_improve_loop.loop_status_to_string failed3.status)

let test_state_roundtrip () =
  with_temp_dir "masc-improve-loop-state" (fun dir ->
    with_ctx dir (fun ctx ->
      let state =
        { (Tool_improve_loop.default_state ~repo:"jeong-sik/masc-mcp" ()) with
          enabled = true;
          status = Tool_improve_loop.Running;
          keeper_name = "masc-improver";
        }
      in
      Tool_improve_loop.save_state ctx.config state;
      let loaded = Tool_improve_loop.load_state ctx.config in
      check bool "enabled" true loaded.enabled;
      check string "repo" "jeong-sik/masc-mcp" loaded.repo;
      check string "keeper" "masc-improver" loaded.keeper_name))

let test_idle_tick_resets_failure_counters () =
  with_temp_dir "masc-improve-loop-idle" (fun dir ->
    with_ctx dir (fun ctx ->
      let started =
        { (Tool_improve_loop.default_state ()) with
          enabled = true;
          status = Tool_improve_loop.Running;
          repo = "jeong-sik/masc-mcp";
          last_failure = Some "previous failure";
          consecutive_failures = 2;
        }
      in
      Tool_improve_loop.save_state ctx.config started;
      let fake_driver =
        {
          Tool_improve_loop.list_prs = (fun ~repo:_ -> Ok []);
          list_issues = (fun ~repo:_ -> Ok []);
          run_command =
            (fun _argv ->
              { Tool_improve_loop.exit_code = 0; stdout = ""; stderr = "" });
          now = (fun () -> 222.0);
        }
      in
      let ok, body =
        Tool_improve_loop.tick_with_driver fake_driver ctx
          (`Assoc [ ("execute", `Bool false) ])
      in
      check bool "idle tick ok" true ok;
      let json = Yojson.Safe.from_string body in
      let failure_count =
        json |> Yojson.Safe.Util.member "consecutive_failures"
        |> Yojson.Safe.Util.to_int
      in
      check int "failure count reset" 0 failure_count;
      let last_failure =
        json |> Yojson.Safe.Util.member "last_failure"
      in
      check bool "last failure cleared" true (last_failure = `Null)))

let test_merge_command_requires_all_gates () =
  let state =
    { (Tool_improve_loop.default_state ()) with
      enabled = true;
      status = Tool_improve_loop.Running;
      repo = "jeong-sik/masc-mcp";
    }
  in
  let candidate =
    Tool_improve_loop.candidate_of_pr ~review_ok:true
      (make_pr 51 "merge"
         ~head_ref_name:"loop/issue-51-merge"
         ~base_ref_name:(Some "main")
         ~mergeable:"MERGEABLE")
  in
  let missing_review =
    Tool_improve_loop.merge_command_if_ready state ~review_ok:false candidate
  in
  check bool "no merge without review gate" true (Option.is_none missing_review);
  let ready =
    Tool_improve_loop.merge_command_if_ready state ~review_ok:true candidate
  in
  check bool "merge emitted" true (Option.is_some ready)

let test_tick_picks_conflict_candidate () =
  with_temp_dir "masc-improve-loop-tick" (fun dir ->
    with_ctx dir (fun ctx ->
      let started =
        { (Tool_improve_loop.default_state ()) with
          enabled = true;
          status = Tool_improve_loop.Running;
          repo = "jeong-sik/masc-mcp";
        }
      in
      Tool_improve_loop.save_state ctx.config started;
      let fake_driver =
        {
          Tool_improve_loop.list_prs =
            (fun ~repo:_ ->
              Ok
                [
                  make_pr 61 "failing"
                    ~mergeable:"MERGEABLE"
                    ~failing_checks:[ "Build and Test" ];
                  make_pr 62 "conflict"
                    ~mergeable:"CONFLICTING"
                    ~merge_state_status:"DIRTY";
                ]);
          list_issues =
            (fun ~repo:_ -> Ok [ make_issue 71 "bug" ~labels:[ "bug" ] ]);
          run_command =
            (fun _argv ->
              { Tool_improve_loop.exit_code = 0; stdout = ""; stderr = "" });
          now = (fun () -> 123.0);
        }
      in
      let ok, body =
        Tool_improve_loop.tick_with_driver fake_driver ctx
          (`Assoc [ ("execute", `Bool false) ])
      in
      check bool "tick ok" true ok;
      let json = Yojson.Safe.from_string body in
      let candidate_number =
        json |> Yojson.Safe.Util.member "current_candidate"
        |> Yojson.Safe.Util.member "number"
        |> Yojson.Safe.Util.to_int
      in
      check int "conflict chosen first" 62 candidate_number))

let test_execute_without_runtime_returns_team_session_error () =
  with_temp_dir "masc-improve-loop-exec" (fun dir ->
    with_ctx dir (fun ctx ->
      let started =
        { (Tool_improve_loop.default_state ()) with
          enabled = true;
          status = Tool_improve_loop.Running;
          repo = "jeong-sik/masc-mcp";
          dry_run = false;
        }
      in
      Tool_improve_loop.save_state ctx.config started;
      let fake_driver =
        {
          Tool_improve_loop.list_prs = (fun ~repo:_ -> Ok []);
          list_issues = (fun ~repo:_ -> Ok [ make_issue 81 "bug" ~labels:[ "bug" ] ]);
          run_command =
            (fun _argv ->
              { Tool_improve_loop.exit_code = 0; stdout = ""; stderr = "" });
          now = (fun () -> 321.0);
        }
      in
      let ok, body =
        Tool_improve_loop.tick_with_driver fake_driver ctx
          (`Assoc [ ("execute", `Bool true) ])
      in
      check bool "execute fails without runtime" false ok;
      let json = Yojson.Safe.from_string body in
      let error =
        json |> Yojson.Safe.Util.member "execution_error"
        |> Yojson.Safe.Util.to_string
      in
      check bool "runtime error surfaced" true
        (Astring.String.is_infix ~affix:"team session runtime unavailable" error)))

let test_tick_due_immediate_on_fresh_start () =
  let state =
    { (Tool_improve_loop.default_state ()) with
      enabled = true;
      status = Tool_improve_loop.Running;
      poll_interval_sec = 300;
    }
  in
  check bool "fresh state ticks immediately" true
    (Tool_improve_loop.tick_due state ~now:10.0)

let test_tick_due_waits_for_interval_after_activity () =
  let state =
    { (Tool_improve_loop.default_state ()) with
      enabled = true;
      status = Tool_improve_loop.Running;
      poll_interval_sec = 300;
      updated_at = 100.0;
      last_success = Some "planned";
      current_phase = Some "issue_burn_down";
    }
  in
  check bool "not due early" false
    (Tool_improve_loop.tick_due state ~now:200.0);
  check bool "due after interval" true
    (Tool_improve_loop.tick_due state ~now:401.0)

let () =
  Random.self_init ();
  run "Tool_improve_loop"
    [
      ( "ranking",
        [
          test_case "conflicting PR beats failing PR" `Quick
            test_rank_conflicting_pr_before_failing_pr;
          test_case "failing PR beats issue" `Quick
            test_rank_failing_pr_before_issue;
          test_case "skip current candidate" `Quick
            test_rank_skips_current_candidate;
        ] );
      ( "state",
        [
          test_case "failure pause after three" `Quick
            test_failure_counter_pauses_after_three;
          test_case "state roundtrip" `Quick test_state_roundtrip;
          test_case "idle tick resets failure counters" `Quick
            test_idle_tick_resets_failure_counters;
        ] );
      ( "actions",
        [
          test_case "merge requires gates" `Quick
            test_merge_command_requires_all_gates;
          test_case "tick selects conflict candidate" `Quick
            test_tick_picks_conflict_candidate;
          test_case "execute without runtime surfaces team session error" `Quick
            test_execute_without_runtime_returns_team_session_error;
          test_case "tick due fresh start" `Quick
            test_tick_due_immediate_on_fresh_start;
          test_case "tick due interval gate" `Quick
            test_tick_due_waits_for_interval_after_activity;
        ] );
    ]
