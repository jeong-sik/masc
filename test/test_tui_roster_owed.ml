(* Which roster read the TUI starts after the server says a row, or every
   row, changed (RFC-0481 §3.3). The checks are on the read chosen, never on
   the screen. *)

open Alcotest
module R = Masc_tui_roster_owed

let retry_s = 2.0
let max_retry_s = 30.0
let failed ~now read t = R.failed ~retry_s ~max_retry_s ~now read t

let read =
  testable
    (fun formatter -> function
      | R.Read_row keeper_name -> Format.fprintf formatter "Read_row %s" keeper_name
      | R.Read_roster -> Format.pp_print_string formatter "Read_roster")
    ( = )

let next ~now t = R.next_read ~now t

let test_one_changed_keeper_reads_its_row () =
  let t = R.row_changed ~keeper_name:"alpha" R.settled in
  check (option read) "one row" (Some (R.Read_row "alpha")) (next ~now:0.0 t);
  let t = R.started (R.Read_row "alpha") t in
  check (option read) "nothing while it reads" None (next ~now:0.0 t);
  check (option read) "nothing after it succeeds" None
    (next ~now:0.0 (R.succeeded (R.Read_row "alpha") t))

let test_two_changed_keepers_read_the_roster_once () =
  let t =
    R.settled |> R.row_changed ~keeper_name:"alpha" |> R.row_changed ~keeper_name:"beta"
  in
  check (option read) "one whole read" (Some R.Read_roster) (next ~now:0.0 t);
  let t = R.succeeded R.Read_roster (R.started R.Read_roster t) in
  check (option read) "the whole read settles both rows" None (next ~now:0.0 t)

let test_a_roster_change_reads_the_roster () =
  let t = R.row_changed ~keeper_name:"alpha" (R.roster_changed R.settled) in
  check (option read) "whole read" (Some R.Read_roster) (next ~now:0.0 t);
  let t = R.succeeded R.Read_roster (R.started R.Read_roster t) in
  check (option read) "settled" None (next ~now:0.0 t)

let test_a_change_during_a_row_read_reads_that_row_again () =
  let t = R.started (R.Read_row "alpha") (R.row_changed ~keeper_name:"alpha" R.settled) in
  let t = R.row_changed ~keeper_name:"alpha" t in
  check (option read) "waits for the read in flight" None (next ~now:0.0 t);
  let t = R.succeeded (R.Read_row "alpha") t in
  check (option read) "the row again" (Some (R.Read_row "alpha")) (next ~now:0.0 t)

let test_another_keeper_waits_for_the_read_in_flight () =
  let t = R.started (R.Read_row "alpha") (R.row_changed ~keeper_name:"alpha" R.settled) in
  let t = R.row_changed ~keeper_name:"beta" t in
  check (option read) "one read at a time" None (next ~now:0.0 t);
  let t = R.succeeded (R.Read_row "alpha") t in
  check (option read) "then the other row" (Some (R.Read_row "beta")) (next ~now:0.0 t)

let test_a_change_during_a_roster_read_is_read_after_it () =
  let t = R.started R.Read_roster (R.roster_changed R.settled) in
  let t = R.row_changed ~keeper_name:"alpha" t in
  check (option read) "waits for the whole read" None (next ~now:0.0 t);
  let t = R.succeeded R.Read_roster t in
  check (option read) "the row changed after it began" (Some (R.Read_row "alpha"))
    (next ~now:0.0 t)

let test_a_failed_row_read_retries_with_backoff () =
  let t = R.started (R.Read_row "alpha") (R.row_changed ~keeper_name:"alpha" R.settled) in
  let t = failed ~now:10.0 (R.Read_row "alpha") t in
  check (option read) "not before the wait" None (next ~now:11.9 t);
  check (option read) "after the wait" (Some (R.Read_row "alpha")) (next ~now:12.0 t);
  let t = failed ~now:12.0 (R.Read_row "alpha") (R.started (R.Read_row "alpha") t) in
  check (option read) "the second wait doubles" None (next ~now:15.9 t);
  check (option read) "after the second wait" (Some (R.Read_row "alpha")) (next ~now:16.0 t)

let test_a_failed_row_does_not_hold_back_another () =
  let t = R.started (R.Read_row "alpha") (R.row_changed ~keeper_name:"alpha" R.settled) in
  let t = R.row_changed ~keeper_name:"beta" (failed ~now:0.0 (R.Read_row "alpha") t) in
  check (option read) "the other row reads now" (Some (R.Read_row "beta")) (next ~now:0.0 t)

let test_rows_wait_while_a_failed_roster_read_waits () =
  let t = R.started R.Read_roster (R.roster_changed R.settled) in
  let t = R.row_changed ~keeper_name:"alpha" (failed ~now:10.0 R.Read_roster t) in
  check (option read) "no row before the roster's wait ends" None (next ~now:11.9 t);
  check (option read) "the whole roster after it" (Some R.Read_roster) (next ~now:12.0 t)

let test_an_abandoned_read_is_owed_again () =
  let t = R.started (R.Read_row "alpha") (R.row_changed ~keeper_name:"alpha" R.settled) in
  check bool "reading" true (R.reading t);
  let t = R.abandoned t in
  check bool "not reading" false (R.reading t);
  check (option read) "owed again" (Some (R.Read_row "alpha")) (next ~now:0.0 t)

let test_a_scheduled_row_is_read_once_its_time_comes () =
  let t = R.schedule_rows [ ("alpha", 10.0) ] R.settled in
  check (option read) "not before its time" None (next ~now:9.9 (R.release_scheduled ~now:9.9 t));
  let t = R.release_scheduled ~now:10.0 t in
  check (option read) "at its time" (Some (R.Read_row "alpha")) (next ~now:10.0 t);
  let t = R.succeeded (R.Read_row "alpha") (R.started (R.Read_row "alpha") t) in
  check (option read) "once" None (next ~now:20.0 (R.release_scheduled ~now:20.0 t))

let test_a_new_schedule_replaces_the_old_one () =
  let t = R.settled |> R.schedule_rows [ ("alpha", 10.0) ] |> R.schedule_rows [ ("beta", 10.0) ] in
  check (option read) "only the row scheduled last" (Some (R.Read_row "beta"))
    (next ~now:10.0 (R.release_scheduled ~now:10.0 t))

let () =
  run "tui_roster_owed"
    [ ( "roster_owed"
      , [ test_case "one changed Keeper reads its row" `Quick
            test_one_changed_keeper_reads_its_row
        ; test_case "two changed Keepers read the roster once" `Quick
            test_two_changed_keepers_read_the_roster_once
        ; test_case "a roster change reads the roster" `Quick
            test_a_roster_change_reads_the_roster
        ; test_case "a change during a row read reads that row again" `Quick
            test_a_change_during_a_row_read_reads_that_row_again
        ; test_case "another Keeper waits for the read in flight" `Quick
            test_another_keeper_waits_for_the_read_in_flight
        ; test_case "a change during a roster read is read after it" `Quick
            test_a_change_during_a_roster_read_is_read_after_it
        ; test_case "a failed row read retries with backoff" `Quick
            test_a_failed_row_read_retries_with_backoff
        ; test_case "a failed row does not hold back another" `Quick
            test_a_failed_row_does_not_hold_back_another
        ; test_case "rows wait while a failed roster read waits" `Quick
            test_rows_wait_while_a_failed_roster_read_waits
        ; test_case "an abandoned read is owed again" `Quick
            test_an_abandoned_read_is_owed_again
        ; test_case "a scheduled row is read once its time comes" `Quick
            test_a_scheduled_row_is_read_once_its_time_comes
        ; test_case "a new schedule replaces the old one" `Quick
            test_a_new_schedule_replaces_the_old_one
        ] )
    ]
