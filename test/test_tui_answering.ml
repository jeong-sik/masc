open Masc

(* The [@] Answering overlay is the footer badge's "+N" unfolded. These pin
   the projection: who leads, what an error adds, and what quiet looks like,
   so the overlay's promises hold without a terminal. *)

let row name state : Tui_decode.keeper_turn_row =
  { Tui_decode.ktr_keeper_name = name; ktr_state = state }
;;

let running ~lane ~started name =
  row name
    (Tui_decode.Keeper_turn_running { lane; started_at_unix = started })
;;

let texts lines =
  List.map (fun (line : Masc_tui_answering.line) -> line.Masc_tui_answering.text) lines
;;

let test_running_rows_lead_with_the_chat_target () =
  let lines =
    Masc_tui_answering.overlay ~now:1000.
      ~chat_target:(Some "analyst") ~error:None
      [ running ~lane:Tui_decode.Turn_lane_autonomous ~started:866. "kidsnote"
      ; row "rondo" Tui_decode.Keeper_turn_idle
      ; running ~lane:Tui_decode.Turn_lane_chat_operation ~started:990.
          "analyst"
      ]
  in
  match texts lines with
  | [ first; second; idle ] ->
      Alcotest.(check bool) "the chat target leads" true
        (String.length first > 0
        && Astring.String.is_infix ~affix:"analyst" first);
      Alcotest.(check bool) "its lane rides the row" true
        (Astring.String.is_infix ~affix:"chat_operation" first);
      Alcotest.(check bool) "elapsed reads in seconds" true
        (Astring.String.is_infix ~affix:"10s" first);
      Alcotest.(check bool) "the other runner follows" true
        (Astring.String.is_infix ~affix:"kidsnote" second);
      Alcotest.(check bool) "minutes carry their seconds" true
        (Astring.String.is_infix ~affix:"2m14s" second);
      Alcotest.(check string) "idle keepers fold into one count" "1 idle" idle
  | other -> Alcotest.failf "expected three lines, got %d" (List.length other)
;;

let test_quiet_fleet_says_so () =
  let lines =
    Masc_tui_answering.overlay ~now:1000. ~chat_target:None ~error:None
      [ row "kidsnote" Tui_decode.Keeper_turn_idle
      ; row "analyst" Tui_decode.Keeper_turn_idle
      ]
  in
  match texts lines with
  | [ quiet; idle ] ->
      Alcotest.(check string) "an idle fleet is named, not blank"
        "nobody is answering right now" quiet;
      Alcotest.(check string) "the count still rides" "2 idle" idle
  | other -> Alcotest.failf "expected two lines, got %d" (List.length other)
;;

let test_error_keeps_the_last_rows_and_says_why () =
  let lines =
    Masc_tui_answering.overlay ~now:1000. ~chat_target:None
      ~error:(Some "connection refused")
      [ running ~lane:Tui_decode.Turn_lane_maintenance ~started:999. "polisher" ]
  in
  match texts lines with
  | [ failed; kept; runner ] ->
      Alcotest.(check bool) "the poll failure is named" true
        (Astring.String.is_infix ~affix:"connection refused" failed);
      Alcotest.(check bool) "and marked as stale, not fresh" true
        (Astring.String.is_infix ~affix:"last rows" kept);
      Alcotest.(check bool) "the last known runner still shows" true
        (Astring.String.is_infix ~affix:"polisher" runner)
  | other -> Alcotest.failf "expected three lines, got %d" (List.length other)
;;

let test_unavailable_reads_as_unknown_not_idle () =
  let lines =
    Masc_tui_answering.overlay ~now:1000. ~chat_target:None ~error:None
      [ row "rondo" (Tui_decode.Keeper_turn_unavailable "owner_not_found") ]
  in
  match lines with
  | [ quiet; unknown ] ->
      Alcotest.(check bool) "no runner still says nobody" true
        (Astring.String.is_infix ~affix:"nobody"
           quiet.Masc_tui_answering.text);
      Alcotest.(check bool) "the lookup failure is spelled out" true
        (Astring.String.is_infix ~affix:"owner_not_found"
           unknown.Masc_tui_answering.text);
      Alcotest.(check bool) "and toned apart from idle" true
        (unknown.Masc_tui_answering.tone = Masc_tui_answering.Unknown)
  | other -> Alcotest.failf "expected two lines, got %d" (List.length other)
;;

let () =
  Alcotest.run "tui_answering"
    [ ( "tui-answering"
      , [ Alcotest.test_case "running rows lead with the chat target" `Quick
            test_running_rows_lead_with_the_chat_target
        ; Alcotest.test_case "a quiet fleet says so" `Quick
            test_quiet_fleet_says_so
        ; Alcotest.test_case "an error keeps the last rows and says why"
            `Quick test_error_keeps_the_last_rows_and_says_why
        ; Alcotest.test_case "unavailable reads as unknown, not idle" `Quick
            test_unavailable_reads_as_unknown_not_idle
        ] )
    ]
;;
