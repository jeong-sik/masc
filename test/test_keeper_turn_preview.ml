open Masc

(* The live-glance plane behind the Answering overlay's preview panel.
   Pins the UTF-8 tail cut, the blank-text guard, that a tool note
   never erases the last visible words, and that the tail the turns route
   serves is redacted across delta boundaries. *)

let reset keeper_name ~now =
  Keeper_turn_preview.reset ~execution_scope:None ~turn_ref:None ~keeper_name ~now ~redaction:Keeper_secret_redaction.empty
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
  let writer = Some (reset "tail-keeper" ~now:0.) in
  Keeper_turn_preview.note_text ~writer ~now:1. hangul;
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
  let writer = Some (reset "blank-keeper" ~now:0.) in
  Keeper_turn_preview.note_text ~writer ~now:1. "words";
  Keeper_turn_preview.note_text ~writer ~now:2. "   ";
  match Keeper_turn_preview.current ~keeper_name:"blank-keeper" with
  | None -> Alcotest.fail "entry vanished"
  | Some preview ->
    Alcotest.(check string) "a tool-only turn keeps the last visible words"
      "words" preview.Keeper_turn_preview.text_tail
;;

let test_tool_note_keeps_text_and_text_keeps_tool () =
  let writer = Some (reset "mix-keeper" ~now:0.) in
  Keeper_turn_preview.note_text ~writer ~now:1. "drafting";
  Keeper_turn_preview.note_tool ~writer ~now:2.
    "Execute";
  (match Keeper_turn_preview.current ~keeper_name:"mix-keeper" with
   | Some { Keeper_turn_preview.text_tail; last_tool; _ } ->
     Alcotest.(check string) "tool note kept the text" "drafting" text_tail;
     Alcotest.(check (option string)) "and recorded the tool"
       (Some "Execute") last_tool
   | None -> Alcotest.fail "entry vanished");
  Keeper_turn_preview.note_text ~writer ~now:3. "still going";
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
  let writer = Some (reset keeper_name ~now:1.) in
  Keeper_turn_preview.note_attempt ~writer ~now:2. ~runtime_id:"claude";
  Alcotest.(check bool) "silent provider wait is visible" true
    (Astring.String.is_infix ~affix:"waiting for provider response"
      (Keeper_turn_preview.status_text (current ())));
  Keeper_turn_preview.note_failure ~writer ~now:3. ~runtime_id:"claude" "401 invalid key";
  Keeper_turn_preview.note_attempt ~writer ~now:4. ~runtime_id:"glm";
  let switched = Keeper_turn_preview.status_text (current ()) in
  Alcotest.(check bool) "new provider and failure both visible" true
    (Astring.String.is_infix ~affix:"glm" switched && Astring.String.is_infix ~affix:"401" switched);
  Keeper_turn_preview.note_stream ~writer ~now:5. (text_delta "working\n");
  Alcotest.(check string) "a finished line appears before the turn completes"
    "working\n" (current ()).text_tail;
  Keeper_turn_preview.note_tool ~writer ~now:6. "Execute";
  Alcotest.(check bool) "last observed tool visible" true
    (Astring.String.is_infix ~affix:"last observed tool: Execute" (Keeper_turn_preview.status_text (current ())));
  Keeper_turn_preview.note_tool ~writer ~now:7. "Execute";
  Alcotest.(check bool) "a returned tool is never labelled running" false
    (Astring.String.is_infix ~affix:"tool running" (Keeper_turn_preview.status_text (current ())));
  let _writer = reset keeper_name ~now:8. in
  Alcotest.(check string) "new turn cannot inherit old output" "" (current ()).text_tail;
  Alcotest.(check (option string)) "new turn cannot inherit old failure" None (current ()).last_failure
;;

let test_overlapping_and_rejected_tools_remain_observations () =
  let keeper_name = "overlapping-tools" in
  let current () = Option.get (Keeper_turn_preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  Keeper_turn_preview.note_stream ~writer ~now:1.5
    (Agent_core.Types.ContentBlockStart { index=1; content_type="tool_use"; tool_id=Some "dynamic"; tool_name=Some "MCP" });
  Alcotest.(check (option string)) "official-client dynamic tool is visible" (Some "MCP") (current ()).last_tool;
  Keeper_turn_preview.note_failure ~writer ~now:1.6 ~runtime_id:"claude" (String.make 10000 'x');
  Alcotest.(check bool) "diagnostic cannot flood the light poll" true
    (String.length (Option.get (current ()).last_failure) < 300);
  let writer = Some (reset keeper_name ~now:1.7) in
  (* The same hook can run before validation rejects Skill. *)
  Keeper_turn_preview.note_tool ~writer ~now:2. "Skill";
  Alcotest.(check string) "a request does not claim execution"
    "tool activity observed · last observed tool: Skill"
    (Keeper_turn_preview.status_text (current ()));
  (* A starts, B starts, A returns. A is the latest observation, not a claim
     that A is running or that B stopped. No shared in-flight slot is cleared. *)
  List.iteri (fun index tool ->
    Keeper_turn_preview.note_tool ~writer ~now:(3. +. float_of_int index) tool)
    ["A"; "B"; "A"];
  Alcotest.(check string) "interleaved returns keep their historical meaning"
    "tool activity observed · last observed tool: A"
    (Keeper_turn_preview.status_text (current ()));
  Keeper_turn_preview.note_failure ~writer ~now:6. ~runtime_id:"claude" "rejected";
  Alcotest.(check (option string)) "failed attempt drops tool observation" None
    (current ()).last_tool;
  Keeper_turn_preview.note_attempt ~writer ~now:7. ~runtime_id:"glm";
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
    let writer = Some (Keeper_turn_preview.reset ~execution_scope:None ~turn_ref:None ~keeper_name ~now:1. ~redaction) in
    Keeper_turn_preview.note_stream ~writer ~now:2. (text_delta first);
    Alcotest.(check string) "an unfinished line is held back" "" (tail keeper_name);
    Alcotest.(check bool) "while the activity already shows the response" true
      (contains
         (Keeper_turn_preview.status_text
            (Option.get (Keeper_turn_preview.current ~keeper_name)))
         "receiving response");
    Keeper_turn_preview.note_stream ~writer ~now:2.2
      (Agent_core.Types.ContentBlockStart
        {index=1;content_type=Runtime_native_tools.stream_content_type;
         tool_id=Some "background";tool_name=Some "Read"});
    Keeper_turn_preview.note_stream ~writer ~now:2.3
      (Agent_core.Types.ContentBlockStop {index=1});
    Alcotest.(check string) "background tool start and end cannot release the prefix"
      "" (tail keeper_name);
    Keeper_turn_preview.note_stream ~writer ~now:3. (text_delta second);
    Alcotest.(check string) "the finished line arrives redacted"
      "deploy with [REDACTED] now\n" (tail keeper_name);
    Alcotest.(check bool) "no part of the secret is served" false
      (contains (tail keeper_name) "secret-9931");
    Keeper_turn_preview.note_text ~writer ~now:4. ("final answer: " ^ secret);
    Alcotest.(check string) "the whole response text is redacted as well"
      "final answer: [REDACTED]" (tail keeper_name))
;;

let test_held_text_is_released_at_the_message_stop () =
  let keeper_name = "held-tail-preview" in
  let writer = Some (Keeper_turn_preview.reset ~execution_scope:None ~turn_ref:None ~keeper_name ~now:1. ~redaction:Keeper_secret_redaction.empty) in
  Keeper_turn_preview.note_stream ~writer ~now:2. (text_delta "no newline yet");
  Alcotest.(check string) "held while the line is open" "" (tail keeper_name);
  Keeper_turn_preview.note_stream ~writer ~now:3. Agent_core.Types.MessageStop;
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
    let writer = Some (Keeper_turn_preview.reset ~execution_scope:None ~turn_ref:None ~keeper_name ~now:1. ~redaction) in
    List.iteri
      (fun index piece ->
         Keeper_turn_preview.note_stream ~writer ~now:(2. +. float_of_int index)
           (text_delta piece))
      [ String.sub korean 0 cut_in_a_syllable
      ; String.sub korean cut_in_a_syllable (second_cut - cut_in_a_syllable)
      ; String.sub korean second_cut (String.length korean - second_cut)
      ];
    Keeper_turn_preview.note_stream ~writer ~now:5.
      (Agent_core.Types.MessageDelta { stop_reason = Some EndTurn; usage = None });
    Alcotest.(check string) "the tail is the text, byte for byte" korean (tail keeper_name))
;;

let test_no_text_before_a_redaction_is_armed () =
  Keeper_turn_preview.note_text ~writer:None ~now:1. "words before any turn";
  Alcotest.(check bool) "unowned text creates no preview" true
    (Keeper_turn_preview.current ~keeper_name:"unarmed-preview" = None)
;;

let test_late_execution_keeps_successor_preview_and_redactor () =
  let keeper_name = "overlapping-preview" in
  with_secret_redaction ~keeper_name "successor-secret" (fun redaction ->
    let config = Workspace.default_config (Filename.get_temp_dir_name ()) in
    let callbacks preview =
      let _, _, _, on_event =
        Keeper_agent_run_turn_helpers.turn_progress_callbacks
          ~preview ~observation_token:None ~config ~keeper_name
          ~downstream:None ~turn_id:1
      in
      Option.get on_event
    in
    let a = Some (reset keeper_name ~now:1.) in
    let emit_a = callbacks a in
    emit_a (text_delta "old unfinished ");
    let b = Some (Keeper_turn_preview.reset ~execution_scope:None ~turn_ref:None ~keeper_name ~now:2. ~redaction) in
    let emit_b = callbacks b in
    Keeper_turn_preview.note_attempt ~writer:b ~now:3. ~runtime_id:"current";
    emit_b (text_delta "successor-");
    let before = Option.get (Keeper_turn_preview.current ~keeper_name) in
    (* An old stream finishing must neither flush B's held secret nor append
       A's held text to B. Tool/failure/final-text writers share the same rule. *)
    emit_a Agent_core.Types.MessageStop;
    emit_a (Agent_core.Types.ContentBlockStart
      { index = 0; content_type = "tool_use"; tool_id = Some "old-tool"
      ; tool_name = Some "Execute" });
    Keeper_turn_preview.note_failure ~writer:a ~now:4. ~runtime_id:"old" "old failure";
    Keeper_turn_preview.note_attempt ~writer:a ~now:5. ~runtime_id:"old-retry";
    Keeper_turn_preview.note_text ~writer:a ~now:6. "old final answer";
    Keeper_turn_preview.note_tool ~writer:a ~now:7. "old tool";
    Keeper_turn_preview.note_stream ~writer:None ~now:8. (text_delta "unowned\n");
    let after = Option.get (Keeper_turn_preview.current ~keeper_name) in
    Alcotest.(check bool) "all old callbacks preserve the displayed snapshot" true
      (before == after);
    emit_b (text_delta "secret\n");
    Alcotest.(check string) "B retains its own held line and secret snapshot"
      "[REDACTED]\n" (tail keeper_name);
    emit_b (Agent_core.Types.ContentBlockStart
      { index = 0; content_type = "native_tool"; tool_id = Some "current-tool"
      ; tool_name = Some "Read" });
    let current = Option.get (Keeper_turn_preview.current ~keeper_name) in
    Alcotest.(check (option string)) "native tool stream updates current preview"
      (Some "Read") current.last_tool;
    emit_b (Agent_core.Types.ContentBlockStart
      { index = 1; content_type = "native_tool"; tool_id = Some "next-tool"
      ; tool_name = Some "Search" });
    emit_b (Agent_core.Types.ContentBlockStop { index = 0 });
    Alcotest.(check (option string)) "native completion keeps exact tool attribution"
      (Some "Read") (Option.get (Keeper_turn_preview.current ~keeper_name)).last_tool)
;;

let test_released_source_position_through_turns_decoder () =
  let name = "source-position" in
  let writer = Some (reset name ~now:0.) in
  let current () = Option.get (Keeper_turn_preview.current ~keeper_name:name) in
  let decoded payload =
    let wire = `Assoc ["schema", `String "masc.keeper_turns.v1";
      "keepers", `List [`Assoc ["keeper_name", `String name; "status", `String "ok";
        "turn", `Assoc ["lane", `String "maintenance"; "interrupt_token", `String "turn";
          "started_at_unix", `Float 0.; "preview", payload]]]] in
    match Tui_decode.decode_keeper_turns wire with
    | Ok [{ktr_state=Keeper_turn_running {preview=Some value; _}; _}] -> value
    | Ok _ -> Alcotest.fail "current preview lost in actual turns decoder"
    | Error error -> Alcotest.fail error in
  let check_position generation total =
    let preview = current () in
    let observed = decoded (Keeper_turn_preview.to_json preview) in
    Alcotest.(check int) "actual wire generation" generation observed.ktp_text_position.kpp_generation;
    Alcotest.(check int) "actual redacted stream byte boundary" total
      (observed.ktp_text_position.kpp_start_byte + String.length observed.ktp_text_tail) in
  Keeper_turn_preview.note_attempt ~writer ~now:1. ~runtime_id:"first";
  let first = String.make 300 'a' ^ "\n" in
  Keeper_turn_preview.note_stream ~writer ~now:2. (text_delta first);
  check_position 1 (String.length first);
  Keeper_turn_preview.note_stream ~writer ~now:3. (text_delta "가나다\n");
  check_position 1 (String.length first + String.length "가나다\n");
  let held = (current ()).text_position in
  Keeper_turn_preview.note_tool ~writer ~now:4. "Read";
  Alcotest.(check bool) "tool cannot advance text position" true ((current ()).text_position=held);
  Keeper_turn_preview.note_stream ~writer ~now:5.
    (ContentBlockDelta {index=0; delta=TextSnapshot "replacement"});
  check_position 2 (String.length "replacement");
  Keeper_turn_preview.note_stream ~writer ~now:6.
    (ContentBlockDelta {index=0; delta=TextSnapshot "replacement"});
  check_position 3 (String.length "replacement");
  List.iteri (fun index text ->
    Keeper_turn_preview.note_stream ~writer ~now:(6.1 +. float_of_int index)
      (ContentBlockDelta {index=0;delta=TextSnapshot text});
    check_position (4 + index) 0;
    let observed = decoded (Keeper_turn_preview.to_json (current ())) in
    Alcotest.(check string) "authoritative empty replacement clears the actual decoded tail"
      "" observed.ktp_text_tail;
    Alcotest.(check int) "empty replacement restarts released source bytes" 0
      observed.ktp_text_position.kpp_start_byte) ["";" \t\n"];
  Keeper_turn_preview.note_attempt ~writer ~now:7. ~runtime_id:"second";
  check_position 6 0;
  Keeper_turn_preview.note_text ~writer ~now:8. "replacement";
  check_position 7 (String.length "replacement");
  with_secret_redaction ~keeper_name:name "exact-secret" (fun redaction ->
    let writer = Some (Keeper_turn_preview.reset ~execution_scope:None ~turn_ref:None ~keeper_name:name ~now:9. ~redaction) in
    Keeper_turn_preview.note_stream ~writer ~now:10. (text_delta "before exact-");
    check_position 0 0;
    Keeper_turn_preview.note_stream ~writer ~now:11. (text_delta "secret after\n");
    let expected = Keeper_secret_redaction.redact_text redaction "before exact-secret after\n" in
    check_position 0 (String.length expected);
    Alcotest.(check bool) "raw secret bytes never counted as visible text" false
      (contains (current ()).text_tail "exact-secret"))
;;

let test_preparation_scopes_are_visible_owned_and_do_not_dispatch () =
  Eio_main.run (fun _ ->
    let module Preview = Keeper_turn_preview in
    let name = "preparation-owner" in
    let writer = Some (reset name ~now:0.) in
    let turn_ref = Ids.Turn_ref.make ~trace_id:"preparation-trace" ~absolute_turn:7 in
    let current () = Option.get (Preview.current ~keeper_name:name) in
    let payload () = Yojson.Safe.Util.member "preparation" (Preview.to_json (current ())) in
    let state () = Yojson.Safe.Util.(payload () |> member "state" |> to_string) in
    let scoped phase operation = Preview.with_preparation_result
        ~writer ~turn_ref:(Some turn_ref) ~phase operation in
    let result = scoped Preview.Tool_preparation (fun () ->
      Alcotest.(check string) "the actual running scope is published before it returns" "active" (state ());
      Alcotest.(check bool) "wire identity is the owner-supplied turn" true
        (Yojson.Safe.Util.member "turn_ref" (payload ()) = Ids.Turn_ref.to_yojson turn_ref);
      let result = scoped Preview.Skill_preparation (fun () ->
        Alcotest.(check bool) "nested Skill preparation owns the live phase" true
          (Option.exists (fun (preparation : Preview.preparation) ->
             preparation.phase = Preview.Skill_preparation
             && preparation.state = Preview.Preparation_active) (current ()).preparation);
        Ok "prepared") in
      Alcotest.(check bool) "completed child restores the active parent" true
        (Option.exists (fun (preparation : Preview.preparation) ->
           preparation.phase = Preview.Tool_preparation
           && preparation.state = Preview.Preparation_active) (current ()).preparation);
      result) in
    Alcotest.(check (result string string)) "observation preserves the result" (Ok "prepared") result;
    Alcotest.(check string) "completion is recorded without implying dispatch" "prepared" (state ());
    Alcotest.(check bool) "no model attempt was invented" true ((current ()).runtime_id = None);
    let spans = Preview.preparation_spans (current ()).preparation_timeline in
    (match spans with
     | [outer;inner] ->
       Alcotest.(check bool) "nested completion keeps both original observations" true
         (outer.preparation.phase=Preview.Tool_preparation
          && inner.preparation.phase=Preview.Skill_preparation
          && inner.parent_scope_id=Some outer.scope_id)
     | _ -> Alcotest.fail "completed nested scope was lost");
    Alcotest.(check bool) "the settled scope carries its own measured span" true
      (match Yojson.Safe.Util.member "elapsed_ns" (payload ()) with `String _ -> true | _ -> false);
    ignore (scoped Preview.Tool_preparation (fun () ->
      Preview.note_attempt ~writer ~now:4. ~runtime_id:"actual-runtime";
      Ok ()));
    Alcotest.(check bool) "late preparation completion cannot replace actual provider activity" true
      ((current ()).preparation = None && (current ()).activity = Preview.Awaiting_response);
    Alcotest.(check (float 0.)) "late finish does not advance the provider activity clock" 4. (current ()).updated_at;
    Alcotest.(check int) "provider activity retains completed preparation observations" 3
      (List.length (Preview.preparation_spans (current ()).preparation_timeline));
    ignore (scoped Preview.Tool_preparation (fun () ->
      let successor = Some (reset name ~now:5.) in
      Preview.note_tool ~writer:successor ~now:6. "actual-tool";
      Ok ()));
    Alcotest.(check (option string)) "old writer cannot replace the successor" (Some "actual-tool")
      (current ()).last_tool;
    Alcotest.(check bool) "successor does not inherit old preparation" true
      ((current ()).preparation = None
       && Preview.preparation_spans (current ()).preparation_timeline = []))
;;

let test_preparation_error_exception_and_cancellation_keep_their_outcomes () =
  Eio_main.run (fun _ ->
    let module Preview = Keeper_turn_preview in
    let name = "preparation-outcomes" in
    let writer = Some (reset name ~now:0.) in
    let scoped operation = Preview.with_preparation_result
        ~writer ~turn_ref:None ~phase:Preview.Context_preparation operation in
    let state () = Yojson.Safe.Util.(Preview.to_json
        (Option.get (Preview.current ~keeper_name:name)) |> member "preparation" |> member "state" |> to_string) in
    let rejected : (unit,string) result = scoped (fun () -> Error "original refusal") in
    Alcotest.(check (result unit string)) "typed error is unchanged" (Error "original refusal") rejected;
    Alcotest.(check string) "refused preparation is no longer active" "rejected" (state ());
    let expected = Failure "private preparation failure" in
    (match scoped (fun () -> raise expected) with
     | _ -> Alcotest.fail "preparation exception was swallowed"
     | exception error -> Alcotest.(check bool) "original exception is preserved" true (error == expected));
    Alcotest.(check string) "raised scope is distinguished from rejection" "raised" (state ());
    let entered,enter = Eio.Promise.create () in
    let never,_ = Eio.Promise.create () in
    Eio.Fiber.first
      (fun () -> ignore (scoped (fun () ->
        Eio.Promise.resolve enter ();
        Eio.Promise.await never;
        Ok ())))
      (fun () -> Eio.Promise.await entered);
    Alcotest.(check string) "cancelled operation leaves a settled cancellation" "cancelled" (state ());
    let json = Preview.to_json ~include_preparation_timeline:true (Option.get (Preview.current ~keeper_name:name)) in
    let outcomes = Preview.preparation_spans
        (Option.get (Preview.current ~keeper_name:name)).preparation_timeline
      |> List.map (fun (span : Preview.preparation_span) -> match span.preparation.state with
          | Preparation_active -> None | Preparation_finished {outcome;_} -> Some outcome) in
    Alcotest.(check bool) "history retains rejection, exception and cancellation separately" true
      (outcomes=[Some Preview.Rejected;Some Preview.Raised;Some Preview.Cancelled]);
    Alcotest.(check bool) "pre-context identity stays unknown" true
      (Yojson.Safe.Util.(json |> member "preparation" |> member "turn_ref") = `Null);
    Alcotest.(check bool) "exception and refusal text are not emitted as preparation metadata" false
      (contains (Yojson.Safe.to_string json) "private preparation failure"
       || contains (Yojson.Safe.to_string json) "original refusal"))
;;

let test_parallel_preparation_lineage_and_actual_wire () =
  Eio_main.run (fun _ ->
    let module Preview = Keeper_turn_preview in
    let keeper_name = "preparation-parallel-lineage" in
    let original = Ids.Turn_ref.make ~trace_id:"parallel-original" ~absolute_turn:3 in
    let owned = Preview.reset ~keeper_name ~execution_scope:None ~turn_ref:(Some original)
        ~now:0. ~redaction:Keeper_secret_redaction.empty in
    let writer = Some owned in
    let scoped phase operation = Preview.with_preparation ~writer ~turn_ref:(Some original) ~phase operation in
    let a_ready,a_enter = Eio.Promise.create () in
    let b_ready,b_enter = Eio.Promise.create () in
    scoped Preview.World_preparation (fun () ->
      Eio.Fiber.pair
        (fun () -> scoped Preview.Context_preparation (fun () ->
          Eio.Promise.resolve a_enter (); Eio.Promise.await b_ready))
        (fun () -> scoped Preview.Skill_preparation (fun () ->
          Eio.Promise.resolve b_enter (); Eio.Promise.await a_ready))) |> ignore;
    let current = Option.get (Preview.current ~keeper_name) in
    (match Preview.preparation_spans current.preparation_timeline with
     | [parent;a;b] ->
       Alcotest.(check bool) "parallel siblings retain the same proven fiber parent" true
         (a.parent_scope_id=Some parent.scope_id && b.parent_scope_id=Some parent.scope_id);
       Alcotest.(check bool) "the original turn reaches every completed observation" true
         (List.for_all (fun (span : Preview.preparation_span) ->
           span.preparation.turn_ref=Some original
           && match span.preparation.state with Preparation_finished _ -> true | Preparation_active -> false)
           [parent;a;b])
     | _ -> Alcotest.fail "parallel scope history is incomplete");
    Alcotest.(check bool) "ordinary turns polling does not serialize unselected history" true
      (Yojson.Safe.Util.member "preparation_timeline" (Preview.to_json current) = `Null);
    let payload = Preview.to_json ~include_preparation_timeline:true current in
    let wire = `Assoc ["schema",`String "masc.keeper_turns.v1";
      "keepers",`List [`Assoc ["keeper_name",`String keeper_name;"status",`String "ok";
        "turn",`Assoc ["lane",`String "maintenance";"interrupt_token",`String "original-slot";
          "started_at_unix",`Float 0.;"turn_ref",Ids.Turn_ref.to_yojson original;"preview",payload]]]] in
    (match Tui_decode.decode_keeper_turns wire with
     | Ok [{ktr_state=Keeper_turn_running {preview=Some decoded;_};_}] ->
       Alcotest.(check bool) "actual turns wire retains all exact observation records" true
         (Preview.preparation_spans (Option.get decoded.ktp_preparation_timeline)
          = Preview.preparation_spans current.preparation_timeline)
     | Ok _ -> Alcotest.fail "actual turns decoder lost the prepared scope history"
     | Error detail -> Alcotest.fail detail);
    let raw = Yojson.Safe.Util.member "preparation_timeline" payload in
    let spans = Yojson.Safe.Util.to_list raw in
    let replace field value = function
      | `Assoc fields -> `Assoc (List.map (fun (key,old) -> key,if key=field then value else old) fields)
      | _ -> Alcotest.fail "span was not encoded as an object" in
    let first = List.hd spans in
    List.iter (fun invalid -> match Preview.preparation_timeline_of_json invalid with
      | Error _ -> () | Ok _ -> Alcotest.fail "invalid scope identity/ancestry was accepted")
      [`Null; `List [first;first]; `List [replace "parent_scope_id" (`Int 42) first];
       `List [replace "scope_id" (`Int (-1)) first];
       `List [match first with `Assoc fields -> `Assoc (("scope_id",`Int 0)::fields) | _ -> first]])
;;

let test_original_preparation_is_durable_after_successor () =
  let module Preview = Keeper_turn_preview in
  let module Observation = Keeper_preparation_runtime_observation in
  let module Manifest = Keeper_runtime_manifest in
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path in
  let base = Filename.temp_dir "preparation-report-" "" in
  Fun.protect ~finally:(fun () -> remove base) (fun () ->
    Eio_main.run (fun _ ->
      let config = Workspace.default_config base in
      let keeper_name = "durable-preparation" in
      let turn_ref = Ids.Turn_ref.make ~trace_id:"original-report-trace" ~absolute_turn:3 in
      let operation_id = match Keeper_operation_id.of_string "original-preparation-operation" with
        | Ok value -> value | Error detail -> Alcotest.fail detail in
      let execution_scope = Keeper_execution_scope_id.direct_operation operation_id in
      let preview = Preview.reset ~keeper_name ~turn_ref:(Some turn_ref)
          ~execution_scope:(Some execution_scope) ~now:0. ~redaction:Keeper_secret_redaction.empty in
      let expected = Error (ref "original returned error") in
      let result = Observation.with_turn ~config ~keeper_name ~preview (fun () ->
        Preview.with_preparation_result ~writer:(Some preview) ~turn_ref:(Some turn_ref)
          ~phase:Preview.World_preparation (fun () ->
            ignore (Preview.with_preparation_result ~writer:(Some preview) ~turn_ref:(Some turn_ref)
              ~phase:Preview.Workspace_memory_preparation (fun () -> Error "unavailable"));
            ignore (reset keeper_name ~now:1.);
            expected)) in
      Alcotest.(check bool) "the exact returned error is preserved" true (result == expected);
      let successor = Option.get (Preview.current ~keeper_name) in
      Alcotest.(check bool) "the displayed successor has no inherited history" true
        (Preview.preparation_timeline_is_empty successor.preparation_timeline);
      let path = Manifest.path_for_trace config ~keeper_name ~trace_id:"original-report-trace" in
      let rows = In_channel.with_open_text path In_channel.input_all
          |> String.split_on_char '\n' |> List.filter (fun row -> row <> "") in
      let row = match rows with
        | [row] -> (match Manifest.decode_persisted_row (Yojson.Safe.from_string row) with
          | Ok (Manifest.Active_row row) -> row
          | Ok (Manifest.Unsupported_row _) -> Alcotest.fail "new event was not registered"
          | Error detail -> Alcotest.fail detail)
        | _ -> Alcotest.fail "the invocation must append exactly one report" in
      Alcotest.(check bool) "report is an observation, not a finished turn" true
        (row.event=Manifest.Preparation_observed && not (Manifest.is_finished_turn [row]));
      let module Scan = Server_dashboard_http_keeper_runtime_manifest_scan in
      let scan = Scan.update_runtime_manifest_scan
          (Scan.make_runtime_manifest_scan ~path ~limit:1 ~scan_line_limit:1 ~scan_scope:"test") row in
      Alcotest.(check int) "the actual runtime lens counts the new observation" 1
        (Hashtbl.find scan.event_counts "preparation_observed");
      Alcotest.(check int) "preparation is not context injection" 0 scan.context_injected_count;
      List.iter (fun edge -> Alcotest.(check bool) "publication time is not a measured preparation edge" true
        Yojson.Safe.Util.(member "started_at" edge = `Null && member "finished_at" edge = `Null))
        (Server_dashboard_http_keeper_runtime_lens_clock_edges.clock_edge_jsons scan);
      let report_json = Yojson.Safe.Util.(Manifest.public_to_json row
          |> member "decision" |> member "preparation_report") in
      let report = match Observation.report_of_json report_json with
        | Ok report -> report | Error detail -> Alcotest.fail detail in
      Alcotest.(check bool) "original execution identity survives durable public projection" true
        (report.turn_ref=Some turn_ref && report.execution_scope=Some execution_scope
         && report.boundary=Observation.Returned);
      (match Preview.preparation_spans report.timeline with
       | [outer; inner] ->
         Alcotest.(check bool) "both failed scopes retain their original lineage" true
           (inner.parent_scope_id=Some outer.scope_id
            && List.for_all (fun (span : Preview.preparation_span) ->
              span.preparation.turn_ref=Some turn_ref && match span.preparation.state with
              | Preview.Preparation_finished {outcome=Preview.Rejected; _} -> true
              | Preview.Preparation_finished _ | Preview.Preparation_active -> false) [outer;inner])
       | _ -> Alcotest.fail "preparation history was lost after replacement");
      let with_unknown = function `Assoc fields -> `Assoc (("private_probe",`String "hidden")::fields)
        | value -> value in
      let decision = Manifest.public_projection_of_decision
          (`Assoc ["preparation_report", with_unknown report_json]) in
      Alcotest.(check bool) "report projection removes undeclared fields" true
        (Yojson.Safe.Util.(decision |> member "preparation_report" |> member "private_probe") = `Null);
      List.iter (fun malformed -> match Observation.report_of_json malformed with
        | Error _ -> () | Ok _ -> Alcotest.fail "malformed report was accepted")
        [with_unknown report_json; `Null]))
;;

let test_preparation_report_preserves_failure_and_cancellation () =
  let module Preview = Keeper_turn_preview in
  let module Observation = Keeper_preparation_runtime_observation in
  Eio_main.run (fun _ ->
    let preview = reset "report-outcomes" ~now:0. in
    let reports = ref [] in
    let observe operation = Observation.with_report ~preview
        ~on_report:(fun report -> reports := report :: !reports) operation in
    let scoped operation = Preview.with_preparation ~writer:(Some preview) ~turn_ref:None
        ~phase:Preview.Context_preparation operation in
    let expected = Failure "original invocation error" in
    (match observe (fun () -> scoped (fun () -> raise expected)) with
     | _ -> Alcotest.fail "original exception was swallowed"
     | exception actual -> Alcotest.(check bool) "original exception identity" true (actual == expected));
    let entered, enter = Eio.Promise.create () in
    let never, _ = Eio.Promise.create () in
    Eio.Fiber.first
      (fun () -> observe (fun () -> scoped (fun () ->
        Eio.Promise.resolve enter (); Eio.Promise.await never)))
      (fun () -> Eio.Promise.await entered);
    (match !reports with
     | [cancelled; raised] ->
       Alcotest.(check bool) "exception and cancellation retain separate boundaries and identities" true
         (cancelled.boundary=Observation.Cancelled && raised.boundary=Observation.Raised
          && cancelled.report_id<>raised.report_id);
       Alcotest.(check int) "earlier report remains an immutable snapshot" 1
         (List.length (Preview.preparation_spans raised.timeline));
       Alcotest.(check int) "later cancellation retains both scope observations" 2
         (List.length (Preview.preparation_spans cancelled.timeline));
       Alcotest.(check bool) "the cancelled scope keeps its actual outcome" true
         (List.exists (fun (span : Preview.preparation_span) -> match span.preparation.state with
           | Preview.Preparation_finished {outcome=Preview.Cancelled; _} -> true
           | Preview.Preparation_finished _ | Preview.Preparation_active -> false)
            (Preview.preparation_spans cancelled.timeline))
     | _ -> Alcotest.fail "exceptional report publication did not settle");
    let unfinished = ref None in
    scoped (fun () -> Observation.with_report ~preview
      ~on_report:(fun report -> unfinished := Some report) (fun () -> ()));
    Alcotest.(check bool) "a scope still active at capture is never fabricated as completed" true
      (List.exists (fun (span : Preview.preparation_span) -> span.preparation.state=Preview.Preparation_active)
         (Preview.preparation_spans (Option.get !unfinished).timeline));
    let returned = ref "original return" in
    let failed_sink () = raise (Failure "observation sink unavailable") in
    let result = Observation.with_report ~preview ~on_report:(fun _ -> failed_sink ()) (fun () -> returned) in
    Alcotest.(check bool) "ordinary sink failure preserves returned value" true (result == returned);
    (match Observation.with_report ~preview ~on_report:(fun _ -> failed_sink ()) (fun () -> raise expected) with
     | _ -> Alcotest.fail "sink failure swallowed the invocation exception"
     | exception actual -> Alcotest.(check bool) "ordinary sink failure preserves original exception" true
         (actual == expected)))
;;

let () =
  Alcotest.run "keeper_turn_preview"
    [ ( "keeper-turn-preview"
      , [ Alcotest.test_case "preparation scopes are visible and keep their actual owner" `Quick
            test_preparation_scopes_are_visible_owned_and_do_not_dispatch
        ; Alcotest.test_case "original preparation remains durable after a successor" `Quick
            test_original_preparation_is_durable_after_successor
        ; Alcotest.test_case "preparation reports preserve failure and cancellation" `Quick
            test_preparation_report_preserves_failure_and_cancellation
        ; Alcotest.test_case "parallel scopes retain original lineage through the actual turns protocol" `Quick
            test_parallel_preparation_lineage_and_actual_wire
        ; Alcotest.test_case "preparation errors, exceptions and cancellation retain their outcomes" `Quick
            test_preparation_error_exception_and_cancellation_keep_their_outcomes
        ; Alcotest.test_case "actual released position through turns decoder" `Quick
            test_released_source_position_through_turns_decoder
        ; Alcotest.test_case "late execution preserves successor preview and redactor" `Quick
            test_late_execution_keeps_successor_preview_and_redactor
        ; Alcotest.test_case "overlapping and rejected tools are observations" `Quick
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
