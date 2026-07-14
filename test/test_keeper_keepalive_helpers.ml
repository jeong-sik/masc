module Types = Masc_domain

(** Focused tests for keepalive identity reconciliation, directed wake
    selection, directive diagnostics, and status-tick observation shape. *)

open Alcotest
open Masc
module KK = Masc.Keeper_keepalive
let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_temp_workspace f =
  let base_path = Filename.temp_dir "keeper-heartbeat-current-task" "" in
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      ignore (Workspace.init config ~agent_name:None : string);
      f config)

let make_keepalive_meta ~name ~agent_name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String agent_name);
        ("trace_id", `String ("trace-" ^ name));
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error err -> fail ("meta_of_json failed: " ^ err)
  | Ok meta -> meta

let make_in_progress_task ~id ~assignee : Types.task =
  {
    id;
    title = "Heartbeat current task";
    description = "";
    task_status =
      Types.InProgress { assignee; started_at = "2026-06-26T00:00:00Z" };
    priority = 3;
    files = [];
    created_at = "2026-06-26T00:00:00Z";
    created_by = Some "test";
    predecessor_task_id = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = None;
    do_not_reclaim_reason = None;
  }

let test_current_task_id_for_agent_reconciles_from_empty_registry_task () =
  with_temp_workspace (fun config ->
    let keeper_name = "heartbeat-current-task-owner" in
    let agent_name = "keeper-heartbeat-current-task-owner-agent" in
    let task_id = "task-heartbeat-current" in
    let meta = make_keepalive_meta ~name:keeper_name ~agent_name in
    (match Keeper_meta_store.write_meta config meta with
     | Ok () -> ()
     | Error err -> fail ("write_meta failed: " ^ err));
    Workspace.write_backlog config
      {
        Types.tasks = [ make_in_progress_task ~id:task_id ~assignee:agent_name ];
        last_updated = "2026-06-26T00:00:01Z";
        version = 2;
      };
    ignore
      (Keeper_registry.register
         ~base_path:config.Workspace.base_path
         keeper_name
         meta);
    Fun.protect
      ~finally:(fun () ->
        Keeper_registry.unregister ~base_path:config.Workspace.base_path keeper_name)
      (fun () ->
        check string "heartbeat task id" task_id
          (KK.current_task_id_for_agent ~config agent_name);
        let current_from_registry =
          match Keeper_registry.get ~base_path:config.Workspace.base_path keeper_name with
          | Some entry ->
            Keeper_runtime_contract.current_task_id_opt entry.meta
          | None -> None
        in
        check (option string) "registry current task reconciled" (Some task_id)
          current_from_registry;
        let current_from_disk =
          match Keeper_meta_store.read_meta config keeper_name with
          | Ok (Some persisted) ->
            Keeper_runtime_contract.current_task_id_opt persisted
          | Ok None -> None
          | Error err -> fail ("read_meta failed: " ^ err)
        in
        check (option string) "persisted current task reconciled" (Some task_id)
          current_from_disk))

let is_warn_unknown_keeper = function
  | KK.Warn_unknown_keeper -> true
  | KK.Debug_throttled_unknown_keeper -> false

let is_debug_throttled_unknown_keeper = function
  | KK.Debug_throttled_unknown_keeper -> true
  | KK.Warn_unknown_keeper -> false

let test_not_in_registry_warn_due_first_event () =
  check bool "first unknown-keeper directive warns" true
    (KK.not_in_registry_warn_due ~previous:None ~now:1_000.0 ())

let test_not_in_registry_warn_due_throttles_within_window () =
  check bool "same window throttles" false
    (KK.not_in_registry_warn_due
       ~previous:(Some 1_000.0)
       ~now:(1_000.0 +. (KK.not_in_registry_warn_cooldown_s /. 2.0))
       ())

let test_not_in_registry_warn_due_recovers_on_clock_regression () =
  check bool "clock regression does not suppress forever" true
    (KK.not_in_registry_warn_due ~previous:(Some 1_000.0) ~now:999.0 ())

let test_not_in_registry_warn_state_is_per_agent () =
  let open KK in
  let state = StringMap.add "keeper-a-agent" 1_000.0 StringMap.empty in
  let decision_a, _ =
    not_in_registry_warn_state_step
      ~agent_name:"keeper-a-agent"
      ~now:(1_000.0 +. (not_in_registry_warn_cooldown_s /. 2.0))
      state
  in
  let decision_b, updated =
    not_in_registry_warn_state_step
      ~agent_name:"keeper-b-agent"
      ~now:(1_000.0 +. (not_in_registry_warn_cooldown_s /. 2.0))
      state
  in
  check bool "same agent throttled" true
    (is_debug_throttled_unknown_keeper decision_a);
  check bool "different agent warns" true (is_warn_unknown_keeper decision_b);
  check bool "different agent recorded" true
    (Option.is_some (StringMap.find_opt "keeper-b-agent" updated))

let test_not_in_registry_warn_state_is_bounded () =
  let open KK in
  let state =
    List.fold_left
      (fun acc i ->
         StringMap.add
           ("keeper-" ^ string_of_int i ^ "-agent")
           (2_000.0 -. float_of_int i)
           acc)
      StringMap.empty
      [ 0; 1; 2; 3; 4 ]
  in
  let decision, updated =
    not_in_registry_warn_state_step
      ~max_entries:3
      ~agent_name:"keeper-new-agent"
      ~now:2_001.0
      state
  in
  check bool "new unknown keeper still warns" true (is_warn_unknown_keeper decision);
  check int "warn throttle map is capped" 3 (StringMap.cardinal updated);
  check bool "new unknown keeper is retained" true
    (Option.is_some (StringMap.find_opt "keeper-new-agent" updated));
  check bool "oldest unknown keeper is pruned" true
    (Option.is_none (StringMap.find_opt "keeper-4-agent" updated))

module KKS = Masc.Keeper_keepalive_signal
module KWOBS = Masc.Keeper_world_observation_board_signal

let make_board_resume_meta name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("keeper-" ^ name))
      ; ("trace_id", `String ("trace-" ^ name))
      ; ("sandbox_profile", `String "local")
      ; ("network_mode", `String "inherit")
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error err -> fail ("meta_of_json failed: " ^ err)
  | Ok meta -> meta
;;

let test_directed_wake_cuts_configured_sleep () =
  Eio_main.run (fun env ->
    let stop = Atomic.make false in
    let wakeup = Atomic.make true in
    let outcome =
      KKS.interruptible_sleep
        ~clock:(Eio.Stdenv.clock env)
        ~stop
        ~wakeup
        30.0
    in
    check bool "directed wake returns Woken" true
      (match outcome with
       | KKS.Woken -> true
       | KKS.Stopped | KKS.Timeout -> false);
    check bool "wake atomic is consumed" false (Atomic.get wakeup))
;;

let test_explicit_stop_cuts_configured_sleep () =
  Eio_main.run (fun env ->
    let stop = Atomic.make true in
    let wakeup = Atomic.make false in
    let outcome =
      KKS.interruptible_sleep
        ~clock:(Eio.Stdenv.clock env)
        ~stop
        ~wakeup
        30.0
    in
    check bool "explicit stop returns Stopped" true
      (match outcome with
       | KKS.Stopped -> true
       | KKS.Woken | KKS.Timeout -> false))
;;

let test_board_goal_keyword_overlap_is_not_wake_reason () =
  let meta = make_board_resume_meta "keyword-overlap" in
  let signal : Board_dispatch.board_signal =
    { kind = Board_dispatch.Board_post_created
    ; post_id = "post-keyword-overlap"
    ; author = "external-author"
    ; title = "test"
    ; content = "this test overlaps the keeper goal but does not address it"
    ; hearth = None
    ; updated_at = Some 123.0
    }
  in
  match KWOBS.wake_reason ~meta ~signal with
  | KWOBS.Available None -> ()
  | KWOBS.Available (Some reason) ->
    failf "goal keyword overlap woke as %s" (KWOBS.wake_reason_label reason)
  | KWOBS.Unavailable unavailable ->
    failf "Board fixture unavailable: %s" (KWOBS.unavailable_to_string unavailable)

let check_exact_board_mention ~content ~expected =
  let meta = make_board_resume_meta "foo" in
  let signal : Board_dispatch.board_signal =
    { kind = Board_dispatch.Board_post_created
    ; post_id = "post-exact-mention"
    ; author = "external-author"
    ; title = "test"
    ; content
    ; hearth = None
    ; updated_at = Some 123.0
    }
  in
  let matched = KWOBS.match_signal ~meta ~signal in
  check bool content expected matched.explicit_mention

let test_board_mentions_use_exact_typed_keeper_ids () =
  check_exact_board_mention ~content:"@foo please inspect" ~expected:true;
  check_exact_board_mention ~content:"@foobar is a different lane" ~expected:false;
  check_exact_board_mention ~content:"mail foo@example.com" ~expected:false

let persist_and_register_board_lane config meta =
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error detail -> fail ("write_meta failed: " ^ detail));
  ignore
    (Keeper_registry.register
       ~base_path:config.Workspace.base_path
       meta.Keeper_meta_contract.name
       meta)
;;

let board_queue_length config keeper_name =
  Keeper_registry_event_queue.snapshot
    ~base_path:config.Workspace.base_path
    keeper_name
  |> Keeper_event_queue.length
;;

let overwrite_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
;;

let test_exact_mentions_deliver_and_wake_each_lane_independently () =
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.clear
    (fun () ->
       let alpha = make_board_resume_meta "alpha" in
       let beta = make_board_resume_meta "beta" in
       persist_and_register_board_lane config alpha;
       persist_and_register_board_lane config beta;
       let signal : Board_dispatch.board_signal =
         { kind = Board_dispatch.Board_post_created
         ; post_id = "post-multi-lane"
         ; author = "external-author"
         ; title = "addressed"
         ; content = "@alpha @beta inspect independently"
         ; hearth = None
         ; updated_at = Some 123.0
         }
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "alpha durable queue" 1 (board_queue_length config "alpha");
       check int "beta durable queue" 1 (board_queue_length config "beta");
       List.iter
         (fun keeper_name ->
            match Keeper_registry.get ~base_path:config.base_path keeper_name with
            | Some entry ->
              check bool (keeper_name ^ " independently woken") true
                (Atomic.get entry.fiber_wakeup)
            | None -> fail (keeper_name ^ " registry entry missing"))
         [ "alpha"; "beta" ])
;;

let test_paused_exact_mention_is_durable_without_wake () =
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.clear
    (fun () ->
       let meta = make_board_resume_meta "pausedlane" in
       persist_and_register_board_lane config meta;
       (match
          Keeper_registry.dispatch_event
            ~base_path:config.base_path
            meta.name
            Keeper_state_machine.Operator_pause
        with
        | Ok _ -> ()
        | Error _ -> fail "failed to pause Keeper fixture");
       let signal : Board_dispatch.board_signal =
         { kind = Board_dispatch.Board_post_created
         ; post_id = "post-paused-lane"
         ; author = "external-author"
         ; title = "addressed"
         ; content = "@pausedlane retain this"
         ; hearth = None
         ; updated_at = Some 124.0
         }
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "paused durable queue" 1 (board_queue_length config meta.name);
       match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some entry ->
         check bool "paused lane wake hint remains false" false
           (Atomic.get entry.fiber_wakeup)
       | None -> fail "paused registry entry missing")
;;

let test_restarting_exact_mention_is_durable_with_deferred_wake () =
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.clear
    (fun () ->
       let meta = make_board_resume_meta "restartlane" in
       (match Keeper_meta_store.write_meta config meta with
        | Ok () -> ()
        | Error detail -> fail ("write_meta failed: " ^ detail));
       (match
          Keeper_registry.register_restarting
            ~base_path:config.base_path
            meta.name
            meta
        with
        | Ok _ -> ()
        | Error _ -> fail "failed to register Restarting Keeper fixture");
       let signal : Board_dispatch.board_signal =
         { kind = Board_dispatch.Board_post_created
         ; post_id = "post-restarting-lane"
         ; author = "external-author"
         ; title = "addressed"
         ; content = "@restartlane retain this while relaunching"
         ; hearth = None
         ; updated_at = Some 124.5
         }
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "Restarting durable queue" 1
         (board_queue_length config meta.name);
       match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some entry ->
         check bool "Restarting lane keeps deferred wake hint" false
           (Atomic.get entry.fiber_wakeup)
       | None -> fail "Restarting registry entry missing")
;;

let test_lane_meta_failure_does_not_block_next_durable_delivery () =
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.clear
    (fun () ->
       let broken = make_board_resume_meta "zzzbroken" in
       let healthy = make_board_resume_meta "aaahealthy" in
       persist_and_register_board_lane config broken;
       persist_and_register_board_lane config healthy;
       (match Keeper_registry.all ~base_path:config.base_path () with
        | first :: _ ->
          check string "fixture processes failing lane first" broken.name first.name
        | [] -> fail "lane-isolation registry fixture is empty");
       overwrite_file
         (Keeper_types_profile.keeper_meta_path config broken.name)
         "{ malformed Keeper metadata";
       let signal : Board_dispatch.board_signal =
         { kind = Board_dispatch.Board_post_created
         ; post_id = "post-lane-isolation"
         ; author = "external-author"
         ; title = "addressed"
         ; content = "@zzzbroken @aaahealthy inspect independently"
         ; hearth = None
         ; updated_at = Some 125.0
         }
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "unreadable lane has no queued signal" 0
         (board_queue_length config broken.name);
       check int "next lane receives durable signal" 1
         (board_queue_length config healthy.name))
;;

(* ── Test runner ─── *)

let () =
  run
    "keeper keepalive helpers"
    [ ( "current_task_reconciliation"
      , [ test_case
            "heartbeat reconciles empty current_task_id from active backlog"
            `Quick
            test_current_task_id_for_agent_reconciles_from_empty_registry_task
        ] )
    ; ( "directive_orphan_warn_gate"
      , [ test_case "first unknown keeper directive warns" `Quick
            test_not_in_registry_warn_due_first_event
        ; test_case "same unknown keeper is throttled within window" `Quick
            test_not_in_registry_warn_due_throttles_within_window
        ; test_case "clock regression does not suppress forever" `Quick
            test_not_in_registry_warn_due_recovers_on_clock_regression
        ; test_case "warn gate is per agent" `Quick
            test_not_in_registry_warn_state_is_per_agent
        ; test_case "warn gate state is bounded" `Quick
            test_not_in_registry_warn_state_is_bounded
        ] )
    ; ( "board_signal_delivery"
      , [ test_case "goal keyword overlap is not a wake reason" `Quick
            test_board_goal_keyword_overlap_is_not_wake_reason
        ; test_case "mentions use exact typed Keeper ids" `Quick
            test_board_mentions_use_exact_typed_keeper_ids
        ; test_case "exact mentions deliver and wake every lane" `Quick
            test_exact_mentions_deliver_and_wake_each_lane_independently
        ; test_case "paused exact mention is durable without wake" `Quick
            test_paused_exact_mention_is_durable_without_wake
        ; test_case "Restarting exact mention is durable with deferred wake" `Quick
            test_restarting_exact_mention_is_durable_with_deferred_wake
        ; test_case "lane metadata failure does not block next durable delivery" `Quick
            test_lane_meta_failure_does_not_block_next_durable_delivery
        ] )
    ; ( "interruptible_cadence"
      , [ test_case "directed wake cuts configured sleep" `Quick
            test_directed_wake_cuts_configured_sleep
        ; test_case "explicit stop cuts configured sleep" `Quick
            test_explicit_stop_cuts_configured_sleep
        ] )
    ]
;;
