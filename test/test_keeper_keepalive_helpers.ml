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
        ("goal", `String "test");
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

(* Compare selected wake reasons by their stable label so the typed variant
   stays printable in Alcotest's (string) testable. *)
let reason_label = KWOBS.wake_reason_label
let labeled selected = List.map (fun (item, r) -> item, reason_label r) selected

let make_board_resume_meta name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("keeper-" ^ name))
      ; ("trace_id", `String ("trace-" ^ name))
      ; ("goal", `String "test")
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

let test_board_wakeup_selection_keeps_explicit_mentions () =
  let selected, deferred =
    KKS.select_board_wakeup_candidates
      [
        "a", Some KWOBS.Thread_reply_after_self_comment;
        "b", Some KWOBS.Explicit_mention;
        "c", Some KWOBS.Explicit_mention;
      ]
  in
  (* Explicit mentions short-circuit the WAKE; the shadowed followup is
     deferred to its mailbox, not discarded (RFC-0334 W1). *)
  check (list (pair string string)) "selected explicit wakeups"
    [ "b", "explicit_mention"; "c", "explicit_mention" ]
    (labeled selected);
  check (list (pair string string)) "shadowed followup deferred, not dropped"
    [ "a", "thread_reply_after_self_comment" ]
    (labeled deferred)

let test_board_wakeup_selection_drops_none_reasons () =
  let selected, deferred =
    KKS.select_board_wakeup_candidates
      [
        "a", Some KWOBS.Thread_reply_after_self_comment;
        "b", None;
        "c", None;
      ]
  in
  (* [None] reasons (no deterministic address) receive nothing — neither a
     wake nor a mailbox delivery; structural followup reasons survive in
     candidate order. *)
  check (list (pair string string)) "None dropped, real reasons kept"
    [ "a", "thread_reply_after_self_comment" ]
    (labeled selected);
  check (list (pair string string)) "nothing deferred under the limit" []
    (labeled deferred)

let test_board_wakeup_selection_caps_thread_followups () =
  let selected, deferred =
    KKS.select_board_wakeup_candidates
      ~total_limit:2
      [
        "a", Some KWOBS.Thread_reply_after_self_comment;
        "b", Some KWOBS.Thread_reply_after_self_comment;
        "c", Some KWOBS.Thread_reply_after_self_comment;
        "d", Some KWOBS.Thread_reply_after_self_comment;
      ]
  in
  (* Thread followups compete for [total_limit] immediate-wake slots in
     candidate order; the overflow is deferred to mailboxes with its reasons
     intact (RFC-0334 W1: the cap bounds wakes, not delivery). *)
  check (list (pair string string)) "first two non-explicit kept in order"
    [ "a", "thread_reply_after_self_comment"; "b", "thread_reply_after_self_comment" ]
    (labeled selected);
  check (list (pair string string)) "overflow deferred in order with reasons"
    [ "c", "thread_reply_after_self_comment"; "d", "thread_reply_after_self_comment" ]
    (labeled deferred)

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
  check (option string) "goal keyword overlap no longer wakes" None
    (Option.map KWOBS.wake_reason_label
       (KWOBS.wake_reason ~meta ~signal))

let test_status_tick_usage_json_includes_cache_fields () =
  let usage = KK.status_tick_usage_json () in
  let int_member key =
    match usage with
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Int value) -> value
        | _ -> fail (key ^ " should be int"))
    | _ -> fail "usage should be object"
  in
  check int "input zero" 0 (int_member "input_tokens");
  check int "output zero" 0 (int_member "output_tokens");
  check int "cache creation zero" 0
    (int_member "cache_creation_tokens");
  check int "cache read zero" 0
    (int_member "cache_read_tokens");
  check int "total zero" 0 (int_member "total_tokens")

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
    ; ( "board_wakeup_selection"
      , [ test_case "explicit mentions bypass and win" `Quick
            test_board_wakeup_selection_keeps_explicit_mentions
        ; test_case "None reasons are dropped, real reasons kept" `Quick
            test_board_wakeup_selection_drops_none_reasons
        ; test_case "thread followup fanout is capped" `Quick
            test_board_wakeup_selection_caps_thread_followups
        ; test_case "goal keyword overlap is not a wake reason" `Quick
            test_board_goal_keyword_overlap_is_not_wake_reason
        ] )
    ; ( "interruptible_cadence"
      , [ test_case "directed wake cuts configured sleep" `Quick
            test_directed_wake_cuts_configured_sleep
        ; test_case "explicit stop cuts configured sleep" `Quick
            test_explicit_stop_cuts_configured_sleep
        ] )
    ; ( "status_tick_usage"
      , [ test_case "status tick usage preserves cache fields" `Quick
            test_status_tick_usage_json_includes_cache_fields
        ] )
    ]
;;
