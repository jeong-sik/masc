open Masc

(* The live-glance plane behind the Answering overlay's preview panel.
   Pins the UTF-8 tail cut, the blank-text guard, and that a tool note
   never erases the last visible words. *)

let test_tail_cuts_on_utf8_boundary () =
  let hangul = String.concat "" (List.init 200 (fun _ -> "\xea\xb0\x80")) in
  Keeper_turn_preview.note_text ~keeper_name:"tail-keeper" ~now:1. hangul;
  match Keeper_turn_preview.current ~keeper_name:"tail-keeper" with
  | None -> Alcotest.fail "text was noted but nothing is current"
  | Some preview ->
    Alcotest.(check bool) "tail fits the byte budget" true
      (String.length preview.Keeper_turn_preview.text_tail
       <= Keeper_turn_preview.tail_bytes);
    Alcotest.(check int) "and starts on a UTF-8 boundary (whole glyphs)" 0
      (String.length preview.Keeper_turn_preview.text_tail mod 3)
;;

let test_blank_text_does_not_erase_the_last_words () =
  Keeper_turn_preview.note_text ~keeper_name:"blank-keeper" ~now:1. "words";
  Keeper_turn_preview.note_text ~keeper_name:"blank-keeper" ~now:2. "   ";
  match Keeper_turn_preview.current ~keeper_name:"blank-keeper" with
  | None -> Alcotest.fail "entry vanished"
  | Some preview ->
    Alcotest.(check string) "a tool-only turn keeps the last visible words"
      "words" preview.Keeper_turn_preview.text_tail
;;

let test_tool_note_keeps_text_and_text_keeps_tool () =
  Keeper_turn_preview.note_text ~keeper_name:"mix-keeper" ~now:1. "drafting";
  Keeper_turn_preview.note_tool ~keeper_name:"mix-keeper" ~now:2.
    "Execute";
  (match Keeper_turn_preview.current ~keeper_name:"mix-keeper" with
   | Some { Keeper_turn_preview.text_tail; last_tool; _ } ->
     Alcotest.(check string) "tool note kept the text" "drafting" text_tail;
     Alcotest.(check (option string)) "and recorded the tool"
       (Some "Execute") last_tool
   | None -> Alcotest.fail "entry vanished");
  Keeper_turn_preview.note_text ~keeper_name:"mix-keeper" ~now:3. "still going";
  match Keeper_turn_preview.current ~keeper_name:"mix-keeper" with
  | Some { Keeper_turn_preview.text_tail; last_tool; _ } ->
    Alcotest.(check string) "text note replaced the tail" "still going"
      text_tail;
    Alcotest.(check (option string)) "and kept the tool" (Some "Execute")
      last_tool
  | None -> Alcotest.fail "entry vanished"
;;

let test_unknown_keeper_has_no_preview () =
  Alcotest.(check bool) "no note, no glance" true
    (Keeper_turn_preview.current ~keeper_name:"never-noted" = None)
;;

let test_live_attempt_failover_and_new_turn () =
  let keeper_name = "live-lifecycle" in
  let current () = Option.get (Keeper_turn_preview.current ~keeper_name) in
  Keeper_turn_preview.reset ~keeper_name ~now:1.;
  Keeper_turn_preview.note_attempt ~keeper_name ~now:2. ~runtime_id:"claude";
  Alcotest.(check bool) "silent provider wait is visible" true
    (Astring.String.is_infix ~affix:"waiting for provider response"
      (Keeper_turn_preview.status_text (current ())));
  Keeper_turn_preview.note_failure ~keeper_name ~now:3. ~runtime_id:"claude" "401 invalid key";
  Keeper_turn_preview.note_attempt ~keeper_name ~now:4. ~runtime_id:"glm";
  let switched = Keeper_turn_preview.status_text (current ()) in
  Alcotest.(check bool) "new provider and failure both visible" true
    (Astring.String.is_infix ~affix:"glm" switched && Astring.String.is_infix ~affix:"401" switched);
  Keeper_turn_preview.note_stream ~keeper_name ~now:5.
    (Agent_core.Types.ContentBlockDelta { index = 0; delta = TextDelta "working" });
  Alcotest.(check string) "text appears before a turn completes" "working" (current ()).text_tail;
  Keeper_turn_preview.note_tool ~keeper_name ~now:6. "Execute";
  Alcotest.(check bool) "last observed tool visible" true
    (Astring.String.is_infix ~affix:"last observed tool: Execute" (Keeper_turn_preview.status_text (current ())));
  Keeper_turn_preview.note_tool ~keeper_name ~now:7. "Execute";
  Alcotest.(check bool) "a returned tool is never labelled running" false
    (Astring.String.is_infix ~affix:"tool running" (Keeper_turn_preview.status_text (current ())));
  Keeper_turn_preview.reset ~keeper_name ~now:8.;
  Alcotest.(check string) "new turn cannot inherit old output" "" (current ()).text_tail;
  Alcotest.(check (option string)) "new turn cannot inherit old failure" None (current ()).last_failure
;;

let test_overlapping_and_rejected_tools_remain_observations () =
  let keeper_name = "overlapping-tools" in
  let current () = Option.get (Keeper_turn_preview.current ~keeper_name) in
  Keeper_turn_preview.reset ~keeper_name ~now:1.;
  (* The same hook can run before validation rejects Skill. *)
  Keeper_turn_preview.note_tool ~keeper_name ~now:2. "Skill";
  Alcotest.(check string) "a request does not claim execution"
    "tool activity observed · last observed tool: Skill"
    (Keeper_turn_preview.status_text (current ()));
  (* A starts, B starts, A returns. A is the latest observation, not a claim
     that A is running or that B stopped. No shared in-flight slot is cleared. *)
  List.iteri (fun index tool ->
    Keeper_turn_preview.note_tool ~keeper_name ~now:(3. +. float_of_int index) tool)
    ["A"; "B"; "A"];
  Alcotest.(check string) "interleaved returns keep their historical meaning"
    "tool activity observed · last observed tool: A"
    (Keeper_turn_preview.status_text (current ()));
  Keeper_turn_preview.note_failure ~keeper_name ~now:6. ~runtime_id:"claude" "rejected";
  Alcotest.(check (option string)) "failed attempt drops tool observation" None
    (current ()).last_tool;
  Keeper_turn_preview.note_attempt ~keeper_name ~now:7. ~runtime_id:"glm";
  Alcotest.(check (option string)) "next attempt has no prior tool" None
    (current ()).last_tool
;;

let () =
  Alcotest.run "keeper_turn_preview"
    [ ( "keeper-turn-preview"
      , [ Alcotest.test_case "overlapping and rejected tools are observations" `Quick
            test_overlapping_and_rejected_tools_remain_observations
        ; Alcotest.test_case "live wait, failover, tool, and next-turn visibility" `Quick
            test_live_attempt_failover_and_new_turn
        ; Alcotest.test_case "tail cuts on a UTF-8 boundary" `Quick
            test_tail_cuts_on_utf8_boundary
        ; Alcotest.test_case "blank text does not erase the last words" `Quick
            test_blank_text_does_not_erase_the_last_words
        ; Alcotest.test_case "tool and text notes do not clobber each other"
            `Quick test_tool_note_keeps_text_and_text_keeps_tool
        ; Alcotest.test_case "unknown keeper has no preview" `Quick
            test_unknown_keeper_has_no_preview
        ] )
    ]
;;
