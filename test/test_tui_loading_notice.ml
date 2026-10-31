open Alcotest
module Types = Masc_tui_types

(* What the keeper detail tabs say while a read is in flight.

   The seconds are the point: against a live server the Sandbox tab's status
   took somewhere between five and sixteen seconds, and a bare "(loading...)"
   held through that window is read as a stall -- the operator starts pressing
   keys. A read that answers at once must not flash a number, which is what the
   floor is for. *)

let fresh () =
  Types.create_state ~workspace:"me" ~port:8935 ~refresh_interval:2.0 ()

let second = 1_000_000_000L
let ns seconds = Int64.mul (Int64.of_int seconds) second

let test_the_elapsed_needs_a_start () =
  check (option int) "a read nobody asked for measures nothing" None
    (Types.pending_elapsed_s ~now_ns:(ns 100) None);
  check (option int) "ten seconds since this read began" (Some 10)
    (Types.pending_elapsed_s ~now_ns:(ns 100) (Some (ns 90)));
  check (option int) "whole seconds, so a part of one is none of one" (Some 0)
    (Types.pending_elapsed_s ~now_ns:(Int64.add (ns 90) 999_999_999L)
       (Some (ns 90)))

let start state ~tab ~keeper ~now_ns =
  ignore (Types.mark_detail_read_started state ~tab ~keeper ~now_ns)

let test_a_background_read_does_not_reset_the_visible_one () =
  (* The operator opens Sandbox, walks to Settings, and an Identity refresh
     finishes behind them and launches its own read. One stamp for the screen
     was rewritten by that read, so the tab on screen reported an elapsed time
     for a request that never restarted. *)
  let state = fresh () in
  start state ~tab:Types.Detail_instructions
    ~keeper:"analyst" ~now_ns:(ns 10);
  start state ~tab:Types.Detail_identity
    ~keeper:"analyst" ~now_ns:(ns 99);
  state.detail_tab <- Types.Detail_instructions;
  check (option int) "the tab on screen keeps its own start" (Some 90)
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state ~tab:state.detail_tab ~keeper:"analyst"));
  check (option int) "and the one that finished behind it keeps its own" (Some 1)
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state ~tab:Types.Detail_identity
          ~keeper:"analyst"));
  check (option int) "a tab nobody asked for measures nothing" None
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state ~tab:Types.Detail_sandbox ~keeper:"analyst"));
  (* Asking again does not restart the count. The Identity tab polls while an
     OAuth attachment settles, and the wait being measured is the operator's,
     which those polls do not interrupt. *)
  start state ~tab:Types.Detail_instructions
    ~keeper:"analyst" ~now_ns:(ns 96);
  check (option int) "asking again keeps the first start" (Some 90)
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state ~tab:Types.Detail_instructions
          ~keeper:"analyst"))

let test_the_wait_ends_when_the_answer_arrives () =
  (* A terminal response ends the wait; a new ask starts a new interval. *)
  let state = fresh () in
  start state ~tab:Types.Detail_identity
    ~keeper:"analyst" ~now_ns:(ns 10);
  check (option int) "waiting" (Some 90)
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state ~tab:Types.Detail_identity
          ~keeper:"analyst"));
  let request = Option.get
      (Types.pending_detail_read state ~tab:Types.Detail_identity ~keeper:"analyst") in
  check bool "the terminal answer retires its wait" true
    (Types.finish_detail_read state request);
  check (option int) "answered, so nothing is being waited for" None
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state ~tab:Types.Detail_identity
          ~keeper:"analyst"));
  start state ~tab:Types.Detail_identity
    ~keeper:"analyst" ~now_ns:(ns 100);
  check (option int) "and the next wait starts from the next ask" (Some 0)
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state ~tab:Types.Detail_identity
          ~keeper:"analyst"))

let test_the_same_tab_for_two_keepers_is_timed_apart () =
  (* Identity_switch_set relaunches the Identity read for whichever Keeper's
     switch landed, which need not be the selected one. Keyed by tab alone, that
     launch rewrote the stamp the selected Keeper's pending read was counting
     from, and its row restarted at the newer read's start. *)
  let state = fresh () in
  start state ~tab:Types.Detail_identity
    ~keeper:"analyst" ~now_ns:(ns 10);
  start state ~tab:Types.Detail_identity
    ~keeper:"polisher" ~now_ns:(ns 99);
  let now_ns = ns 100 in
  check (option int) "the Keeper on screen keeps its own start" (Some 90)
    (Types.pending_elapsed_s ~now_ns
       (Types.detail_read_started state ~tab:Types.Detail_identity
          ~keeper:"analyst"));
  check (option int) "and the one that landed behind it keeps its own" (Some 1)
    (Types.pending_elapsed_s ~now_ns
       (Types.detail_read_started state ~tab:Types.Detail_identity
          ~keeper:"polisher"));
  check (option int) "a Keeper nobody read for measures nothing" None
    (Types.pending_elapsed_s ~now_ns
       (Types.detail_read_started state ~tab:Types.Detail_identity
          ~keeper:"critic"))

let test_two_reads_are_timed_apart () =
  (* The Sandbox tab's status and its container logs are two reads, and the
     operator presses o/l long after the status landed. Sharing one stamp made
     a log read that had just started claim the status read's minutes. *)
  let state = fresh () in
  start state ~tab:Types.Detail_sandbox ~keeper:"analyst" ~now_ns:(ns 10);
  state.keeper_sandbox_logs_inflight <-
    Some
      { Types.slr_keeper = "analyst"
      ; slr_generation = 3
      ; slr_started_ns = ns 98
      };
  let now_ns = ns 100 in
  check (option int) "the tab read has been waiting ninety seconds" (Some 90)
    (Types.pending_elapsed_s ~now_ns
       (Types.detail_read_started state ~tab:Types.Detail_sandbox ~keeper:"analyst"));
  let logs_started =
    Option.map
      (fun (request : Types.sandbox_logs_request) -> request.slr_started_ns)
      state.keeper_sandbox_logs_inflight
  in
  check (option int) "and the log read, two" (Some 2)
    (Types.pending_elapsed_s ~now_ns logs_started)

let test_offscreen_completion_and_late_poll_do_not_age_a_new_wait () =
  List.iter (fun tab ->
    let state = fresh () in
    let first = Types.mark_detail_read_started state ~tab ~keeper:"analyst"
        ~now_ns:(ns 10) in
    let poll = Types.mark_detail_read_started state ~tab ~keeper:"analyst"
        ~now_ns:(ns 12) in
    check bool "an explicit reread supersedes the previous response" true
      (first.drr_generation <> poll.drr_generation);
    check bool "a superseded response cannot finish the outstanding read" false
      (Types.finish_detail_read state first);
    check (option int) "rereading does not reset accumulated elapsed time" (Some 3)
      (Types.pending_elapsed_s ~now_ns:(ns 13)
         (Types.detail_read_started state ~tab ~keeper:"analyst"));
    (* Completion is independent of the current tab, Keeper, or visible view.
       Both success and error callbacks use it before checking selection. *)
    state.view <- Types.Overview;
    check bool "an offscreen terminal response still retires the wait" true
      (Types.finish_detail_read state poll);
    let fresh = Types.mark_detail_read_started state ~tab ~keeper:"analyst"
        ~now_ns:(ns 100) in
    check bool "reopening creates a different wait" true
      (fresh.drr_generation <> first.drr_generation);
    check bool "a late answer from the old poll cannot end the new wait" false
      (Types.finish_detail_read state poll);
    check (option int) "the new wait has its own elapsed time" (Some 2)
      (Types.pending_elapsed_s ~now_ns:(ns 102)
         (Types.detail_read_started state ~tab ~keeper:"analyst"));
    check bool "only the new wait may finish" true
      (Types.finish_detail_read state fresh);
    check bool "duplicate terminal delivery is ignored" false
      (Types.finish_detail_read state fresh))
    [Types.Detail_instructions; Types.Detail_sandbox; Types.Detail_github;
     Types.Detail_identity; Types.Detail_automation]

let test_logs_keep_repainting_after_status_arrives () =
  let state = fresh () in
  let status = Types.mark_detail_read_started state ~tab:Types.Detail_sandbox
      ~keeper:"analyst" ~now_ns:(ns 10) in
  ignore (Types.finish_detail_read state status);
  state.keeper_sandbox_logs_inflight <- Some
    { Types.slr_keeper = "analyst"; slr_generation = 2; slr_started_ns = ns 20 };
  check bool "matching logs need timed repaints without a status request" true
    (Types.detail_read_waiting state ~tab:Types.Detail_sandbox ~keeper:"analyst");
  check bool "another Keeper's logs do not animate this tab" false
    (Types.detail_read_waiting state ~tab:Types.Detail_sandbox ~keeper:"polisher");
  check bool "hidden Sandbox logs do not animate Identity" false
    (Types.detail_read_waiting state ~tab:Types.Detail_identity ~keeper:"analyst");
  state.keeper_sandbox_logs_inflight <- None;
  check bool "finished logs stop requesting repaints" false
    (Types.detail_read_waiting state ~tab:Types.Detail_sandbox ~keeper:"analyst")

let test_schedule_responses_follow_keeper_and_generation () =
  let keeper name : Types.keeper =
    { k_origin = Masc.Tui_decode.Persisted_keeper; k_name = name
    ; k_paused = false
    ; k_identity = Ok { k_trace_id = "trace"; k_created_at = ""; k_updated_at = "" }
    ; k_activity = Some
        { k_current_task_id = None; k_total_turns = 0; k_total_tokens = 0
        ; k_total_cost_usd = Keeper_cost_coverage.empty; k_last_turn_ts = ""; k_last_proactive_outcome = None } }
  in
  let snapshot count : Types.schedule_snapshot =
    { scs_status = "ok"; scs_read_error = None; scs_request_count = Some count
    ; scs_truncated = false; scs_payload_target = None
    ; scs_paging = Schedule_paging_unavailable; scs_next_due_iso = None; scs_counts = None
    ; scs_rows = []; scs_observed_at_iso = "2026-10-26T08:59:00Z"
         ; scs_runner_status = Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_ok }
  in
  let state = fresh () in
  (* A schedule page is applied only under a ready server identity
     (server_authority_ready); the case here is the Keeper and generation
     check, so the server has answered for its workspace. *)
  state.server_identity <- Some
    { Masc.Tui_decode.sid_version = "test"; sid_binary_commit = "test"
    ; sid_binary_commit_age_s = None; sid_base_path = Masc.Tui_decode.Canonical_path.of_path "/workspace"
    ; sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "/workspace/.masc"; sid_executable_in_worktree = None
    ; sid_state_ready = Some true; sid_uptime = None; sid_sse_clients = None
    ; sid_gc = None; sid_scheduler = None };
  state.keepers <- [keeper "alpha"; keeper "beta"];
  let ask name = Types.mark_detail_read_started state
    ~tab:Types.Detail_automation ~keeper:name ~now_ns:(ns 10) in
  let apply detail result =
    Types.apply_keeper_schedules_read state
      { kspr_detail = detail; kspr_page = Types.schedule_first_page;
        kspr_navigation = false; kspr_scroll = 0 } result in
  let alpha = ask "alpha" in
  state.keeper_cursor <- 1;
  let beta = ask "beta" in
  apply beta (Ok (snapshot 2));
  apply alpha (Error "late alpha failure");
  check (option string) "late A cannot replace B's page" (Some "beta")
    (Option.map fst state.keeper_schedules);
  check (option (pair string string)) "late A error is not B's error" None
    state.keeper_schedules_error;
  check bool "offscreen A's request is retired" false
    (Types.detail_read_waiting state ~tab:Types.Detail_automation ~keeper:"alpha");
  let old_beta = ask "beta" in
  let new_beta = ask "beta" in
  apply new_beta (Ok (snapshot 3));
  apply old_beta (Ok (snapshot 1));
  check (option int) "older generation cannot regress the current page" (Some 3)
    (Option.bind state.keeper_schedules (fun (_, page) -> page.scs_request_count));
  let failed = ask "beta" in
  apply failed (Error "beta offline");
  check (option int) "failed refresh retains the last read" (Some 3)
    (Option.bind state.keeper_schedules (fun (_, page) -> page.scs_request_count));
  check (option (pair string string)) "failed refresh is attributed to B"
    (Some ("beta", "beta offline")) state.keeper_schedules_error;
  let first =
    { (snapshot 25) with
      scs_paging = Types.Schedule_paging { page_cursor = None; next_cursor = Some "next" } }
  in
  let page2 = match Types.schedule_next_page Types.schedule_first_page first with
    | Some page -> page
    | None -> fail "the issued next cursor was not offered" in
  check (option string) "next page uses the issued cursor" (Some "next") page2.sp_cursor;
  (match Types.schedule_previous_page page2 with
   | None -> fail "the previous page was lost"
   | Some page -> check (option string) "previous page keeps its original cursor" None page.sp_cursor);
  check bool "a first-page snapshot cannot advance a different page" true
    (Option.is_none (Types.schedule_next_page page2 first));
  let failed_page = ask "beta" in
  Types.apply_keeper_schedules_read state
    { kspr_detail = failed_page; kspr_page = page2;
      kspr_navigation = false; kspr_scroll = 0 } (Error "page failed");
  check (option string) "a failed page read retains the current page" None
    (Option.bind state.keeper_schedules_page (fun (_, page) -> page.sp_cursor));
  let superseded = ask "beta" in
  let newest = ask "beta" in
  Types.apply_keeper_schedules_read state
    { kspr_detail = newest; kspr_page = page2;
      kspr_navigation = false; kspr_scroll = 0 } (Ok (snapshot 25));
  apply superseded (Ok (snapshot 3));
  check (option string) "a late response cannot replace the accepted page" (Some "next")
    (Option.bind state.keeper_schedules_page (fun (_, page) -> page.sp_cursor));
  let read, old_agenda = Types.Snapshot_read.start ~intent:Types.Snapshot_read.Poll state.schedules_agenda_read in
  state.schedules_agenda_read <- read;
  let read, new_agenda = Types.Snapshot_read.start ~intent:Types.Snapshot_read.Refresh state.schedules_agenda_read in
  state.schedules_agenda_read <- read;
  let ticket = function Some ticket -> ticket | None -> fail "agenda request was not started" in
  state.schedules <- Some (snapshot 25);
  Types.apply_schedule_agenda_read state (ticket new_agenda) (Ok (snapshot 3));
  Types.apply_schedule_agenda_read state (ticket old_agenda) (Ok (snapshot 1));
  check (option int) "agenda keeps its own newest first-page observation" (Some 3)
    (Option.bind state.schedules_agenda (fun page -> page.scs_request_count));
  check (option int) "agenda refresh does not replace the browsed page" (Some 25)
    (Option.bind state.schedules (fun page -> page.scs_request_count));
  check bool "A's identity action cannot mutate B's view" false
    (Types.keeper_detail_target_matches state "alpha");
  check bool "B's identity action can refresh its own view" true
    (Types.keeper_detail_target_matches state "beta");
  state.view <- Types.Keepers Types.Keeper_message;
  state.msg_target_keeper_name <- Some "alpha";
  let chat_alpha = ask "alpha" in
  apply chat_alpha (Ok (snapshot 4));
  check (option string) "chat target owns its schedules even while roster selects B" (Some "alpha")
    (Option.map fst state.keeper_schedules);
  let off_target = ask "beta" in
  apply off_target (Error "off-target failure");
  check (option string) "another Keeper cannot replace chat observation" (Some "alpha")
    (Option.map fst state.keeper_schedules);
  check (option (pair string string)) "another Keeper cannot set chat read error" None
    state.keeper_schedules_error;
  state.view <- Types.Keepers Types.Keeper_detail;
  state.detail_tab <- Types.Detail_automation;
  state.keeper_cursor <- 1;
  state.detail_scroll <- 0;
  let pending_page = ask "beta" in
  state.keeper_schedules_pending <- Some (pending_page, page2, 0);
  check bool "repeated request for the same Keeper page shares the pending read" true
    (Types.keeper_schedule_page_pending state ~keeper_name:"beta" page2);
  check bool "the first page cannot share a pending second page" false
    (Types.keeper_schedule_page_pending state ~keeper_name:"beta" Types.schedule_first_page);
  state.detail_scroll <- 1;
  check bool "a new navigation after scrolling does not share the old request" false
    (Types.keeper_schedule_navigation_pending state ~keeper_name:"beta" page2);
  Types.apply_keeper_schedules_read state
    { kspr_detail = pending_page; kspr_page = page2;
      kspr_navigation = true; kspr_scroll = 0 } (Ok (snapshot 77));
  check (option string) "scroll after page request keeps the previous observation" (Some "alpha")
    (Option.map fst state.keeper_schedules);
  let page_for_chat = ask "beta" in
  state.keeper_schedules_pending <- Some (page_for_chat, page2, 0);
  state.view <- Types.Keepers Types.Keeper_message;
  state.msg_target_keeper_name <- Some "beta";
  let chat_first = ask "beta" in
  state.keeper_schedules_pending <- Some (chat_first, Types.schedule_first_page, 0);
  Types.apply_keeper_schedules_read state
    { kspr_detail = page_for_chat; kspr_page = page2;
      kspr_navigation = true; kspr_scroll = 0 } (Ok (snapshot 77));
  check bool "entering chat replaces the pending Automation page" true
    (Types.keeper_schedule_page_pending state ~keeper_name:"beta" Types.schedule_first_page);
  apply chat_first (Ok (snapshot 4));
  check bool "chat accepts the selected Keeper's first page" true
    (Types.keeper_schedule_first_page_available state "beta");
  let first_nav = ask "beta" in
  state.keeper_schedules_pending <- Some (first_nav, Types.schedule_first_page, 0);
  Types.apply_keeper_schedules_read state
    { kspr_detail = first_nav; kspr_page = Types.schedule_first_page;
      kspr_navigation = true; kspr_scroll = 0 } (Ok (snapshot 5));
  check (option int) "chat may accept a shared navigation to the first page" (Some 5)
    (Option.bind state.keeper_schedules (fun (_, page) -> page.scs_request_count));
  state.view <- Types.Schedules;
  state.schedules <- Some first;
  state.schedules_page <- Types.schedule_first_page;
  state.schedule_detail_id <- None;
  let started read intent =
    let read, ticket = Types.Snapshot_read.start ~intent read in
    state.schedules_read <- read;
    match ticket with Some ticket -> ticket | None -> fail "schedule read did not start" in
  let old_poll = started state.schedules_read Types.Snapshot_read.Poll in
  let nav = started state.schedules_read Types.Snapshot_read.Refresh in
  state.schedules_navigation <- Some (nav, page2, None);
  check bool "repeated fleet navigation shares the pending destination" true
    (Types.schedule_navigation_pending state page2);
  state.schedules_navigation <- Some (nav, page2, Some "different-selection");
  check bool "navigation after changing selection does not share the old request" false
    (Types.schedule_navigation_pending state page2);
  state.schedules_navigation <- Some (nav, page2, None);
  let fleet_request ticket navigating =
    { Types.spr_ticket = ticket; spr_page = page2; spr_agenda_ticket = None;
      spr_navigation = navigating; spr_selected_id = None } in
  Types.apply_schedule_page_read state (fleet_request old_poll false) (Ok (snapshot 99));
  check bool "the poll cannot replace its newer page request" true
    (Types.schedule_navigation_pending state page2);
  state.schedule_detail_id <- Some "opened-after-navigation";
  Types.apply_schedule_page_read state (fleet_request nav true) (Ok (snapshot 77));
  check (option string) "opening details beats a late page response"
    (Some "opened-after-navigation") state.schedule_detail_id;
  check (option string) "discarded navigation leaves the first page" None state.schedules_page.sp_cursor;
  state.schedule_detail_id <- None;
  let next = started state.schedules_read Types.Snapshot_read.Refresh in
  Types.apply_schedule_page_read state (fleet_request next true) (Ok (snapshot 77));
  check (option string) "uninterrupted page navigation applies its destination" (Some "next")
    state.schedules_page.sp_cursor

let () =
  run "tui loading notice"
    [ ( "a read in flight"
      , [ test_case "schedule responses follow target and generation" `Quick
            test_schedule_responses_follow_keeper_and_generation
        ; test_case "offscreen completion and late polls preserve a fresh wait" `Quick
            test_offscreen_completion_and_late_poll_do_not_age_a_new_wait
        ; test_case "logs keep repainting after status arrives" `Quick
            test_logs_keep_repainting_after_status_arrives
        ; test_case "the elapsed needs a start" `Quick
            test_the_elapsed_needs_a_start
        ; test_case "two reads are timed apart" `Quick
            test_two_reads_are_timed_apart
        ; test_case "a background read does not reset the visible one" `Quick
            test_a_background_read_does_not_reset_the_visible_one
        ; test_case "the same tab for two keepers is timed apart" `Quick
            test_the_same_tab_for_two_keepers_is_timed_apart
        ; test_case "the wait ends when the answer arrives" `Quick
            test_the_wait_ends_when_the_answer_arrives
        ] )
    ]
