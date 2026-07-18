module A = Masc.Keeper_board_attention_candidate
module J = Masc.Keeper_board_attention_judgment
module P = Masc.Keeper_board_attention_partition
module W = Masc.Keeper_board_attention_worker
module U = Yojson.Safe.Util

exception Test_done

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base name f =
  let base_path = Filename.temp_dir name "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let candidate ~keeper_name index : A.candidate =
  let signal : Masc.Board_dispatch.board_signal =
    { kind = Masc.Board_dispatch.Board_post_created
    ; post_id = Printf.sprintf "%s-post-%03d" keeper_name index
    ; author = "external-author"
    ; title = "Board update"
    ; content = Printf.sprintf "%s-candidate-%03d" keeper_name index
    ; hearth = Some "worker-test"
    ; updated_at = Some (float_of_int index)
    }
  in
  let candidate_id = A.candidate_id_of_signal ~keeper_name signal in
  { candidate_id
  ; keeper_name
  ; signal
  ; judgment_request =
      `Assoc
        [ ( "keeper_context"
          , `Assoc
              [ "lane_keeper_name", `String keeper_name
              ; "instructions", `String "worker test context"
              ] )
        ; "candidate_id", `String candidate_id
        ; "signal", A.signal_to_yojson signal
        ]
  ; recorded_at = float_of_int index
  ; status = A.Pending { last_failure = None }
  }
;;

let judgment candidate : A.judgment =
  { verdict =
      { J.decision = J.Not_relevant
      ; rationale = "worker exact judgment for " ^ candidate.A.candidate_id
      }
  ; runtime_id = "worker-test-runtime"
  ; judged_at = 200.0
  }
;;

let exact_map candidates =
  List.fold_left
    (fun map candidate ->
       A.Candidate_map.add candidate.A.candidate_id (judgment candidate) map)
    A.Candidate_map.empty
    candidates
;;

let record_candidate ~base_path candidate =
  match W.record_and_notify ~base_path candidate with
  | Ok acceptance -> acceptance
  | Error detail -> Alcotest.fail detail
;;

let rec await_registered ~base_path =
  if W.For_testing.registered ~base_path
  then ()
  else (
    Eio.Fiber.yield ();
    await_registered ~base_path)
;;

let rec await_completed ~base_path ~keeper_name =
  match P.completed ~base_path ~keeper_name with
  | Ok (_ :: _ as completed) -> completed
  | Ok [] ->
    Eio.Fiber.yield ();
    await_completed ~base_path ~keeper_name
  | Error detail -> Alcotest.fail detail
;;

let rec await_deferred_candidate ~base_path ~keeper_name ~candidate_id =
  match P.load ~base_path ~keeper_name with
  | Ok partitions
    when List.exists
           (fun partition ->
              partition.P.candidate_ids = [ candidate_id ]
              && match partition.state with
                 | P.Deferred _ -> true
                 | P.Ready | P.Running _ | P.Completed _ | P.Settled _ | P.Blocked _ ->
                   false)
           partitions ->
    ()
  | Ok _ ->
    Eio.Fiber.yield ();
    await_deferred_candidate ~base_path ~keeper_name ~candidate_id
  | Error detail -> Alcotest.fail detail
;;

let rec await_lane_failure ~base_path =
  let health = W.health_json ~base_path in
  if U.(health |> member "lane_failure_count" |> to_int) > 0
  then health
  else (
    Eio.Fiber.yield ();
    await_lane_failure ~base_path)
;;

let within clock f =
  Eio.Time.with_timeout_exn clock 5.0 f
;;

let test_owner_drain_never_waits_for_provider () =
  with_temp_base "board-worker-owner-independent" @@ fun base_path ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let provider_started, resolve_provider_started = Eio.Promise.create () in
  let release_provider, resolve_release_provider = Eio.Promise.create () in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       W.For_testing.start_with_judge
         ~sw
         ~base_path
         ~worker_epoch:"owner-independent-epoch"
         ~judge:(fun candidates ->
           Eio.Promise.resolve resolve_provider_started ();
           Eio.Promise.await release_provider;
           Ok (exact_map candidates))
         ());
     within clock (fun () -> await_registered ~base_path);
     let acceptance = record_candidate ~base_path (candidate ~keeper_name:"keeper-a" 1) in
     Alcotest.(check bool)
       "worker was signaled"
       true
       (match acceptance.signal with
        | W.Signaled | W.Coalesced -> true
        | W.Worker_not_registered | W.No_signal_required -> false);
     within clock (fun () -> Eio.Promise.await provider_started);
     Alcotest.(check int)
       "one provider lane active"
       1
       (W.For_testing.active_keeper_count ~base_path);
     let owner_report =
       match W.drain_completed_on_owner_lane ~base_path ~keeper_name:"keeper-a" with
       | Ok report -> report
       | Error detail -> Alcotest.fail detail
     in
     Alcotest.(check int) "owner attempted no provider work" 0 owner_report.attempted;
     Alcotest.(check int) "owner consumed no incomplete work" 0 owner_report.consumed;
     Eio.Promise.resolve resolve_release_provider ();
     ignore
       (within clock (fun () ->
          await_completed ~base_path ~keeper_name:"keeper-a")
        : P.t list);
     let settled =
       match
         Eio_unix.run_in_systhread
           ~label:"test-board-attention-owner-delivery"
           (fun () ->
              W.drain_completed_on_owner_lane
                ~base_path
                ~keeper_name:"keeper-a")
       with
       | Ok report -> report
       | Error detail -> Alcotest.fail detail
     in
     Alcotest.(check int) "completed result consumed" 1 settled.consumed;
     (match P.load ~base_path ~keeper_name:"keeper-a" with
      | Ok [ { state = P.Settled _; _ } ] -> ()
      | Ok _ -> Alcotest.fail "owner did not settle the durable partition"
      | Error detail -> Alcotest.fail detail);
     raise Test_done
   with Test_done -> ())
;;

let test_blocked_keeper_does_not_block_sibling () =
  with_temp_base "board-worker-sibling" @@ fun base_path ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let keeper_a_started, resolve_keeper_a_started = Eio.Promise.create () in
  let release_keeper_a, resolve_release_keeper_a = Eio.Promise.create () in
  let keeper_b_judged, resolve_keeper_b_judged = Eio.Promise.create () in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       W.For_testing.start_with_judge
         ~sw
         ~base_path
         ~worker_epoch:"sibling-epoch"
         ~judge:(fun candidates ->
           match candidates with
           | first :: _ when String.equal first.A.keeper_name "keeper-a" ->
             Eio.Promise.resolve resolve_keeper_a_started ();
             Eio.Promise.await release_keeper_a;
             Ok (exact_map candidates)
           | _ ->
             Eio.Promise.resolve resolve_keeper_b_judged ();
             Ok (exact_map candidates))
         ());
     within clock (fun () -> await_registered ~base_path);
     ignore
       (record_candidate ~base_path (candidate ~keeper_name:"keeper-a" 1)
        : W.record_acceptance);
     within clock (fun () -> Eio.Promise.await keeper_a_started);
     ignore
       (Domain.join
          (Domain.spawn (fun () ->
             record_candidate
               ~base_path
               (candidate ~keeper_name:"keeper-b" 1)))
        : W.record_acceptance);
     within clock (fun () -> Eio.Promise.await keeper_b_judged);
     ignore
       (within clock (fun () ->
          await_completed ~base_path ~keeper_name:"keeper-b")
        : P.t list);
     Alcotest.(check bool)
       "keeper A remains provider-blocked"
       true
       (match Eio.Promise.peek release_keeper_a with
        | None -> true
        | Some () -> false);
     let sibling =
       match W.drain_completed_on_owner_lane ~base_path ~keeper_name:"keeper-b" with
       | Ok report -> report
       | Error detail -> Alcotest.fail detail
     in
     Alcotest.(check int) "sibling completed independently" 1 sibling.consumed;
     Eio.Promise.resolve resolve_release_keeper_a ();
     raise Test_done
   with Test_done -> ())
;;

let test_startup_scan_isolates_malformed_ledger () =
  with_temp_base "board-worker-startup" @@ fun base_path ->
  let acceptance = record_candidate ~base_path (candidate ~keeper_name:"keeper-boot" 1) in
  let ledger_dir =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      "board_attention_candidates"
  in
  let malformed_path = Filename.concat ledger_dir "malformed.jsonl" in
  let channel = open_out_bin malformed_path in
  output_string channel "not-json\n";
  close_out channel;
  Alcotest.(check bool)
    "pre-start durable record has no live worker"
    true
    (match acceptance.signal with
     | W.Worker_not_registered -> true
     | W.Signaled | W.Coalesced | W.No_signal_required -> false);
  let pre_start_health = W.health_json ~base_path in
  Alcotest.(check bool)
    "durable work without worker requires operator action"
    true
    U.(pre_start_health |> member "operator_action_required" |> to_bool);
  Alcotest.(check bool)
    "worker registration truth is visible"
    false
    U.(pre_start_health |> member "worker_registered" |> to_bool);
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       W.For_testing.start_with_judge
         ~sw
         ~base_path
         ~worker_epoch:"startup-epoch"
         ~judge:(fun candidates -> Ok (exact_map candidates))
         ());
     within clock (fun () -> await_registered ~base_path);
     ignore
       (within clock (fun () ->
          await_completed ~base_path ~keeper_name:"keeper-boot")
        : P.t list);
     let health = W.health_json ~base_path in
     Alcotest.(check int)
       "malformed ledger remains operator-visible"
       1
       U.(health |> member "candidate_ledger_discovery_error_count" |> to_int);
     raise Test_done
   with Test_done -> ())
;;

let test_lane_cancellation_is_visible_and_sibling_survives () =
  with_temp_base "board-worker-lane-failure" @@ fun base_path ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       W.For_testing.start_with_judge
         ~sw
         ~base_path
         ~worker_epoch:"lane-failure-epoch"
         ~judge:(fun candidates ->
           match candidates with
           | first :: _ when String.equal first.A.keeper_name "keeper-a" ->
             raise (Eio.Cancel.Cancelled Exit)
           | _ -> Ok (exact_map candidates))
         ());
     within clock (fun () -> await_registered ~base_path);
     ignore
       (record_candidate ~base_path (candidate ~keeper_name:"keeper-a" 1)
        : W.record_acceptance);
     let health = within clock (fun () -> await_lane_failure ~base_path) in
     Alcotest.(check bool)
       "lane failure requires operator action"
       true
       U.(health |> member "operator_action_required" |> to_bool);
     ignore
       (record_candidate ~base_path (candidate ~keeper_name:"keeper-b" 1)
        : W.record_acceptance);
     ignore
       (within clock (fun () ->
          await_completed ~base_path ~keeper_name:"keeper-b")
        : P.t list);
     raise Test_done
   with Test_done -> ())
;;

let test_candidate_signal_does_not_retry_deferred_partition () =
  with_temp_base "board-worker-typed-signal" @@ fun base_path ->
  let keeper_name = "keeper-signal" in
  let first = candidate ~keeper_name 1 in
  let second = candidate ~keeper_name 2 in
  let judge_calls = ref 0 in
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       W.For_testing.start_with_judge
         ~sw
         ~base_path
         ~worker_epoch:"typed-signal-epoch"
         ~judge:(fun candidates ->
           incr judge_calls;
           match candidates with
           | [ candidate ] when String.equal candidate.A.candidate_id first.candidate_id ->
             Error
               { A.kind = A.Provider_unavailable
               ; detail = "provider unavailable"
               ; failed_at = 200.0
               }
           | _ -> Ok (exact_map candidates))
         ());
     within clock (fun () -> await_registered ~base_path);
     ignore (record_candidate ~base_path first : W.record_acceptance);
     within clock (fun () ->
       await_deferred_candidate
         ~base_path
         ~keeper_name
         ~candidate_id:first.candidate_id);
     ignore (record_candidate ~base_path second : W.record_acceptance);
     let completed =
       within clock (fun () -> await_completed ~base_path ~keeper_name)
     in
     Alcotest.(check (list string))
       "new candidate completes independently"
       [ second.candidate_id ]
       (List.concat_map (fun partition -> partition.P.candidate_ids) completed);
     Alcotest.(check int)
       "deferred partition was not retried by candidate signal"
       2
       !judge_calls;
     raise Test_done
   with Test_done -> ())
;;

let () =
  Alcotest.run
    "keeper_board_attention_worker"
    [ ( "owner-independent judgment"
      , [ Alcotest.test_case
            "owner drain never waits for provider"
            `Quick
            test_owner_drain_never_waits_for_provider
        ; Alcotest.test_case
            "blocked keeper does not block sibling"
            `Quick
            test_blocked_keeper_does_not_block_sibling
        ; Alcotest.test_case
            "startup scan isolates malformed ledger"
            `Quick
            test_startup_scan_isolates_malformed_ledger
        ; Alcotest.test_case
            "lane cancellation is visible and sibling survives"
            `Quick
            test_lane_cancellation_is_visible_and_sibling_survives
        ; Alcotest.test_case
            "candidate signal does not retry deferred partition"
            `Quick
            test_candidate_signal_does_not_retry_deferred_partition
        ] )
    ]
;;
