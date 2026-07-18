module A = Masc.Keeper_board_attention_candidate
module J = Masc.Keeper_board_attention_judgment
module P = Masc.Keeper_board_attention_partition
module R = Masc.Keeper_registry
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

let relevant_judgment candidate : A.judgment =
  { (judgment candidate) with
    verdict =
      { J.decision = J.Relevant
      ; rationale = "worker exact relevant judgment for " ^ candidate.A.candidate_id
      }
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

let persist_candidate ~base_path candidate =
  match A.record ~base_path candidate with
  | A.Recorded persisted | A.Duplicate persisted -> persisted
  | A.Record_error detail -> Alcotest.fail detail
;;

let keeper_meta keeper_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String keeper_name
        ; "agent_name", `String ("agent-" ^ keeper_name)
        ; "trace_id", `String ("trace-" ^ keeper_name)
        ; "autoboot_enabled", `Bool false
        ])
  with
  | Ok meta -> meta
  | Error detail -> Alcotest.failf "keeper meta fixture failed: %s" detail
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

let rec await_completed_count ~base_path ~keeper_name ~expected =
  match P.completed ~base_path ~keeper_name with
  | Ok completed when List.length completed >= expected -> completed
  | Ok _ ->
    Eio.Fiber.yield ();
    await_completed_count ~base_path ~keeper_name ~expected
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

let rec await_owner_wake entry =
  if Atomic.get entry.R.fiber_wakeup
  then ()
  else (
    Eio.Fiber.yield ();
    await_owner_wake entry)
;;

let within clock f =
  Eio.Time.with_timeout_exn clock 5.0 f
;;

let json_field_names = function
  | `Assoc fields -> List.map fst fields |> List.sort_uniq String.compare
  | _ -> Alcotest.fail "health projection must be an object"
;;

let test_placeholder_health_shape_matches_live_projection () =
  with_temp_base "board-worker-health-shape" @@ fun base_path ->
  let live_fields = W.health_json ~base_path |> json_field_names in
  let placeholder =
    W.placeholder_health_json
      ~status:Health_status.Timeout
      ~component_timed_out:true
  in
  let placeholder_fields =
    placeholder
    |> json_field_names
    |> List.filter (fun name -> not (String.equal name "component_timed_out"))
  in
  Alcotest.(check (list string))
    "placeholder and live health share one field contract"
    live_fields
    placeholder_fields;
  Alcotest.(check string)
    "placeholder preserves typed timeout status"
    "timeout"
    U.(placeholder |> member "status" |> to_string)
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
         ~worker_epoch:(P.Worker_epoch.generate ())
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
         ~worker_epoch:(P.Worker_epoch.generate ())
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
         ~worker_epoch:(P.Worker_epoch.generate ())
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

let test_startup_replays_completed_owner_wake () =
  with_temp_base "board-worker-completed-wake" @@ fun base_path ->
  let keeper_name = "keeper-completed" in
  let pending = candidate ~keeper_name 1 |> persist_candidate ~base_path in
  let worker_epoch = P.Worker_epoch.generate () in
  let root =
    match P.ensure_roots ~base_path ~keeper_name [ pending ] with
    | Error detail -> Alcotest.fail detail
    | Ok _ ->
      (match P.claim_next ~now:100.0 ~worker_epoch ~base_path ~keeper_name with
       | Ok (Some root) -> root
       | Ok None -> Alcotest.fail "expected a ready partition"
       | Error detail -> Alcotest.fail detail)
  in
  ignore
    (match
       P.complete
         ~now:110.0
         ~worker_epoch
         ~base_path
         ~partition:root
         ~items:[ { P.candidate_id = pending.candidate_id; judgment = judgment pending } ]
     with
     | Ok transition -> transition
     | Error detail -> Alcotest.fail detail
      : P.transition);
  R.clear ();
  Fun.protect
    ~finally:R.clear
    (fun () ->
       let owner = R.register ~base_path keeper_name (keeper_meta keeper_name) in
       Atomic.set owner.fiber_wakeup false;
       Eio_main.run @@ fun env ->
       let clock = Eio.Stdenv.clock env in
       (try
          Eio.Switch.run @@ fun sw ->
          Eio.Fiber.fork ~sw (fun () ->
            W.For_testing.start_with_judge
              ~sw
              ~base_path
              ~worker_epoch:(P.Worker_epoch.generate ())
              ~judge:(fun _ -> Alcotest.fail "Completed recovery called provider")
              ());
          within clock (fun () -> await_registered ~base_path);
          within clock (fun () -> await_owner_wake owner);
          Alcotest.(check bool)
            "startup replayed durable Completed owner wake"
            true
            (Atomic.get owner.fiber_wakeup);
          raise Test_done
        with Test_done -> ()))
;;

let test_delivery_failure_degrades_worker_health () =
  with_temp_base "board-worker-delivery-health" @@ fun base_path ->
  let pending =
    candidate ~keeper_name:"keeper-delivery" 1 |> persist_candidate ~base_path
  in
  let judged =
    match A.record_judgment ~base_path pending (judgment pending) with
    | Ok judged -> judged
    | Error detail -> Alcotest.fail detail
  in
  ignore
    (match
       A.record_retryable_failure
         ~base_path
         judged
         { A.kind = A.Durable_delivery_unavailable
         ; detail = "event queue unavailable"
         ; failed_at = 210.0
         }
     with
     | Ok failed -> failed
     | Error detail -> Alcotest.fail detail
      : A.candidate);
  let health = W.health_json ~base_path in
  Alcotest.(check string)
    "delivery failure degrades worker health"
    "degraded"
    U.(health |> member "status" |> to_string);
  Alcotest.(check bool)
    "delivery failure requires operator action"
    true
    U.(health |> member "operator_action_required" |> to_bool);
  Alcotest.(check int)
    "delivery failure count"
    1
    U.(health |> member "candidate_delivery_failure_count" |> to_int);
  Alcotest.(check bool)
    "delivery failure reason is explicit"
    true
    U.(health |> member "status_reasons" |> to_list |> List.mem (`String "candidate_delivery_failures"))
;;

let test_owner_drain_rejects_partial_delivery_success () =
  with_temp_base "board-worker-owner-delivery-failure" @@ fun base_path ->
  let keeper_name = "keeper-owner-failure" in
  let pending = candidate ~keeper_name 1 |> persist_candidate ~base_path in
  ignore
    (match A.record_judgment ~base_path pending (relevant_judgment pending) with
     | Ok judged -> judged
     | Error detail -> Alcotest.fail detail
      : A.candidate);
  let queue_dir =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      (Filename.concat "keepers" keeper_name)
  in
  Fs_compat.mkdir_p queue_dir;
  let queue_path = Filename.concat queue_dir "event-queue.json" in
  let channel = open_out_bin queue_path in
  output_string channel "{\"schema\":\"keeper.event_queue.state.v2\"}\n";
  close_out channel;
  (match W.drain_completed_on_owner_lane ~base_path ~keeper_name with
   | Error detail ->
     Alcotest.(check bool)
       "remaining delivery is an explicit failure"
       true
       (String.length detail > 0)
   | Ok _ -> Alcotest.fail "partial durable delivery returned success");
  let health = W.health_json ~base_path in
  Alcotest.(check int)
    "failed owner delivery remains visible"
    1
    U.(health |> member "candidate_delivery_failure_count" |> to_int)
;;

let test_injected_loader_cannot_cross_keeper_identity () =
  with_temp_base "board-worker-loader-identity" @@ fun base_path ->
  let keeper_name = "keeper-loader-owner" in
  ignore
    (record_candidate ~base_path (candidate ~keeper_name 1) : W.record_acceptance);
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       W.For_testing.start_with_judge
         ~load_candidates:(fun ~base_path:_ ~keeper_name:_ ->
           Ok [ candidate ~keeper_name:"other-keeper" 1 ])
         ~sw
         ~base_path
         ~worker_epoch:(P.Worker_epoch.generate ())
         ~judge:(fun selected -> Ok (exact_map selected))
         ());
     within clock (fun () -> await_registered ~base_path);
     let health = within clock (fun () -> await_lane_failure ~base_path) in
     Alcotest.(check int)
       "cross-Keeper loader failure is operator-visible"
       1
       U.(health |> member "lane_failure_count" |> to_int);
     (match P.load ~base_path ~keeper_name with
      | Ok [] -> ()
      | Ok _ -> Alcotest.fail "cross-Keeper loader persisted a partition root"
      | Error detail -> Alcotest.fail detail);
     raise Test_done
   with Test_done -> ())
;;

let test_lane_cancellation_is_visible_and_sibling_survives () =
  with_temp_base "board-worker-lane-failure" @@ fun base_path ->
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let cancel_keeper_a_once = ref true in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       W.For_testing.start_with_judge
         ~sw
         ~base_path
         ~worker_epoch:(P.Worker_epoch.generate ())
         ~judge:(fun candidates ->
           match candidates with
           | first :: _
             when String.equal first.A.keeper_name "keeper-a" && !cancel_keeper_a_once ->
             cancel_keeper_a_once := false;
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
       (record_candidate ~base_path (candidate ~keeper_name:"keeper-a" 2)
        : W.record_acceptance);
     let recovered =
       within clock (fun () ->
         await_completed_count ~base_path ~keeper_name:"keeper-a" ~expected:2)
     in
     Alcotest.(check (list string))
       "a later signal can execute the released claim"
       [ (candidate ~keeper_name:"keeper-a" 1).A.candidate_id
       ; (candidate ~keeper_name:"keeper-a" 2).A.candidate_id
       ]
       (List.concat_map (fun partition -> partition.P.candidate_ids) recovered);
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
         ~worker_epoch:(P.Worker_epoch.generate ())
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

let test_lane_cycle_builds_one_snapshot_and_continues_after_defer () =
  with_temp_base "board-worker-single-snapshot" @@ fun base_path ->
  let keeper_name = "keeper-snapshot" in
  let candidates = List.init 17 (fun index -> candidate ~keeper_name (index + 1)) in
  let first = List.hd candidates in
  List.iter
    (fun candidate ->
       let acceptance = record_candidate ~base_path candidate in
       Alcotest.(check bool)
         "pre-start candidate remains durable without a worker"
         true
         (match acceptance.signal with
          | W.Worker_not_registered -> true
          | W.Signaled | W.Coalesced | W.No_signal_required -> false))
    candidates;
  let snapshot_count = Atomic.make 0 in
  let judge_count = ref 0 in
  let load_candidates ~base_path ~keeper_name =
    ignore (Atomic.fetch_and_add snapshot_count 1 : int);
    A.load_candidates ~base_path ~keeper_name
  in
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       W.For_testing.start_with_judge
         ~load_candidates
         ~sw
         ~base_path
         ~worker_epoch:(P.Worker_epoch.generate ())
         ~judge:(fun selected ->
           incr judge_count;
           match selected with
           | [ candidate ]
             when String.equal candidate.A.candidate_id first.candidate_id ->
             Error
               { A.kind = A.Provider_unavailable
               ; detail = "provider unavailable"
               ; failed_at = 200.0
               }
           | _ -> Ok (exact_map selected))
         ());
     within clock (fun () -> await_registered ~base_path);
     within clock (fun () ->
       await_deferred_candidate
         ~base_path
         ~keeper_name
         ~candidate_id:first.candidate_id);
     ignore
       (within clock (fun () ->
          await_completed_count
            ~base_path
            ~keeper_name
            ~expected:(List.length candidates - 1))
        : P.t list);
     Alcotest.(check int)
       "one immutable candidate index per lane cycle"
       1
       (Atomic.get snapshot_count);
     Alcotest.(check int)
       "deferred root does not stop ready siblings"
       (List.length candidates)
       !judge_count;
     raise Test_done
   with Test_done -> ())
;;

let test_active_lane_candidate_owns_next_snapshot () =
  with_temp_base "board-worker-next-snapshot" @@ fun base_path ->
  let keeper_name = "keeper-next-snapshot" in
  let first = candidate ~keeper_name 1 in
  let second = candidate ~keeper_name 2 in
  let load_count = Atomic.make 0 in
  let load_candidates ~base_path ~keeper_name =
    ignore (Atomic.fetch_and_add load_count 1 : int);
    A.load_candidates ~base_path ~keeper_name
  in
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let first_started, resolve_first_started = Eio.Promise.create () in
  let release_first, resolve_release_first = Eio.Promise.create () in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       W.For_testing.start_with_judge
         ~load_candidates
         ~sw
         ~base_path
         ~worker_epoch:(P.Worker_epoch.generate ())
         ~judge:(fun selected ->
           match selected with
           | [ candidate ] when String.equal candidate.A.candidate_id first.candidate_id ->
             Eio.Promise.resolve resolve_first_started ();
             Eio.Promise.await release_first;
             Ok (exact_map selected)
           | _ -> Ok (exact_map selected))
         ());
     within clock (fun () -> await_registered ~base_path);
     ignore (record_candidate ~base_path first : W.record_acceptance);
     within clock (fun () -> Eio.Promise.await first_started);
     let second_acceptance = record_candidate ~base_path second in
     Alcotest.(check bool)
       "active lane retains a pending durable signal"
       true
       (match second_acceptance.signal with
        | W.Signaled | W.Coalesced -> true
        | W.Worker_not_registered | W.No_signal_required -> false);
     Eio.Promise.resolve resolve_release_first ();
     ignore
       (within clock (fun () ->
          await_completed_count ~base_path ~keeper_name ~expected:2)
        : P.t list);
     Alcotest.(check int)
       "candidate committed after snapshot starts a fresh cycle"
       2
       (Atomic.get load_count);
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
            "startup replays Completed owner wake"
            `Quick
            test_startup_replays_completed_owner_wake
        ; Alcotest.test_case
            "delivery failure degrades worker health"
            `Quick
            test_delivery_failure_degrades_worker_health
        ; Alcotest.test_case
            "owner drain rejects partial delivery success"
            `Quick
            test_owner_drain_rejects_partial_delivery_success
        ; Alcotest.test_case
            "injected loader cannot cross Keeper identity"
            `Quick
            test_injected_loader_cannot_cross_keeper_identity
        ; Alcotest.test_case
            "lane cancellation is visible and sibling survives"
            `Quick
            test_lane_cancellation_is_visible_and_sibling_survives
        ; Alcotest.test_case
            "candidate signal does not retry deferred partition"
            `Quick
            test_candidate_signal_does_not_retry_deferred_partition
        ; Alcotest.test_case
            "lane cycle uses one snapshot and continues after defer"
            `Quick
            test_lane_cycle_builds_one_snapshot_and_continues_after_defer
        ; Alcotest.test_case
            "active lane candidate owns the next snapshot"
            `Quick
            test_active_lane_candidate_owns_next_snapshot
        ; Alcotest.test_case
            "placeholder health shape matches live projection"
            `Quick
            test_placeholder_health_shape_matches_live_projection
        ] )
    ]
;;
