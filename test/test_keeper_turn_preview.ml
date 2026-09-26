open Masc

(* The live-glance plane behind the Answering overlay's preview panel.
   Pins the UTF-8 tail cut, the blank-text guard, that a tool note
   never erases the last visible words, and that the tail the turns route
   serves is redacted across delta boundaries. *)

let reset keeper_name ~now =
  Keeper_turn_preview.reset ~keeper_name ~now ~redaction:Keeper_secret_redaction.empty
;;

let text_delta text =
  Agent_core.Types.ContentBlockDelta { index = 0; delta = TextDelta text }
;;

(* A redaction snapshot whose one exact value is [secret], read from a caller
   file so the test needs no knowledge of the keeper secret layout. *)
let with_secret_redaction ~keeper_name secret f =
  let dir = Filename.temp_dir "keeper_turn_preview_" "" in
  let file = Filename.concat dir "secret.txt" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove file with Sys_error _ -> ());
      try Sys.rmdir dir with Sys_error _ -> ())
    (fun () ->
      Out_channel.with_open_bin file (fun oc -> output_string oc (secret ^ "\n"));
      f
        (Keeper_secret_redaction.snapshot_with_additional_secret_files
           ~redact_identity_scalars:true ~additional_secret_files:[ file ]
           ~base_path:dir ~keeper_name))
;;

let tail keeper_name =
  match Keeper_turn_preview.current ~keeper_name with
  | Some preview -> preview.Keeper_turn_preview.text_tail
  | None -> Alcotest.fail "no preview for a keeper that was reset"
;;

let contains haystack needle = Astring.String.is_infix ~affix:needle haystack

let test_tail_cuts_on_utf8_boundary () =
  let hangul = String.concat "" (List.init 200 (fun _ -> "\xea\xb0\x80")) in
  reset "tail-keeper" ~now:0.;
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
  reset "blank-keeper" ~now:0.;
  Keeper_turn_preview.note_text ~keeper_name:"blank-keeper" ~now:1. "words";
  Keeper_turn_preview.note_text ~keeper_name:"blank-keeper" ~now:2. "   ";
  match Keeper_turn_preview.current ~keeper_name:"blank-keeper" with
  | None -> Alcotest.fail "entry vanished"
  | Some preview ->
    Alcotest.(check string) "a tool-only turn keeps the last visible words"
      "words" preview.Keeper_turn_preview.text_tail
;;

let test_tool_note_keeps_text_and_text_keeps_tool () =
  reset "mix-keeper" ~now:0.;
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
  reset keeper_name ~now:1.;
  Keeper_turn_preview.note_attempt ~keeper_name ~now:2. ~runtime_id:"claude";
  Alcotest.(check bool) "silent provider wait is visible" true
    (Astring.String.is_infix ~affix:"waiting for provider response"
      (Keeper_turn_preview.status_text (current ())));
  Keeper_turn_preview.note_failure ~keeper_name ~now:3. ~runtime_id:"claude" "401 invalid key";
  Keeper_turn_preview.note_attempt ~keeper_name ~now:4. ~runtime_id:"glm";
  let switched = Keeper_turn_preview.status_text (current ()) in
  Alcotest.(check bool) "new provider and failure both visible" true
    (Astring.String.is_infix ~affix:"glm" switched && Astring.String.is_infix ~affix:"401" switched);
  Keeper_turn_preview.note_stream ~keeper_name ~now:5. (text_delta "working\n");
  Alcotest.(check string) "a finished line appears before the turn completes"
    "working\n" (current ()).text_tail;
  Keeper_turn_preview.note_tool ~keeper_name ~now:6. "Execute";
  Alcotest.(check bool) "last observed tool visible" true
    (Astring.String.is_infix ~affix:"last observed tool: Execute" (Keeper_turn_preview.status_text (current ())));
  Keeper_turn_preview.note_tool ~keeper_name ~now:7. "Execute";
  Alcotest.(check bool) "a returned tool is never labelled running" false
    (Astring.String.is_infix ~affix:"tool running" (Keeper_turn_preview.status_text (current ())));
  reset keeper_name ~now:8.;
  Alcotest.(check string) "new turn cannot inherit old output" "" (current ()).text_tail;
  Alcotest.(check (option string)) "new turn cannot inherit old failure" None (current ()).last_failure
;;

let test_overlapping_and_rejected_tools_remain_observations () =
  let keeper_name = "overlapping-tools" in
  let current () = Option.get (Keeper_turn_preview.current ~keeper_name) in
  reset keeper_name ~now:1.;
  Keeper_turn_preview.note_stream ~keeper_name ~now:1.5
    (Agent_core.Types.ContentBlockStart { index=1; content_type="tool_use"; tool_id=Some "dynamic"; tool_name=Some "MCP" });
  Alcotest.(check (option string)) "official-client dynamic tool is visible" (Some "MCP") (current ()).last_tool;
  Keeper_turn_preview.note_failure ~keeper_name ~now:1.6 ~runtime_id:"claude" (String.make 10000 'x');
  Alcotest.(check bool) "diagnostic cannot flood the light poll" true
    (String.length (Option.get (current ()).last_failure) < 300);
  reset keeper_name ~now:1.7;
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

(* Two Codex [item/agentMessage/delta] chunks that each carry half of a
   secret. Neither half is an exact value, so a tail built from the raw deltas
   served the secret to every surface that polls the turns route. *)
let test_secret_split_across_deltas_never_reaches_the_tail () =
  let keeper_name = "split-secret-preview" in
  let secret = "preview-split-secret-9931" in
  with_secret_redaction ~keeper_name secret (fun redaction ->
    let first = "deploy with preview-split-" and second = "secret-9931 now\n" in
    Alcotest.(check string) "the second half alone passes plain redaction" second
      (Keeper_secret_redaction.redact_text redaction second);
    Keeper_turn_preview.reset ~keeper_name ~now:1. ~redaction;
    Keeper_turn_preview.note_stream ~keeper_name ~now:2. (text_delta first);
    Alcotest.(check string) "an unfinished line is held back" "" (tail keeper_name);
    Alcotest.(check bool) "while the activity already shows the response" true
      (contains
         (Keeper_turn_preview.status_text
            (Option.get (Keeper_turn_preview.current ~keeper_name)))
         "receiving response");
    Keeper_turn_preview.note_stream ~keeper_name ~now:3. (text_delta second);
    Alcotest.(check string) "the finished line arrives redacted"
      "deploy with [REDACTED] now\n" (tail keeper_name);
    Alcotest.(check bool) "no part of the secret is served" false
      (contains (tail keeper_name) "secret-9931");
    Keeper_turn_preview.note_text ~keeper_name ~now:4. ("final answer: " ^ secret);
    Alcotest.(check string) "the whole response text is redacted as well"
      "final answer: [REDACTED]" (tail keeper_name))
;;

let test_held_text_is_released_at_the_message_stop () =
  let keeper_name = "held-tail-preview" in
  Keeper_turn_preview.reset ~keeper_name ~now:1. ~redaction:Keeper_secret_redaction.empty;
  Keeper_turn_preview.note_stream ~keeper_name ~now:2. (text_delta "no newline yet");
  Alcotest.(check string) "held while the line is open" "" (tail keeper_name);
  Keeper_turn_preview.note_stream ~keeper_name ~now:3. Agent_core.Types.MessageStop;
  Alcotest.(check string) "released, not dropped, at the stop" "no newline yet"
    (tail keeper_name)
;;

(* Provider chunks can cut a Hangul syllable in two. The redactor passes the
   bytes through in order, so the tail is the text exactly. *)
let test_korean_without_secrets_passes_through_whole () =
  let keeper_name = "korean-preview" in
  let korean = "안녕하세요, 키퍼입니다.\n비밀이 없는 문장은 그대로예요" in
  let cut_in_a_syllable = 7 in
  let second_cut = String.length korean - 5 in
  with_secret_redaction ~keeper_name "unrelated-secret-value-5550" (fun redaction ->
    Keeper_turn_preview.reset ~keeper_name ~now:1. ~redaction;
    List.iteri
      (fun index piece ->
         Keeper_turn_preview.note_stream ~keeper_name ~now:(2. +. float_of_int index)
           (text_delta piece))
      [ String.sub korean 0 cut_in_a_syllable
      ; String.sub korean cut_in_a_syllable (second_cut - cut_in_a_syllable)
      ; String.sub korean second_cut (String.length korean - second_cut)
      ];
    Keeper_turn_preview.note_stream ~keeper_name ~now:5.
      (Agent_core.Types.MessageDelta { stop_reason = Some EndTurn; usage = None });
    Alcotest.(check string) "the tail is the text, byte for byte" korean (tail keeper_name))
;;

let test_no_text_before_a_redaction_is_armed () =
  let keeper_name = "unarmed-preview" in
  Keeper_turn_preview.note_text ~keeper_name ~now:1. "words before any turn";
  Alcotest.(check string) "text without a snapshot is not kept" "" (tail keeper_name)
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
        ; Alcotest.test_case "a secret split across deltas never reaches the tail"
            `Quick test_secret_split_across_deltas_never_reaches_the_tail
        ; Alcotest.test_case "held text is released at the message stop" `Quick
            test_held_text_is_released_at_the_message_stop
        ; Alcotest.test_case "Korean without secrets passes through whole" `Quick
            test_korean_without_secrets_passes_through_whole
        ; Alcotest.test_case "no text is kept before a redaction is armed" `Quick
            test_no_text_before_a_redaction_is_armed
        ] )
    ]
;;
