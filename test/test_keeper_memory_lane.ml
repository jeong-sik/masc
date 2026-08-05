(** Tests for Keeper_memory_lane (RFC-0257).

    The lane detaches post-turn memory work from the keeper turn lane:
    serialized within a keeper, independent across keepers, bounded, and
    leak-safe on a raising unit. *)

module Lane = Masc.Keeper_memory_lane
module Librarian_runtime = Masc.Keeper_librarian_runtime
module Memory_current = Masc.Keeper_memory_os_current
module Post_turn_memory = Masc.Keeper_agent_run_post_turn_memory

exception Test_boom
exception Cancel_lane_test

let base_path = Filename.concat (Filename.get_temp_dir_name ()) "test-memory-lane"

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name ])
  with
  | Ok meta -> meta
  | Error detail -> Alcotest.failf "keeper meta fixture failed: %s" detail
;;

let run_post_turn ~config ~meta ~turn =
  Post_turn_memory.run
    ~config
    ~meta
    ~generation:turn
    ~profile_defaults:
      Masc.Keeper_types_profile_defaults.empty_keeper_profile_defaults
    ~turn
    ~oas_turn_count:1
    ~actual_tools:[]
    ~librarian_messages:[]
    ~post_turn_t0:(Time_compat.now ())
    ~inference_telemetry:None
    ()
;;

(* No executor switch set -> submit runs inline so no work is lost. *)
let test_inline_when_uninitialized () =
  Lane.For_testing.reset ();
  let ran = ref false in
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> ran := true)
  in
  Alcotest.(check bool) "unit ran inline" true !ran;
  match outcome with
  | Lane.Ran_inline -> ()
  | Lane.Submitted -> Alcotest.fail "expected Ran_inline, got Submitted"
  | Lane.Coalesced -> Alcotest.fail "expected Ran_inline, got Coalesced"
  | Lane.Dropped -> Alcotest.fail "expected Ran_inline, got Dropped"
;;

(* A raising unit in the inline path is contained and returns Ran_inline. *)
let test_inline_contains_raise () =
  Lane.For_testing.reset ();
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> raise Test_boom)
  in
  match outcome with
  | Lane.Ran_inline -> ()
  | Lane.Submitted -> Alcotest.fail "expected Ran_inline, got Submitted"
  | Lane.Coalesced -> Alcotest.fail "expected Ran_inline, got Coalesced"
  | Lane.Dropped -> Alcotest.fail "expected Ran_inline, got Dropped"
;;

(* Two units for the same keeper run one after another: the second only starts
   after the first releases the keeper's mutex. *)
let test_serializes_within_keeper () =
  Lane.For_testing.reset ();
  let order = ref [] in
  let add s = order := s :: !order in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_started, set_started = Eio.Promise.create () in
      let p_release, set_release = Eio.Promise.create () in
      let oa =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          add "a-start";
          Eio.Promise.resolve set_started ();
          Eio.Promise.await p_release;
          add "a-end")
      in
      Eio.Promise.await p_started;
      let ob =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> add "b")
      in
      (* Let B attempt (and fail) to acquire the keeper mutex held by A. *)
      Eio.Fiber.yield ();
      add "before-release";
      Eio.Promise.resolve set_release ();
      (match oa with
       | Lane.Submitted -> ()
       | _ -> Alcotest.fail "unit A not submitted");
      match ob with
      | Lane.Submitted -> ()
      | _ -> Alcotest.fail "unit B not submitted"));
  Alcotest.(check (list string))
    "B serialized behind A"
    [ "a-start"; "before-release"; "a-end"; "b" ]
    (List.rev !order)
;;

(* A unit for one keeper does not block a unit for another keeper. *)
let test_independent_across_keepers () =
  Lane.For_testing.reset ();
  let order = ref [] in
  let add s = order := s :: !order in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_started, set_started = Eio.Promise.create () in
      let p_release, set_release = Eio.Promise.create () in
      let _ =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await p_release;
          add "k1")
      in
      Eio.Promise.await p_started;
      let _ =
        Lane.submit ~base_path ~keeper_name:"k2" ~lane:Lane.Librarian (fun () -> add "k2")
      in
      (* k2 runs to completion while k1 is still holding its own lane. *)
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      Alcotest.(check bool) "k2 ran while k1 blocked" true (List.mem "k2" !order);
      Eio.Promise.resolve set_release ()));
  Alcotest.(check (list string)) "k2 before k1" [ "k2"; "k1" ] (List.rev !order)
;;

(* The deterministic lane retains its existing bounded-drop policy. *)
let test_deterministic_saturation_drops () =
  Lane.For_testing.reset ();
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_release, set_release = Eio.Promise.create () in
      let o1 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Deterministic (fun () ->
          Eio.Promise.await p_release)
      in
      let o2 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Deterministic (fun () -> ())
      in
      let o3 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Deterministic (fun () -> ())
      in
      (match o1 with
       | Lane.Submitted -> ()
       | _ -> Alcotest.fail "o1 not submitted");
      (match o2 with
       | Lane.Submitted -> ()
       | _ -> Alcotest.fail "o2 not submitted");
      (match o3 with
       | Lane.Dropped -> ()
       | Lane.Submitted -> Alcotest.fail "o3 should be Dropped, got Submitted"
       | Lane.Coalesced -> Alcotest.fail "deterministic lane must not coalesce"
       | Lane.Ran_inline -> Alcotest.fail "o3 should be Dropped, got Ran_inline");
      Eio.Promise.resolve set_release ()))
;;

(* Librarian saturation keeps one running unit and one overwriteable latest
   snapshot. Every submit returns immediately; only the newest pending snapshot
   evaluates after the blocker. *)
let test_librarian_saturation_coalesces_latest () =
  Lane.For_testing.reset ();
  let evaluated = ref [] in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let running =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release;
          evaluated := "running" :: !evaluated)
      in
      Eio.Promise.await started;
      let snapshot trace generation messages () =
        evaluated :=
          Printf.sprintf "%s:%d:%s" trace generation (String.concat "," messages)
          :: !evaluated
      in
      let stale =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian
          (snapshot "trace-stale" 1 [ "stale" ])
      in
      let newer =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian
          (snapshot "trace-newer" 2 [ "newer" ])
      in
      let newest =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian
          (snapshot "trace-newest" 3 [ "newest-a"; "newest-b" ])
      in
      (match running, stale, newer, newest with
       | Lane.Submitted, Lane.Submitted, Lane.Coalesced, Lane.Coalesced -> ()
       | _ -> Alcotest.fail "unexpected Librarian coalescing outcomes");
      (match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
       | Some 2 -> ()
       | Some n -> Alcotest.failf "running+latest bound should be 2, got %d" n
       | None -> Alcotest.fail "missing Librarian lane entry");
      Eio.Promise.resolve set_release ()));
  Alcotest.(check (list string))
    "only running and newest snapshot evaluate"
    [ "running"; "trace-newest:3:newest-a,newest-b" ]
    (List.rev !evaluated);
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked after coalesced drain: %d" n
  | None -> Alcotest.fail "Librarian lane entry missing"
;;

(* The regression this split exists for: a saturated librarian lane must not
   consume the deterministic lane's budget. A librarian unit parked in a
   provider round trip plus one queued behind it fills the librarian lane, and
   the deterministic write — one-shot, no retry — must still be admitted and
   must run while the librarian is still blocked. Before the split both kinds
   shared one budget, so this deterministic unit was dropped: measured live on
   2026-07-20 at 220 drops fleet-wide, keeper `analyst` losing 144 of 280. *)
let test_lanes_have_independent_budgets () =
  Lane.For_testing.reset ();
  let det_ran = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_release, set_release = Eio.Promise.create () in
      let lib1 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          Eio.Promise.await p_release)
      in
      let lib2 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> ())
      in
      let lib3 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> ())
      in
      let det =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Deterministic (fun () ->
          det_ran := true)
      in
      (match lib1, lib2 with
       | Lane.Submitted, Lane.Submitted -> ()
       | _ -> Alcotest.fail "librarian lane should admit two units");
      (match lib3 with
       | Lane.Coalesced -> ()
       | _ -> Alcotest.fail "librarian lane should coalesce at the bound");
      (match det with
       | Lane.Submitted -> ()
       | Lane.Coalesced ->
         Alcotest.fail "deterministic unit must not use Librarian coalescing"
       | Lane.Dropped ->
         Alcotest.fail "deterministic unit dropped by a saturated librarian lane"
       | Lane.Ran_inline -> Alcotest.fail "deterministic unit ran inline");
      (* Still blocked on the librarian round trip; the deterministic write must
         not be waiting behind it. *)
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      Alcotest.(check bool)
        "deterministic write ran while librarian was in flight"
        true
        !det_ran;
      Eio.Promise.resolve set_release ()))
;;

(* A unit that raises releases the mutex and the pending slot, so the lane
   recovers and later units run. *)
let test_releases_on_raise () =
  Lane.For_testing.reset ();
  let latest_ran = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let first =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release;
          raise Test_boom)
      in
      Eio.Promise.await started;
      let latest =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          latest_ran := true)
      in
      (match first, latest with
       | Lane.Submitted, Lane.Submitted -> ()
       | _ -> Alcotest.fail "raise fixture submissions were not accepted");
      Eio.Promise.resolve set_release ()));
  Alcotest.(check bool) "latest runs after raising unit" true !latest_ran;
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked: %d" n
  | None -> Alcotest.fail "keeper entry missing"
;;

(* Cancellation during shutdown releases both the mutex and the pending slot. *)
let test_releases_on_cancel () =
  Lane.For_testing.reset ();
  let latest_ran = ref false in
  (try
     Eio_main.run (fun _env ->
       Eio.Switch.run (fun sw ->
         Lane.init ~sw;
         let started, set_started = Eio.Promise.create () in
         let never, _set_never = Eio.Promise.create () in
         let outcome =
           Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
             Eio.Promise.resolve set_started ();
             Eio.Promise.await never)
         in
         let latest =
           Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
             latest_ran := true)
         in
         (match outcome with
          | Lane.Submitted -> ()
          | Lane.Coalesced -> Alcotest.fail "first cancel unit unexpectedly coalesced"
          | Lane.Ran_inline -> Alcotest.fail "cancel test unexpectedly ran inline"
          | Lane.Dropped -> Alcotest.fail "cancel test unexpectedly dropped");
         (match latest with
          | Lane.Submitted -> ()
          | Lane.Coalesced -> Alcotest.fail "first latest unit unexpectedly coalesced"
         | Lane.Ran_inline -> Alcotest.fail "latest cancel unit unexpectedly ran inline"
          | Lane.Dropped -> Alcotest.fail "latest cancel unit unexpectedly dropped");
         Eio.Promise.await started;
         Eio.Switch.fail sw Cancel_lane_test))
   with
   | Cancel_lane_test -> ());
  Alcotest.(check bool) "latest did not run after switch cancel" false !latest_ran;
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked after cancel: %d" n
  | None -> Alcotest.fail "keeper entry missing after cancel"
;;

(* Submitting against a finished executor switch must not leak the pending
   reservation. Eio.Fiber.fork does not raise to the caller for an off switch, so
   the lane needs its own executor-switch release fallback. *)
let test_finished_switch_drops_without_leak () =
  Lane.For_testing.reset ();
  let finished_sw = ref None in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      finished_sw := Some sw));
  let sw =
    match !finished_sw with
    | Some sw -> sw
    | None -> Alcotest.fail "missing captured switch"
  in
  Lane.init ~sw;
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> raise Test_boom)
  in
  (match outcome with
   | Lane.Dropped -> ()
   | Lane.Submitted -> Alcotest.fail "expected Dropped, got Submitted"
   | Lane.Coalesced -> Alcotest.fail "expected Dropped, got Coalesced"
   | Lane.Ran_inline -> Alcotest.fail "expected Dropped, got Ran_inline");
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked after finished switch submit: %d" n
  | None -> Alcotest.fail "keeper entry missing after finished switch submit"
;;

(* The Librarian setting is live while lane work is asynchronous. The
   post-turn entrypoint must reject OFF/INVALID before submission, then fence
   an already queued ON unit again before snapshot I/O when the setting changes
   while it waits behind an in-flight unit. *)
let test_post_turn_librarian_live_config_boundaries () =
  Lane.For_testing.reset ();
  let root = temp_dir "test-post-turn-librarian-gate-" in
  let env_key = Env_config.KeeperMemoryOs.librarian_env_key in
  let previous_env = Sys.getenv_opt env_key in
  Fun.protect
    ~finally:(fun () ->
      (match previous_env with
       | Some value -> Unix.putenv env_key value
       | None -> Unix.putenv env_key "");
      Config_dir_resolver.reset ();
      Lane.For_testing.reset ();
      remove_tree root)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Masc_test_deps.init_eio_clock env;
      let config = Masc.Workspace.default_config root in
      ignore (Masc.Workspace.init config ~agent_name:None);
      Config_dir_resolver.reset ();
      let failure_metric =
        Keeper_metrics.(to_string MemoryOsLibrarianFailures)
      in
      let failures_before =
        Masc.Otel_metric_store.metric_total failure_metric |> int_of_float
      in
      let cadence_entries_before =
        Librarian_runtime.cadence_counter_entries ()
      in
      let expect_no_admission ~value ~keeper_name ~turn =
        Unix.putenv env_key value;
        let meta = make_meta keeper_name in
        run_post_turn ~config ~meta ~turn;
        match
          Lane.For_testing.pending
            ~base_path:config.base_path
            ~keeper_name
            ~lane:Lane.Librarian
        with
        | None -> ()
        | Some pending ->
          Alcotest.failf
            "config=%s created Librarian lane pending=%d"
            value
            pending
      in
      expect_no_admission ~value:"false" ~keeper_name:"gateoff" ~turn:1;
      expect_no_admission ~value:"invalid" ~keeper_name:"gateinvalid" ~turn:2;
      let expect_queued_fence ~poison_snapshot ~terminal_value ~keeper_name ~turn =
        Lane.For_testing.reset ();
        Eio.Switch.run @@ fun sw ->
        Masc_test_deps.init_eio_clock ~sw env;
        Lane.init ~sw;
        let meta = make_meta keeper_name in
        let keepers_dir =
          Config_dir_resolver.keepers_dir_for_base_path
            ~base_path:config.base_path
        in
        if poison_snapshot
        then (
          Fs_compat.mkdir_p keepers_dir;
          Unix.mkdir
            (Memory_current.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name)
            0o755);
        Unix.putenv env_key "true";
        let started, set_started = Eio.Promise.create () in
        let release, set_release = Eio.Promise.create () in
        let blocker =
          Lane.submit
            ~base_path:config.base_path
            ~keeper_name
            ~lane:Lane.Librarian
            (fun () ->
               Eio.Promise.resolve set_started ();
               Eio.Promise.await release)
        in
        (match blocker with
         | Lane.Submitted -> ()
         | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped ->
           Alcotest.fail "Librarian blocker was not submitted");
        Eio.Promise.await started;
        run_post_turn ~config ~meta ~turn;
        Alcotest.(check (option int))
          "one running plus one queued Librarian unit"
          (Some 2)
          (Lane.For_testing.pending
             ~base_path:config.base_path
             ~keeper_name
             ~lane:Lane.Librarian);
        Unix.putenv env_key terminal_value;
        Eio.Promise.resolve set_release ()
      in
      expect_queued_fence
        ~poison_snapshot:true
        ~terminal_value:"false"
        ~keeper_name:"queuedoff"
        ~turn:3;
      expect_queued_fence
        ~poison_snapshot:false
        ~terminal_value:"invalid"
        ~keeper_name:"queuedinvalid"
        ~turn:4;
      Alcotest.(check int)
        "fenced work did not read invalid snapshots or emit failures"
        failures_before
        (Masc.Otel_metric_store.metric_total failure_metric |> int_of_float);
      Alcotest.(check int)
        "fenced work did not advance Librarian cadence"
        cadence_entries_before
        (Librarian_runtime.cadence_counter_entries ()))
;;

let () =
  Alcotest.run
    "keeper_memory_lane"
    [ ( "lane"
      , [ Alcotest.test_case
            "inline when uninitialized"
            `Quick
            test_inline_when_uninitialized
        ; Alcotest.test_case
            "inline contains raise"
            `Quick
            test_inline_contains_raise
        ; Alcotest.test_case
            "serializes within keeper"
            `Quick
            test_serializes_within_keeper
        ; Alcotest.test_case
            "independent across keepers"
            `Quick
            test_independent_across_keepers
        ; Alcotest.test_case
            "deterministic saturation drops"
            `Quick
            test_deterministic_saturation_drops
        ; Alcotest.test_case
            "librarian saturation coalesces latest"
            `Quick
            test_librarian_saturation_coalesces_latest
        ; Alcotest.test_case
            "lanes have independent budgets"
            `Quick
            test_lanes_have_independent_budgets
        ; Alcotest.test_case "releases on raise" `Quick test_releases_on_raise
        ; Alcotest.test_case "releases on cancel" `Quick test_releases_on_cancel
        ; Alcotest.test_case
            "finished switch drops without leak"
            `Quick
            test_finished_switch_drops_without_leak
        ; Alcotest.test_case
            "post-turn Librarian live config boundaries"
            `Quick
            test_post_turn_librarian_live_config_boundaries
        ] )
    ]
;;
