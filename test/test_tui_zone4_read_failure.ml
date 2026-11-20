(** Zone 4 decisions for a background read that keeps failing
    (RFC tui-one-screen-grammar §2): which notice leads, how many wait behind
    it, and what a repeated failure or a success changes. Wording is not
    checked (constitution execution_protocol). *)

module Failure = Masc_tui_read_failure
module Order = Masc_tui_notice_order
module Prim = Masc_tui_render_prim
module Pace = Masc_tui_refresh_pace
module Redraw = Masc_tui_value.Redraw

let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

let rfc_order =
  Order.[ Pending_confirmation; Action_result; Read_failure; Stale_observation; Next_schedule ]

let reads failures = List.map (fun (failure : Failure.failure) -> failure.read) failures

let state_with failures =
  let state = Masc_tui_types.create_state ~workspace:"" ~port:0 () in
  state.read_failures <- failures;
  state

let lead_read = function
  | Some { Order.lead = Prim.Zone4_read_failure failure; more } -> Some (failure.Failure.read, more)
  | Some { lead = Prim.Zone4_pending | Prim.Zone4_action; more = _ } | None -> None

let test_each_rank_against_every_other () =
  List.iteri (fun i higher ->
    List.iteri (fun j lower ->
      if i < j then
        List.iter (fun notices ->
          match Order.choose ~rank:Fun.id notices with
          | Some { lead; more } ->
              check_bool "the RFC's earlier rank leads" true (lead = higher);
              check_int "the other waits behind" 1 more
          | None -> Alcotest.fail "two notices choose one")
          [ [ higher; lower ]; [ lower; higher ] ])
      rfc_order)
    rfc_order;
  check_bool "nothing waiting draws nothing" true (Order.choose ~rank:Fun.id [] = None)

let two_failures =
  Failure.(failed (failed empty Server_health ~at:10.) Asks ~at:11.)

let test_action_result_is_never_replaced () =
  let state = state_with two_failures in
  (* The failures came first and the action after, and the other way round:
     the action result leads either way, and the reads wait behind it. *)
  (match Prim.zone4_notice state ~action_text:(Some "done") ~preferred_action:None with
   | Some { lead = Prim.Zone4_action; more } -> check_int "both reads wait" 2 more
   | Some _ | None -> Alcotest.fail "the action result leads");
  state.read_failures <- Failure.failed state.read_failures Failure.Confirmations ~at:20.;
  (match Prim.zone4_notice state ~action_text:(Some "done") ~preferred_action:None with
   | Some { lead = Prim.Zone4_action; more } -> check_int "a newer failure waits too" 3 more
   | Some _ | None -> Alcotest.fail "a newer failure does not replace the action result");
  (match Prim.zone4_notice state ~action_text:None
           ~preferred_action:(Some (Masc_tui_footer.Outcome ("lost", Fun.id))) with
   | Some { lead = Prim.Zone4_action; more = _ } -> ()
   | Some _ | None -> Alcotest.fail "an input outcome is an action result too");
  (match Prim.zone4_notice state ~action_text:(Some "quit?")
           ~preferred_action:(Some (Masc_tui_footer.Pending_question ("quit?", Fun.id))) with
   | Some { lead = Prim.Zone4_pending; more } -> check_int "action and reads wait" 4 more
   | Some _ | None -> Alcotest.fail "a pending confirmation leads");
  (* Menu choices are keys (zone 5), not a notice: zone 4's ranking still
     holds the failure. The footer row that stands in for both today gives
     its slot to choices that lead it; that is the row's room, not a rank. *)
  check_bool "choices are not ranked as a notice" true
    (lead_read (Prim.zone4_notice state ~action_text:None
                  ~preferred_action:(Some (Masc_tui_footer.Menu_choices "1:a"))) <> None)

let test_two_failing_reads_draw_one_and_count_one () =
  let state = state_with two_failures in
  check_bool "the read that failed first leads, the other is counted" true
    (lead_read (Prim.zone4_notice state ~action_text:None ~preferred_action:None)
     = Some (Failure.Server_health, 1))

let test_success_clears_only_that_read () =
  let state = state_with (Failure.succeeded two_failures Failure.Server_health) in
  check_bool "the other read leads alone" true
    (lead_read (Prim.zone4_notice state ~action_text:None ~preferred_action:None)
     = Some (Failure.Asks, 0));
  state.read_failures <- Failure.succeeded state.read_failures Failure.Asks;
  check_bool "no failure, no notice" true
    (Prim.zone4_notice state ~action_text:None ~preferred_action:None = None);
  check_bool "a read that never failed clears nothing" true
    (reads (Failure.failures (Failure.succeeded two_failures Failure.Refresh_pass))
     = [ Failure.Server_health; Failure.Asks ])

let test_repeating_failure_changes_only_its_count () =
  (* /health fails every 2 s, and the questions started failing in between. *)
  let every_two_seconds =
    List.fold_left (fun failures at -> Failure.failed failures Failure.Server_health ~at)
      two_failures [ 12.; 14.; 16. ] in
  check_bool "the order stays" true
    (reads (Failure.failures every_two_seconds) = [ Failure.Server_health; Failure.Asks ]);
  (match Failure.failures every_two_seconds with
   | health :: _ ->
       check_bool "the run keeps its start" true (Float.equal health.since 10.);
       check_int "the run counts each failure" 4 health.count
   | [] -> Alcotest.fail "the failure is held");
  let state = state_with every_two_seconds in
  check_bool "the same notice leads with the same count behind it" true
    (lead_read (Prim.zone4_notice state ~action_text:None ~preferred_action:None)
     = Some (Failure.Server_health, 1));
  (* Without a new failure the notice does not change: it says when the run
     started, not how long it has run, so it asks for no redraw of its own
     (RFC §2, §8). *)
  let failure = List.hd (Failure.failures every_two_seconds) in
  List.iter (fun now ->
    Redraw.begin_frame ();
    ignore (Failure.notice_text ~ko:true ~now ~next_try:None failure);
    check_bool "the notice asks for no time redraw" true (Redraw.next_change () = None))
    [ 15.5; 100.; 4000. ]

let test_whole_server_reads_lead () =
  (* The confirm queue failed first; /health and the refresh failed after.
     The server's reads lead, oldest first, since the queue may be failing
     because the server is. *)
  let failures =
    Failure.(failed (failed (failed empty Confirmations ~at:10.) Refresh_pass ~at:12.)
               Server_health ~at:11.) in
  check_bool "server reads first, then the rest, each oldest first" true
    (reads (Failure.failures failures)
     = [ Failure.Server_health; Failure.Refresh_pass; Failure.Confirmations ]);
  check_bool "a later questions failure waits behind the server" true
    (reads (Failure.failures (Failure.failed failures Failure.Asks ~at:13.))
     = [ Failure.Server_health; Failure.Refresh_pass; Failure.Confirmations; Failure.Asks ])

(* Which answers a read's run hears (RFC §2): a failure counts, an answer
   ends the run, and a read the workspace guard kept back is neither. *)
let test_answer_decides_the_run () =
  let state = state_with Failure.empty in
  let note result = Masc_tui_types.note_read_answer state Failure.Asks ~at:5. result in
  note (Error (Masc_tui_types.Request_withdrawn Masc_tui_types.Workspace_identity_not_confirmed));
  check_bool "a kept-back read is no failure" true (Failure.failures state.read_failures = []);
  note (Error (Masc_tui_types.Request_failed "500"));
  note (Error (Masc_tui_types.Request_failed "500"));
  check_bool "a failed read counts" true
    (List.map (fun (failure : Failure.failure) -> failure.read, failure.count)
       (Failure.failures state.read_failures)
     = [ (Failure.Asks, 2) ]);
  note (Error (Masc_tui_types.Request_withdrawn Masc_tui_types.Workspace_authority_withdrawn));
  check_bool "a kept-back read does not end the run" true
    (reads (Failure.failures state.read_failures) = [ Failure.Asks ]);
  note (Ok ());
  check_bool "an answer ends the run" true (Failure.failures state.read_failures = [])

(* The drawn slot, not only the ranking: [footer_line] is what reaches the
   screen. The action text is a fixture token, so these check which notice is
   drawn and whether the waiting count is drawn, never the product wording. *)
let action_token = "zq-action-result-zq"

let retry_s = 2.
let max_retry_s = 30.

(* A wall clock whose local minute is 13, 28, 43 or 58 past in any zone of
   whole quarter hours, so the moments below never cross a day boundary. *)
let scheduled_wall = 1_700_000_000.

(* [/health] failed once and the pass it owes waits [retry_s]. *)
let failing_pace =
  Pace.probe_failed ~retry_s ~max_retry_s ~now:(Masc_tui_wake.Mono.now ()) ~wall_now:scheduled_wall
    Pace.answering

let next_try_wall = scheduled_wall +. retry_s

let health_failing = Failure.(failed empty Server_health ~at:10.)
let asks_failing = Failure.(failed empty Asks ~at:10.)

let drawn_row ?action ?pace failures =
  let state = state_with failures in
  Option.iter (fun pace -> state.refresh_pace <- pace) pace;
  Option.iter (fun text ->
    Masc_tui_types.set_last_action state (Some (text, Unix.gettimeofday ()))) action;
  Prim.footer_line state ~max_cells:400 ~hints:""

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0

let test_drawn_slot_keeps_the_action_result () =
  check_bool "the action result is drawn while reads fail" true
    (contains ~needle:action_token (drawn_row ~action:action_token two_failures))

let test_drawn_slot_counts_the_waiting_reads () =
  (* Behind a visible action result the failing reads change the row (their
     count); with no failing read the row is the action result alone. *)
  check_bool "waiting reads are counted on the drawn row" false
    (String.equal (drawn_row ~action:action_token two_failures)
       (drawn_row ~action:action_token Failure.empty))

let test_drawn_slot_says_a_failure_when_nothing_outranks_it () =
  check_bool "a failing read fills an empty slot" false
    (String.equal (drawn_row two_failures) (drawn_row Failure.empty))

let test_drawn_failure_asks_no_redraw () =
  (* Drawn whole, cut to its first cells, or behind an action result: the
     failing reads add no time redraw to the row (RFC §8). The action result
     notes its own expiry, so the row is compared with the same row without
     the failures. *)
  let at = Unix.gettimeofday () in
  let next_change ?action ?pace ~max_cells failures =
    let state = state_with failures in
    Option.iter (fun text -> Masc_tui_types.set_last_action state (Some (text, at))) action;
    Option.iter (fun pace -> state.refresh_pace <- pace) pace;
    Redraw.begin_frame ();
    ignore (Prim.footer_line state ~max_cells ~hints:"");
    Redraw.next_change () in
  List.iter (fun (action, max_cells) ->
    check_bool "no redraw asked by a failing read" true
      (next_change ?action ~max_cells two_failures
       = next_change ?action ~max_cells Failure.empty);
    check_bool "no redraw asked by the next try" true
      (next_change ?action ~pace:failing_pace ~max_cells two_failures
       = next_change ?action ~max_cells Failure.empty))
    [ (None, 400); (None, 12); (Some action_token, 400); (Some action_token, 12) ]

(* While the pass a failing [/health] owes waits, the notice says when it
   starts (RFC §2); once nothing waits it does not. Which rows differ is
   checked, never the wording. *)
let test_the_notice_says_the_next_try_while_the_probe_fails () =
  check_bool "a failing probe's notice carries the next try" false
    (String.equal (drawn_row ~pace:failing_pace health_failing) (drawn_row health_failing));
  check_bool "an answer takes the next try away" true
    (String.equal (drawn_row ~pace:(Pace.answered_again failing_pace) health_failing)
       (drawn_row health_failing));
  check_bool "the owed pass starting now takes it away" true
    (String.equal
       (drawn_row ~pace:(Pace.stream_opened Pace.Opened_after_failure failing_pace) health_failing)
       (drawn_row health_failing));
  check_bool "a read that does not wait for that pass says no next try" true
    (String.equal (drawn_row ~pace:failing_pace asks_failing) (drawn_row asks_failing))

(* The next try is a moment fixed when the wait was scheduled, not a
   countdown: the notice reads the same as the wait runs out, and only a new
   failure changes it (RFC §2, §8). *)
let test_the_next_try_does_not_move_between_draws () =
  let failure = List.hd (Failure.failures health_failing) in
  let next_try = Pace.next_try failing_pace in
  let texts =
    List.map (fun now ->
      Redraw.begin_frame ();
      let text = Failure.notice_text ~ko:true ~now ~next_try failure in
      check_bool "the next try asks for no redraw" true (Redraw.next_change () = None);
      text)
      [ next_try_wall -. 1.5; next_try_wall -. 0.5; next_try_wall +. 0.5; next_try_wall +. 3. ]
  in
  check_bool "the notice reads the same as the wait runs out" true
    (List.for_all (String.equal (List.hd texts)) texts);
  check_bool "two draws of the row read the same" true
    (String.equal (drawn_row ~pace:failing_pace health_failing)
       (drawn_row ~pace:failing_pace health_failing));
  let again =
    Pace.probe_failed ~retry_s ~max_retry_s ~now:(Masc_tui_wake.Mono.now ())
      ~wall_now:(next_try_wall +. 0.5) failing_pace in
  check_bool "a new failure changes the row" false
    (String.equal (drawn_row ~pace:again health_failing) (drawn_row ~pace:failing_pace health_failing))

let () =
  Alcotest.run "tui_zone4_read_failure"
    [ ( "zone 4"
      , [ Alcotest.test_case "each rank against every other" `Quick
            test_each_rank_against_every_other
        ; Alcotest.test_case "an action result is never replaced" `Quick
            test_action_result_is_never_replaced
        ; Alcotest.test_case "two failing reads: one notice, one more" `Quick
            test_two_failing_reads_draw_one_and_count_one
        ; Alcotest.test_case "a success clears only that read" `Quick
            test_success_clears_only_that_read
        ; Alcotest.test_case "a repeating failure changes only its count" `Quick
            test_repeating_failure_changes_only_its_count
        ; Alcotest.test_case "the drawn slot keeps the action result" `Quick
            test_drawn_slot_keeps_the_action_result
        ; Alcotest.test_case "the drawn slot counts the waiting reads" `Quick
            test_drawn_slot_counts_the_waiting_reads
        ; Alcotest.test_case "the drawn slot says a failure when nothing outranks it" `Quick
            test_drawn_slot_says_a_failure_when_nothing_outranks_it
        ; Alcotest.test_case "a drawn failure asks for no redraw" `Quick
            test_drawn_failure_asks_no_redraw
        ; Alcotest.test_case "the notice says the next try while the probe fails" `Quick
            test_the_notice_says_the_next_try_while_the_probe_fails
        ; Alcotest.test_case "the next try does not move between draws" `Quick
            test_the_next_try_does_not_move_between_draws
        ; Alcotest.test_case "the whole server's reads lead" `Quick
            test_whole_server_reads_lead
        ; Alcotest.test_case "an answer decides the run" `Quick
            test_answer_decides_the_run
        ] )
    ]
