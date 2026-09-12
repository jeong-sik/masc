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

let test_two_reads_are_timed_apart () =
  (* The Sandbox tab's status and its container logs are two reads, and the
     operator presses o/l long after the status landed. Sharing one stamp made
     a log read that had just started claim the status read's minutes. *)
  let state = fresh () in
  state.detail_read_started_at <- Some (ns 10);
  state.keeper_sandbox_logs_inflight <-
    Some
      { Types.slr_keeper = "analyst"
      ; slr_generation = 3
      ; slr_started_ns = ns 98
      };
  let now_ns = ns 100 in
  check (option int) "the tab read has been waiting ninety seconds" (Some 90)
    (Types.pending_elapsed_s ~now_ns state.detail_read_started_at);
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
        ] )
    ]
