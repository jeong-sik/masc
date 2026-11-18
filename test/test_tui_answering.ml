open Masc

(* The [@] Answering overlay is the footer badge's "+N" unfolded. These pin
   the projection: who leads, what an error adds, what quiet looks like, how
   a finished turn keeps its ✓ row for a while, and which rows Enter can act
   on — so the overlay's promises hold without a terminal. *)

let row name state : Tui_decode.keeper_turn_row =
  { Tui_decode.ktr_chat_control_token = None; ktr_keeper_name = name; ktr_state = state }
;;

let running ?preview ~lane ~started name =
  row name
    (Tui_decode.Keeper_turn_running
       { lane; started_at_unix = started; preview; interrupt_token = "fixture-token"; turn_ref = None })
;;

let texts lines =
  List.map (fun (line : Masc_tui_answering.line) -> line.Masc_tui_answering.text) lines
;;

let test_unavailable_reads_as_unknown_not_idle () =
  let lines =
    Masc_tui_answering.overlay ~ko:false ~now:1000. ~chat_target:None ~error:None
      ~observed_at:(Some 988.)
      ~finishes:[]
      [ row "delta" (Tui_decode.Keeper_turn_unavailable "owner_not_found") ]
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

let test_finished_turns_glow_then_expire () =
  let finishes = [ ("echo", 990.) ] in
  let fresh =
    Masc_tui_answering.overlay ~ko:false ~now:1000. ~chat_target:None ~error:None
      ~observed_at:(Some 988.)
      ~finishes
      [ row "echo" Tui_decode.Keeper_turn_idle ]
  in
  (match fresh with
   | [ done_line; idle ] ->
       Alcotest.(check bool) "a finish inside the TTL keeps a ✓ row" true
         (Astring.String.is_infix ~affix:"echo"
            done_line.Masc_tui_answering.text
         && Astring.String.is_infix ~affix:"answered 10s ago"
              done_line.Masc_tui_answering.text);
       Alcotest.(check bool) "toned as done" true
         (done_line.Masc_tui_answering.tone = Masc_tui_answering.Done);
       Alcotest.(check bool) "and Enter can open it" true
         (done_line.Masc_tui_answering.target = Some "echo");
       Alcotest.(check bool)
         "a fleet with a fresh finish does not read as nobody" true
         (Astring.String.is_infix ~affix:"idle"
            idle.Masc_tui_answering.text)
   | other -> Alcotest.failf "expected two lines, got %d" (List.length other));
  let expired =
    Masc_tui_answering.overlay ~ko:false
      ~now:(990. +. Masc_tui_answering.finish_glow_ttl_seconds +. 1.)
      ~chat_target:None ~error:None ~observed_at:(Some 988.) ~finishes
      [ row "echo" Tui_decode.Keeper_turn_idle ]
  in
  match texts expired with
  | [ quiet; _idle ] ->
      Alcotest.(check string) "past the TTL the glow is gone"
        "nobody is answering right now" quiet
  | other -> Alcotest.failf "expected two lines, got %d" (List.length other)
;;

let test_advance_finishes_tracks_the_transition () =
  let previous =
    [ running ~lane:Tui_decode.Turn_lane_autonomous ~started:900. "echo"
    ; running ~lane:Tui_decode.Turn_lane_chat_operation ~started:950. "analyst"
    ; row "delta" (Tui_decode.Keeper_turn_unavailable "owner_not_found")
    ]
  in
  let current =
    [ row "echo" Tui_decode.Keeper_turn_idle
    ; running ~lane:Tui_decode.Turn_lane_chat_operation ~started:950. "analyst"
    ; row "delta" Tui_decode.Keeper_turn_idle
    ]
  in
  let finishes =
    Masc_tui_answering.advance_finishes ~now:1000. ~previous_rows:previous
      ~current_rows:current []
  in
  Alcotest.(check (list (pair string (float 0.001))))
    "running→idle is a finish; unavailable→idle is not"
    [ ("echo", 1000.) ] finishes;
  (* A keeper that starts running again drops its glow: the badge takes
     over, and one keeper must not read as both answering and answered. *)
  let running_again =
    Masc_tui_answering.advance_finishes ~now:1010.
      ~previous_rows:current
      ~current_rows:
        [ running ~lane:Tui_decode.Turn_lane_autonomous ~started:1005.
            "echo"
        ]
      finishes
  in
  Alcotest.(check (list (pair string (float 0.001))))
    "restarting clears the finish glow" [] running_again
;;

let test_target_indexes_skip_prose () =
  let lines =
    Masc_tui_answering.overlay ~ko:false ~now:1000. ~chat_target:None
      ~error:(Some (Masc_tui_answering.Read_failed "boom")) ~observed_at:(Some 988.) ~finishes:[ ("analyst", 995.) ]
      [ running ~lane:Tui_decode.Turn_lane_autonomous ~started:990. "echo"
      ; row "delta" Tui_decode.Keeper_turn_idle
      ]
  in
  (* error(2 lines) → running(1) → finished(1) → idle(1) *)
  Alcotest.(check (list int)) "only actionable rows carry an index" [ 2; 3 ]
    (Masc_tui_answering.target_indexes lines)
;;

let test_chat_shows_background_work_and_uncertainty () =
  let preview : Tui_decode.keeper_turn_preview =
    { ktp_updated_at_unix = 950.; ktp_text_position={kpp_generation=0; kpp_start_byte=0}; ktp_text_tail = "editing the report"; ktp_last_tool = Some "Execute"; ktp_preparation=None; ktp_preparation_timeline=None; ktp_execution_scope=None; ktp_activity=None
    ; ktp_status_text = "glm · tool activity observed · last observed tool: Execute · last failure: 401" } in
  let rows =
    [ running ~preview ~lane:Tui_decode.Turn_lane_autonomous ~started:900. "echo"
    ; running ~lane:Tui_decode.Turn_lane_maintenance ~started:950. "other" ] in
  let text rows = List.map Masc_tui_answering.chat_activity_row_text rows in
  let activity ?(error = None) keeper_name rows =
    Masc_tui_answering.chat_activity ~ko:false ~now:1000. ~keeper_name ~error rows
  in
  let lines = activity "echo" rows in
  Alcotest.(check int) "only running status in the band" 1 (List.length lines);
  let joined = String.concat "\n" (text lines) in
  List.iter (fun expected -> Alcotest.(check bool) expected true
    (Astring.String.is_infix ~affix:expected joined))
    ["autonomous"; "glm"; "Execute"; "401"; "last activity 50s ago"];
  (* The lead is what the status colour paints: the mark, the lane, the age.
     The model and the tool are detail and recede. *)
  (match lines with
   | status :: _ ->
     Alcotest.(check bool) "the lead names the lane and the age" true
       (Astring.String.is_infix ~affix:"autonomous · 1m" status.Masc_tui_answering.lead);
     Alcotest.(check bool) "the model is not in the lead" false
       (Astring.String.is_infix ~affix:"glm" status.lead);
     Alcotest.(check bool) "no sentence around the facts" false
       (Astring.String.is_infix ~affix:"Current" status.lead)
   | [] -> Alcotest.fail "no status row");
  Alcotest.(check bool) "other Keeper never appears" false
    (Astring.String.is_infix ~affix:"other" joined);
  let waiting = activity "other" rows |> text |> String.concat "\n" in
  Alcotest.(check bool) "missing events are not invented work" true
    (Astring.String.is_infix ~affix:"progress has not been reported" waiting);
  let stale = activity ~error:(Some (Masc_tui_answering.Read_failed "timeout")) "echo" rows |> text in
  Alcotest.(check bool) "failed observation is labelled" true
    (Astring.String.is_infix ~affix:"Activity unavailable" (List.hd stale));
  Alcotest.(check bool) "cached progress is marked last observed" true
    (Astring.String.is_infix ~affix:"last observed autonomous" (String.concat "\n" stale));
  Alcotest.(check (list string)) "idle has no stale running preview" []
    (text (activity "echo" [row "echo" Tui_decode.Keeper_turn_idle]));
  (* Output belongs to the conversation regardless of its live source. *)
  let drawn = activity "echo" rows in
  Alcotest.(check int) "status line alone when the pane draws the text" 1
    (List.length drawn);
  Alcotest.(check bool) "the tail is not said twice" false
    (Astring.String.is_infix ~affix:"editing the report" (String.concat "\n" (text drawn)))
;;

let () =
  Alcotest.run "tui_answering"
    [ ( "chat activity", [Alcotest.test_case "background work and missing observation" `Quick
          test_chat_shows_background_work_and_uncertainty])
    ; ( "duration"
      , [] )
    ; ( "running mark"
      , [] )
    ; ( "tui-answering"
      , [ Alcotest.test_case "unavailable reads as unknown, not idle" `Quick
            test_unavailable_reads_as_unknown_not_idle
        ; Alcotest.test_case "finished turns glow then expire" `Quick
            test_finished_turns_glow_then_expire
        ; Alcotest.test_case "advance_finishes tracks the transition" `Quick
            test_advance_finishes_tracks_the_transition
        ; Alcotest.test_case "target indexes skip prose" `Quick
            test_target_indexes_skip_prose
        ;] )
    ]
;;
