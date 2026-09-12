open Alcotest
module Types = Masc_tui_types

(* What the keeper detail tabs say while a read is in flight.

   The seconds are the point: against a live server the Sandbox tab's status
   took somewhere between five and sixteen seconds, and a bare "(loading...)"
   held through that window is read as a stall -- the operator starts pressing
   keys. A read that answers at once must not flash a number, which is what the
   floor is for. *)

let cut = "\xe2\x80\xa6"

let fresh () =
  Types.create_state ~workspace:"me" ~port:8935 ~refresh_interval:2.0 ()

let test_a_quick_read_says_no_number () =
  check string "nothing measured, nothing said" ("(loading" ^ cut ^ ")")
    (Types.loading_notice "loading");
  check string "under the floor, still nothing" ("(loading" ^ cut ^ ")")
    (Types.loading_notice ~elapsed_s:1 "loading")

let test_a_slow_read_says_how_long () =
  check string "at the floor" ("(loading" ^ cut ^ " 2s)")
    (Types.loading_notice ~elapsed_s:Types.pending_seconds_floor "loading");
  check string "and past it" ("(loading" ^ cut ^ " 16s)")
    (Types.loading_notice ~elapsed_s:16 "loading");
  check string "whatever the read is called"
    ("(loading actual container logs" ^ cut ^ " 7s)")
    (Types.loading_notice ~elapsed_s:7 "loading actual container logs")

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
     Types.Detail_identity]

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

let () =
  run "tui loading notice"
    [ ( "a read in flight"
      , [ test_case "offscreen completion and late polls preserve a fresh wait" `Quick
            test_offscreen_completion_and_late_poll_do_not_age_a_new_wait
        ; test_case "logs keep repainting after status arrives" `Quick
            test_logs_keep_repainting_after_status_arrives
        ; test_case "a quick read says no number" `Quick
            test_a_quick_read_says_no_number
        ; test_case "a slow read says how long" `Quick
            test_a_slow_read_says_how_long
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
