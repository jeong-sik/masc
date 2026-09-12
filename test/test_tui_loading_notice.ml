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

let test_a_background_read_does_not_reset_the_visible_one () =
  (* The operator opens Sandbox, walks to Settings, and an Identity refresh
     finishes behind them and launches its own read. One stamp for the screen
     was rewritten by that read, so the tab on screen reported an elapsed time
     for a request that never restarted. *)
  let state = fresh () in
  Types.mark_detail_read_started state ~tab:Types.Detail_instructions
    ~now_ns:(ns 10);
  Types.mark_detail_read_started state ~tab:Types.Detail_identity ~now_ns:(ns 99);
  state.detail_tab <- Types.Detail_instructions;
  check (option int) "the tab on screen keeps its own start" (Some 90)
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state state.detail_tab));
  check (option int) "and the one that finished behind it keeps its own" (Some 1)
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state Types.Detail_identity));
  check (option int) "a tab nobody asked for measures nothing" None
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state Types.Detail_sandbox));
  (* Asking again replaces that tab's start rather than stacking a second. *)
  Types.mark_detail_read_started state ~tab:Types.Detail_instructions
    ~now_ns:(ns 96);
  check (option int) "R restarts the count for that tab" (Some 4)
    (Types.pending_elapsed_s ~now_ns:(ns 100)
       (Types.detail_read_started state Types.Detail_instructions))

let test_two_reads_are_timed_apart () =
  (* The Sandbox tab's status and its container logs are two reads, and the
     operator presses o/l long after the status landed. Sharing one stamp made
     a log read that had just started claim the status read's minutes. *)
  let state = fresh () in
  Types.mark_detail_read_started state ~tab:Types.Detail_sandbox ~now_ns:(ns 10);
  state.keeper_sandbox_logs_inflight <-
    Some
      { Types.slr_keeper = "analyst"
      ; slr_generation = 3
      ; slr_started_ns = ns 98
      };
  let now_ns = ns 100 in
  check (option int) "the tab read has been waiting ninety seconds" (Some 90)
    (Types.pending_elapsed_s ~now_ns
       (Types.detail_read_started state Types.Detail_sandbox));
  let logs_started =
    Option.map
      (fun (request : Types.sandbox_logs_request) -> request.slr_started_ns)
      state.keeper_sandbox_logs_inflight
  in
  check (option int) "and the log read, two" (Some 2)
    (Types.pending_elapsed_s ~now_ns logs_started)

let () =
  run "tui loading notice"
    [ ( "a read in flight"
      , [ test_case "a quick read says no number" `Quick
            test_a_quick_read_says_no_number
        ; test_case "a slow read says how long" `Quick
            test_a_slow_read_says_how_long
        ; test_case "the elapsed needs a start" `Quick
            test_the_elapsed_needs_a_start
        ; test_case "two reads are timed apart" `Quick
            test_two_reads_are_timed_apart
        ; test_case "a background read does not reset the visible one" `Quick
            test_a_background_read_does_not_reset_the_visible_one
        ] )
    ]
