open Masc

(* The live-glance plane behind the Answering overlay's preview panel.
   Pins the UTF-8 tail cut, the blank-text guard, that a tool note
   never erases the last visible words, and that the tail the turns route
   serves is redacted across delta boundaries. *)

(* No server runs here, so nothing is sent for this workspace. *)
let preview_base_path = "keeper-turn-preview-test"

let reset keeper_name ~now =
  Keeper_turn_preview.reset ~base_path:preview_base_path ~execution_scope:None ~turn_ref:None ~keeper_name ~now ~redaction:Keeper_secret_redaction.empty
;;

let text_delta text =
  Agent_core.Types.ContentBlockDelta { index = 0; delta = TextDelta text }
;;

let thinking_delta text =
  Agent_core.Types.ContentBlockDelta { index = 0; delta = ThinkingDelta text }
;;

let tool_block index tool_id tool_name =
  Agent_core.Types.ContentBlockStart
    { index; content_type = "tool_use"; tool_id; tool_name = Some tool_name }
;;

(* The stream block an official client opens for a tool it runs itself. It
   closes when that run ends, and no tool hook comes for it. *)
let native_tool_block index tool_id tool_name =
  Agent_core.Types.ContentBlockStart
    { index
    ; content_type = Runtime_native_tools.stream_content_type
    ; tool_id
    ; tool_name = Some tool_name
    }
;;

let message_start id = Agent_core.Types.MessageStart { id; model = "m"; usage = None} ;;

let block_stop index = Agent_core.Types.ContentBlockStop { index } ;;

(* A new attempt of the turn, run by an official client or by MASC's own agent
   loop. The loop decides what a tool block's stop means and whether a tool's
   return opens the next response. *)
let client_attempt ?(now = 0.) writer runtime_id =
  Keeper_turn_preview.note_attempt ~writer ~now ~runtime_id
    ~checkpoint_owner:Runtime_execution.Official_client
;;

let loop_attempt ?(now = 0.) writer runtime_id =
  Keeper_turn_preview.note_attempt ~writer ~now ~runtime_id
    ~checkpoint_owner:Runtime_execution.Masc_agent_core
;;

(* The two tool hooks, as the Keeper's agent-core hooks call them. *)
let started ?(tool_use_id = None) writer now tool_name =
  Keeper_turn_preview.note_tool_started ~writer ~now ~tool_use_id ~tool_name ~cohort:None ~reach:None
;;

let finished ?(tool_use_id = None) writer now tool_name =
  Keeper_turn_preview.note_tool_finished ~writer ~now ~tool_use_id ~tool_name
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
  started writer 2. "Execute";
  finished writer 2.5 "Execute";
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
  client_attempt ~now:2. writer "claude";
  Alcotest.(check bool) "silent provider wait is visible" true
    (Astring.String.is_infix ~affix:"waiting for provider response"
      (Keeper_turn_preview.status_text (current ())));
  Keeper_turn_preview.note_failure ~writer ~now:3. ~runtime_id:"claude" "401 invalid key";
  loop_attempt ~now:4. writer "glm";
  let switched = Keeper_turn_preview.status_text (current ()) in
  Alcotest.(check bool) "new provider and failure both visible" true
    (Astring.String.is_infix ~affix:"glm" switched && Astring.String.is_infix ~affix:"401" switched);
  Keeper_turn_preview.note_stream ~writer ~now:5. (text_delta "working\n");
  Alcotest.(check string) "a finished line appears before the turn completes"
    "working\n" (current ()).text_tail;
  started writer 6. "Execute";
  Alcotest.(check bool) "a call that runs is shown running" true
    (contains (Keeper_turn_preview.status_text (current ())) "tool running: Execute");
  finished writer 7. "Execute";
  Alcotest.(check bool) "last observed tool visible" true
    (Astring.String.is_infix ~affix:"last observed tool: Execute" (Keeper_turn_preview.status_text (current ())));
  Alcotest.(check bool) "a returned tool is never labelled running" false
    (Astring.String.is_infix ~affix:"tool running" (Keeper_turn_preview.status_text (current ())));
  let _writer = reset keeper_name ~now:8. in
  Alcotest.(check string) "new turn cannot inherit old output" "" (current ()).text_tail;
  Alcotest.(check (option string)) "new turn cannot inherit old failure" None (current ()).last_failure
;;

(* The provider request after a tool is a wait on the provider. The tool stays
   the last observed tool, and the turn's activity is the wait. *)
let test_a_request_after_a_tool_waits_on_the_provider () =
  let keeper_name = "request-after-tool" in
  let current () = Option.get (Keeper_turn_preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  loop_attempt ~now:2. writer "glm";
  started writer 3. "Execute";
  finished writer 3.5 "Execute";
  Keeper_turn_preview.note_request ~writer ~now:4.;
  Alcotest.(check bool) "the turn waits on the provider" true
    ((current ()).activity = Keeper_turn_preview.Awaiting_response);
  Alcotest.(check (option string)) "the tool stays the last observed tool" (Some "Execute")
    (current ()).last_tool;
  Keeper_turn_preview.note_stream ~writer ~now:5. (text_delta "next\n");
  Alcotest.(check bool) "the request's stream moves the activity on" true
    ((current ()).activity = Keeper_turn_preview.Receiving_response)
;;

(* RFC open-tool-carries-cohort-and-reach D1. The before-tool hook hands the
   call's planned batch to the open tool: a call the stream requested gets it
   when it starts running, and the wire names the batch and whether it runs at
   once. A call no hook has named yet carries none. *)
let test_a_running_tool_carries_its_planned_batch () =
  let keeper_name = "tool-cohort" in
  let current () = Option.get (Keeper_turn_preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  loop_attempt ~now:1. writer "glm";
  Keeper_turn_preview.note_stream ~writer ~now:2. (tool_block 1 (Some "call-a") "Execute");
  Keeper_turn_preview.note_stream ~writer ~now:2. (tool_block 2 (Some "call-b") "WebFetch");
  let cohort_of id =
    List.find_map
      (function
        | Keeper_turn_preview.Tool_open { tool_use_id = Some open_id; cohort; _ }
          when String.equal open_id id -> Some cohort
        | Keeper_turn_preview.Tool_open _ | Keeper_turn_preview.Response_open _ -> None)
      (current ()).open_activities
  in
  Alcotest.(check bool) "a requested call has no batch yet" true
    (cohort_of "call-a" = Some None);
  let batch =
    { Agent_core.Tool_contract.planned_index = 0
    ; batch_index = 0
    ; batch_size = 2
    ; execution_mode = Agent_core.Tool_contract.Concurrent
    }
  in
  Keeper_turn_preview.note_tool_started ~writer ~now:3. ~tool_use_id:(Some "call-a")
    ~tool_name:"Execute" ~cohort:(Some batch) ~reach:(Some Keeper_tool_reach.Sandbox);
  Keeper_turn_preview.note_tool_started ~writer ~now:3. ~tool_use_id:(Some "call-b")
    ~tool_name:"WebFetch" ~cohort:(Some { batch with planned_index = 1 })
    ~reach:(Some Keeper_tool_reach.Network);
  Alcotest.(check bool) "the started call carries its batch" true
    (cohort_of "call-a" = Some (Some batch));
  Alcotest.(check bool) "its batch peer carries the same batch" true
    (match cohort_of "call-b" with
     | Some (Some { batch_index = 0; batch_size = 2; _ }) -> true
     | Some _ | None -> false);
  let wire_cohorts =
    Yojson.Safe.Util.(
      Keeper_turn_preview.to_json (current ())
      |> member "open_activities" |> to_list
      |> List.map (member "cohort"))
  in
  Alcotest.(check (list string)) "the wire names the batch and that it runs at once"
    [ {|{"batch_index":0,"batch_size":2,"concurrent":true}|}
    ; {|{"batch_index":0,"batch_size":2,"concurrent":true}|}
    ]
    (List.map Yojson.Safe.to_string wire_cohorts);
  (* RFC D2. The hook names where each call reaches. *)
  Alcotest.(check (list string)) "the wire names where each call reaches"
    [ {|"sandbox"|}; {|"network"|} ]
    Yojson.Safe.Util.(
      Keeper_turn_preview.to_json (current ())
      |> member "open_activities" |> to_list
      |> List.map (fun item -> Yojson.Safe.to_string (member "reach" item)))
;;

(* RFC D2/D3. An add-on tool's reach is its MCP openWorldHint; an add-on that
   leaves the hint out has no reach rather than a guessed one. *)
let test_an_addon_tool_reaches_where_its_open_world_hint_says () =
  let reach_of hint =
    let annotations =
      Option.map
        (fun open_world_hint ->
           { Mcp_protocol.Mcp_types.title = None
           ; read_only_hint = None
           ; destructive_hint = None
           ; idempotent_hint = None
           ; open_world_hint
           })
        hint
    in
    let tool = Mcp_protocol.Mcp_types.make_tool ~name:"addon_tool" ?annotations () in
    let export =
      Lane_addon_tool_export.create
        ~owner:(Lane_addon_tool_export.create_owner ~instance_id:"addon-1")
        ~tool
    in
    Keeper_tool_descriptor.reach_of_handler (Keeper_tool_descriptor.Tool_lane_addon export)
  in
  let show = Option.map Keeper_tool_reach.to_wire in
  Alcotest.(check (option string)) "open world reaches the network" (Some "network")
    (show (reach_of (Some (Some true))));
  Alcotest.(check (option string)) "closed world stays on the host" (Some "sandbox")
    (show (reach_of (Some (Some false))));
  Alcotest.(check (option string)) "no hint is not known" None
    (show (reach_of (Some None)));
  Alcotest.(check (option string)) "no annotations is not known" None
    (show (reach_of None))
;;

(* A call that validation rejects never opens, so it is only the last observed
   tool. Two calls that overlap stay open one by one: A returning says nothing
   about B. *)
let test_a_rejected_tool_never_runs_and_overlapping_tools_stay_open () =
  let keeper_name = "overlapping-tools" in
  let current () = Option.get (Keeper_turn_preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  Keeper_turn_preview.note_stream ~writer ~now:1.5 (tool_block 1 (Some "dynamic") "MCP");
  Alcotest.(check (option string)) "official-client dynamic tool is visible" (Some "MCP") (current ()).last_tool;
  Keeper_turn_preview.note_failure ~writer ~now:1.6 ~runtime_id:"claude" (String.make 10000 'x');
  Alcotest.(check bool) "diagnostic cannot flood the light poll" true
    (String.length (Option.get (current ()).last_failure) < 300);
  let writer = Some (reset keeper_name ~now:1.7) in
  (* The same hook can run before validation rejects Skill. *)
  finished writer 2. "Skill";
  Alcotest.(check string) "a call that never opened does not claim execution"
    "waiting for provider response · last observed tool: Skill"
    (Keeper_turn_preview.status_text (current ()));
  Alcotest.(check bool) "a return that ended no call opens no response" true
    ((current ()).open_activities = []);
  started writer 3. "A";
  started writer 4. "B";
  finished writer 5. "A";
  Alcotest.(check string) "A returned and B is still running"
    "tool running: B · last observed tool: A"
    (Keeper_turn_preview.status_text (current ()));
  Keeper_turn_preview.note_failure ~writer ~now:6. ~runtime_id:"claude" "rejected";
  Alcotest.(check (option string)) "failed attempt drops tool observation" None
    (current ()).last_tool;
  Alcotest.(check bool) "failed attempt ends the call that was open" true
    ((current ()).open_activities = []);
  Keeper_turn_preview.note_failure ~writer ~now:6. ~runtime_id:"claude" "rejected";
  Alcotest.(check (option string)) "failed attempt drops tool observation" None
    (current ()).last_tool;
  loop_attempt ~now:7. writer "glm";
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
    let writer = Some (Keeper_turn_preview.reset ~base_path:preview_base_path ~execution_scope:None ~turn_ref:None ~keeper_name ~now:1. ~redaction) in
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
  let writer = Some (Keeper_turn_preview.reset ~base_path:preview_base_path ~execution_scope:None ~turn_ref:None ~keeper_name ~now:1. ~redaction:Keeper_secret_redaction.empty) in
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
    let writer = Some (Keeper_turn_preview.reset ~base_path:preview_base_path ~execution_scope:None ~turn_ref:None ~keeper_name ~now:1. ~redaction) in
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
          ~downstream:None
      in
      Option.get on_event
    in
    let a = Some (reset keeper_name ~now:1.) in
    let emit_a = callbacks a in
    emit_a (text_delta "old unfinished ");
    let b = Some (Keeper_turn_preview.reset ~base_path:preview_base_path ~execution_scope:None ~turn_ref:None ~keeper_name ~now:2. ~redaction) in
    let emit_b = callbacks b in
    loop_attempt ~now:3. b "current";
    emit_b (text_delta "successor-");
    let before = Option.get (Keeper_turn_preview.current ~keeper_name) in
    (* An old stream finishing must neither flush B's held secret nor append
       A's held text to B. Tool/failure/final-text writers share the same rule. *)
    emit_a Agent_core.Types.MessageStop;
    emit_a (Agent_core.Types.ContentBlockStart
      { index = 0; content_type = "tool_use"; tool_id = Some "old-tool"
      ; tool_name = Some "Execute" });
    Keeper_turn_preview.note_failure ~writer:a ~now:4. ~runtime_id:"old" "old failure";
    loop_attempt ~now:5. a "old-retry";
    Keeper_turn_preview.note_text ~writer:a ~now:6. "old final answer";
    started a 7. "old tool";
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
  let check_position generation total =
    let preview = current () in
    let json = Keeper_turn_preview.to_json preview in
    let open Yojson.Safe.Util in
    let pos = json |> member "text_position" in
    let obs_gen = pos |> member "generation" |> to_int in
    let obs_start = pos |> member "start_byte" |> to_int in
    let obs_tail = json |> member "text_tail" |> to_string in
    Alcotest.(check int) "actual wire generation" generation obs_gen;
    Alcotest.(check int) "actual redacted stream byte boundary" total
      (obs_start + String.length obs_tail) in
  loop_attempt ~now:1. writer "first";
  let first = String.make 300 'a' ^ "\n" in
  Keeper_turn_preview.note_stream ~writer ~now:2. (text_delta first);
  check_position 1 (String.length first);
  Keeper_turn_preview.note_stream ~writer ~now:3. (text_delta "가나다\n");
  check_position 1 (String.length first + String.length "가나다\n");
  let held = (current ()).text_position in
  finished writer 4. "Read";
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
    let observed = Keeper_turn_preview.to_json (current ()) in
    Alcotest.(check string) "authoritative empty replacement clears the actual wire tail"
      "" Yojson.Safe.Util.(observed |> member "text_tail" |> to_string);
    Alcotest.(check int) "empty replacement restarts released source bytes" 0
      Yojson.Safe.Util.(observed |> member "text_position" |> member "start_byte" |> to_int)) ["";" \t\n"];
  loop_attempt ~now:7. writer "second";
  check_position 6 0;
  Keeper_turn_preview.note_text ~writer ~now:8. "replacement";
  check_position 7 (String.length "replacement");
  with_secret_redaction ~keeper_name:name "exact-secret" (fun redaction ->
    let writer = Some (Keeper_turn_preview.reset ~base_path:preview_base_path ~execution_scope:None ~turn_ref:None ~keeper_name:name ~now:9. ~redaction) in
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
      loop_attempt ~now:4. writer "actual-runtime";
      Ok ()));
    Alcotest.(check bool) "late preparation completion cannot replace actual provider activity" true
      ((current ()).preparation = None && (current ()).activity = Preview.Awaiting_response);
    Alcotest.(check (float 0.)) "late finish does not advance the provider activity clock" 4. (current ()).updated_at;
    Alcotest.(check int) "provider activity retains completed preparation observations" 3
      (List.length (Preview.preparation_spans (current ()).preparation_timeline));
    ignore (scoped Preview.Tool_preparation (fun () ->
      let successor = Some (reset name ~now:5.) in
      Preview.note_tool_started ~writer:successor ~now:6. ~tool_use_id:None ~tool_name:"actual-tool" ~cohort:None ~reach:None;
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
    let owned = Preview.reset ~base_path:preview_base_path ~keeper_name ~execution_scope:None ~turn_ref:(Some original)
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
    let raw = Yojson.Safe.Util.member "preparation_timeline" payload in
    (match Preview.preparation_timeline_of_json raw with
     | Ok decoded_timeline ->
       Alcotest.(check bool) "actual turns wire retains all exact observation records" true
         (Preview.preparation_spans decoded_timeline
          = Preview.preparation_spans current.preparation_timeline)
     | Error detail -> Alcotest.fail detail);
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
      let preview = Preview.reset ~base_path:preview_base_path ~keeper_name ~turn_ref:(Some turn_ref)
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

(* --- Open work: what started in the turn and has not ended ---------------
   RFC turn-activity-is-open-work §8. Each case is one transition of one
   activity, driven by the server events and hooks that really reach it. *)

let test_a_tool_is_open_from_its_call_to_its_return () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-tool-lifecycle" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let call stage since =
    [ Preview.Tool_open
        { tool_use_id = Some "toolu_a"; tool_name = "Execute"; stage
        ; started_at = 3.; since; cohort = None; reach = None } ]
  in
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:3. (tool_block 1 (Some "toolu_a") "Execute");
  Alcotest.(check string) "while the model is still answering, both are named"
    "waiting for provider response · tool called: Execute · last observed tool: Execute"
    (Preview.status_text (current ()));
  Preview.note_stream ~writer ~now:4. (block_stop 1);
  Preview.note_stream ~writer ~now:5. Agent_core.Types.MessageStop;
  Alcotest.(check string) "the model's call is open and is not running yet"
    "tool called: Execute · last observed tool: Execute"
    (Preview.status_text (current ()));
  Alcotest.(check bool) "the call outlives the response that made it" true
    ((current ()).open_activities = call Preview.Tool_requested 3.);
  started ~tool_use_id:(Some "toolu_a") writer 6. "Execute";
  Alcotest.(check bool) "the before-tool hook is where it runs" true
    ((current ()).open_activities = call Preview.Tool_executing 6.);
  Alcotest.(check string) "and the status says so"
    "tool running: Execute · last observed tool: Execute"
    (Preview.status_text (current ()));
  started ~tool_use_id:(Some "toolu_a") writer 6.5 "Execute";
  Alcotest.(check bool) "hearing the hook twice moves nothing" true
    ((current ()).open_activities = call Preview.Tool_executing 6.);
  finished ~tool_use_id:(Some "toolu_a") writer 7. "Execute";
  Alcotest.(check bool) "the return ends the call. The agent loop opens the next response at its own request" true
    ((current ()).open_activities = []);
  Alcotest.(check string) "the turn is back to waiting and keeps which tool it ran"
    "waiting for provider response · last observed tool: Execute"
    (Preview.status_text (current ()));
  Preview.note_request ~writer ~now:8.;
  Alcotest.(check bool) "the request opens the response with the request's clock" true
    ((current ()).open_activities
     = [ Preview.Response_open { channel = Preview.No_content; started_at = 8.; since = 8. } ])
;;

let test_reasoning_and_answer_are_two_channels_of_one_response () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-response-channels" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let response channel since =
    [ Preview.Response_open { channel; started_at = 2.; since } ]
  in
  Preview.note_request ~writer ~now:2.;
  Alcotest.(check bool) "the request opens a response with nothing in it yet" true
    ((current ()).open_activities = response Preview.No_content 2.);
  Alcotest.(check string) "which is a wait" "waiting for provider response"
    (Preview.status_text (current ()));
  Preview.note_stream ~writer ~now:2.5
    (Agent_core.Types.MessageStart { id = "msg_1"; model = "m"; usage = None });
  Alcotest.(check bool) "the message start does not open a second response" true
    ((current ()).open_activities = response Preview.No_content 2.);
  Preview.note_stream ~writer ~now:3. (thinking_delta "weighing");
  Alcotest.(check string) "reasoning is its own channel" "receiving reasoning"
    (Preview.status_text (current ()));
  Preview.note_stream ~writer ~now:4. (thinking_delta " options");
  Alcotest.(check bool) "more of the same channel moves nothing" true
    ((current ()).open_activities = response Preview.Thinking 3.);
  Preview.note_stream ~writer ~now:5. (text_delta "the answer");
  Alcotest.(check string) "the answer is another channel" "receiving response"
    (Preview.status_text (current ()));
  Alcotest.(check bool) "of the response that opened at the request" true
    ((current ()).open_activities = response Preview.Text 5.);
  Preview.note_stream ~writer ~now:6. Agent_core.Types.MessageStop;
  Alcotest.(check bool) "the message stop ends the response" true
    ((current ()).open_activities = []);
  Alcotest.(check bool) "so the turn no longer says it is receiving" true
    ((current ()).activity = Preview.Awaiting_response)
;;

let test_parallel_tools_stay_open_one_by_one () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-parallel-tools" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let call id started_at since =
    Preview.Tool_open
      { tool_use_id = Some id; tool_name = "Read"; stage = Preview.Tool_executing
      ; started_at; since; cohort = None; reach = None }
  in
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:3. (tool_block 1 (Some "a") "Read");
  Preview.note_stream ~writer ~now:3.5 (block_stop 1);
  Preview.note_stream ~writer ~now:4. (tool_block 2 (Some "b") "Read");
  Preview.note_stream ~writer ~now:4.5 (block_stop 2);
  Preview.note_stream ~writer ~now:5. Agent_core.Types.MessageStop;
  started ~tool_use_id:(Some "a") writer 6. "Read";
  started ~tool_use_id:(Some "b") writer 6.5 "Read";
  Alcotest.(check bool) "two calls of one tool are two open activities" true
    ((current ()).open_activities = [ call "a" 3. 6.; call "b" 4. 6.5 ]);
  finished ~tool_use_id:(Some "a") writer 7. "Read";
  Alcotest.(check bool) "the first returning leaves the second open" true
    ((current ()).open_activities = [ call "b" 4. 6.5 ]);
  finished ~tool_use_id:(Some "b") writer 8. "Read";
  Alcotest.(check bool) "the second ends on its own return" true
    ((current ()).open_activities = [])
;;

let test_a_late_return_ends_only_its_own_call () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-late-return" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let call id name since =
    Preview.Tool_open
      { tool_use_id = id; tool_name = name; stage = Preview.Tool_executing
      ; started_at = since; since; cohort = None; reach = None }
  in
  started ~tool_use_id:(Some "old") writer 2. "Execute";
  finished ~tool_use_id:(Some "old") writer 3. "Execute";
  started ~tool_use_id:(Some "new") writer 4. "Execute";
  finished ~tool_use_id:(Some "old") writer 5. "Execute";
  Alcotest.(check bool) "a return that belongs to an ended call ends nothing else" true
    ((current ()).open_activities = [ call (Some "new") "Execute" 4. ]);
  started writer 6. "Search";
  started writer 7. "Search";
  finished writer 8. "Search";
  Alcotest.(check bool) "with no ids the oldest call of that name is the one that ended" true
    ((current ()).open_activities = [ call (Some "new") "Execute" 4.; call None "Search" 7. ])
;;

let test_starting_an_anonymous_stream_tool_records_its_hook_id () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-tools-adopt-id" in
  let writer = Some (reset keeper_name ~now:1.) in
  let tool_ids () =
    (Option.get (Preview.current ~keeper_name)).open_activities
    |> List.filter_map (function
         | Preview.Tool_open tool -> tool.tool_use_id
         | Preview.Response_open _ -> None)
  in
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:3. (tool_block 1 None "Search");
  started ~tool_use_id:(Some "a") writer 4. "Search";
  started ~tool_use_id:(Some "a") writer 5. "Search";
  started ~tool_use_id:(Some "b") writer 6. "Search";
  Alcotest.(check (list string)) "same name keeps the two distinct hook ids"
    ["a"; "b"] (tool_ids ());
  finished ~tool_use_id:(Some "b") writer 7. "Search";
  Alcotest.(check (list string)) "the identified return leaves the other call open"
    ["a"] (tool_ids ())
;;

let test_a_new_attempt_a_failure_and_a_new_request_end_open_work () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-work-ends" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  started writer 2. "Execute";
  Preview.note_request ~writer ~now:3.;
  Alcotest.(check bool) "every earlier call settled before a new request" true
    ((current ()).open_activities
     = [ Preview.Response_open { channel = Preview.No_content; started_at = 3.; since = 3. } ]);
  started writer 4. "Execute";
  loop_attempt ~now:5. writer "glm";
  Alcotest.(check bool) "a new attempt ends what the old one left open" true
    ((current ()).open_activities = []);
  started writer 6. "Execute";
  Preview.note_failure ~writer ~now:7. ~runtime_id:"glm" "429";
  Alcotest.(check bool) "a failed attempt ends it too" true ((current ()).open_activities = []);
  Alcotest.(check bool) "and the turn says it failed" true ((current ()).activity = Preview.Failed)
;;

let test_the_wire_carries_the_open_work () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-work-wire" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:3. (tool_block 1 (Some "toolu_a") "Execute");
  Preview.note_stream ~writer ~now:3.5 (block_stop 1);
  Preview.note_stream ~writer ~now:4. Agent_core.Types.MessageStop;
  Preview.note_stream ~writer ~now:4.5 (tool_block 2 None "Search");
  started ~tool_use_id:(Some "toolu_a") writer 5. "Execute";
  let json = Preview.to_json (current ()) in
  Alcotest.(check bool) "a tool that runs is the turn's activity" true
    (Yojson.Safe.Util.member "activity" json = `String "tool");
  Alcotest.(check bool) "each open activity travels with its kind, stage and clocks" true
    (Yojson.Safe.Util.member "open_activities" json
     = `List
         [ `Assoc
             [ "kind", `String "tool"; "tool_use_id", `String "toolu_a"
             ; "name", `String "Execute"; "stage", `String "executing"
             ; "started_at_unix", `Float 3.; "since_unix", `Float 5.
             ; "cohort", `Null; "reach", `Null ]
         ; `Assoc
             [ "kind", `String "tool"; "tool_use_id", `Null
             ; "name", `String "Search"; "stage", `String "requested"
             ; "started_at_unix", `Float 4.5; "since_unix", `Float 4.5
             ; "cohort", `Null; "reach", `Null ] ]);
  Alcotest.(check string) "the status names them in order"
    "tool running: Execute · tool called: Search · last observed tool: Execute"
    (Yojson.Safe.Util.(member "status_text" json |> to_string))
;;

let test_a_tool_the_stream_never_showed_opens_at_its_hook () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-tool-without-stream" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  Preview.note_request ~writer ~now:2.;
  started ~tool_use_id:(Some "late") writer 3. "Execute";
  Alcotest.(check bool) "the hook is the first word of the call, and the message that called it is over" true
    ((current ()).open_activities
     = [ Preview.Tool_open
           { tool_use_id = Some "late"; tool_name = "Execute"
           ; stage = Preview.Tool_executing; started_at = 3.; since = 3.; cohort = None; reach = None } ]);
  Alcotest.(check string) "the turn says the tool runs"
    "tool running: Execute · last observed tool: Execute"
    (Preview.status_text (current ()));
  Alcotest.(check bool) "which is the turn's activity" true
    ((current ()).activity = Preview.Tool_observed);
  finished ~tool_use_id:(Some "late") writer 4. "Execute";
  Alcotest.(check bool) "its return ends the call" true ((current ()).open_activities = [])
;;

(* In MASC's own agent loop a request goes out before every model message, and
   a tool block is only the model's call: the gates before the run, an
   approval included, come after its stop. So the block's stop ends nothing,
   and the next response opens at the next request with that request's clock. *)
let test_in_the_agent_loop_a_tool_block_is_only_the_call () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "loop-tool-block" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let call stage since =
    Preview.Tool_open
      { tool_use_id = Some "call_1"; tool_name = "Execute"; stage; started_at = 3.; since; cohort = None; reach = None }
  in
  let response since =
    Preview.Response_open { channel = Preview.No_content; started_at = since; since }
  in
  loop_attempt ~now:1.5 writer "glm";
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:3. (tool_block 1 (Some "call_1") "Execute");
  Preview.note_stream ~writer ~now:4. (block_stop 1);
  Alcotest.(check string) "the model finished the call, and the gates may still be holding it"
    "glm · waiting for provider response · tool called: Execute · last observed tool: Execute"
    (Preview.status_text (current ()));
  Alcotest.(check bool) "so the block's stop leaves the call open" true
    ((current ()).open_activities = [ response 2.; call Preview.Tool_requested 3. ]);
  started ~tool_use_id:(Some "call_1") writer 5. "Execute";
  Alcotest.(check bool) "the before-tool hook is where it runs, and the message that called it is over" true
    ((current ()).open_activities = [ call Preview.Tool_executing 5. ]);
  finished ~tool_use_id:(Some "call_1") writer 6. "Execute";
  Alcotest.(check bool) "its return opens no response" true ((current ()).open_activities = []);
  Preview.note_request ~writer ~now:20.;
  Alcotest.(check bool) "the next request does, with its own clock" true
    ((current ()).open_activities = [ response 20. ])
;;

(* An official client's turn is one message boundary around many model
   messages and tool runs: before_turn, MessageStart and MessageStop each come
   once, and after_turn runs when the turn is over. Measured on 2026-11-25,
   the first request's response stayed open under every tool, so between tools
   the screen showed that response's clock and its last channel. *)
let test_an_official_client_turn_waits_on_a_new_response_after_each_tool () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-official-client-turn" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let waiting since =
    [ Preview.Response_open { channel = Preview.No_content; started_at = since; since } ]
  in
  client_attempt ~now:1.5 writer "codex";
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:2.5 (message_start "turn_1");
  Preview.note_stream ~writer ~now:3. (text_delta "checking");
  Preview.note_stream ~writer ~now:130. (tool_block 1 (Some "call_1") "Execute");
  Alcotest.(check string) "a call the model is still making leaves the answer open"
    "codex · receiving response · tool called: Execute · last observed tool: Execute"
    (Preview.status_text (current ()));
  started ~tool_use_id:(Some "call_1") writer 131. "Execute";
  Alcotest.(check string) "the words before the call are not an open answer while it runs"
    "codex · tool running: Execute · last observed tool: Execute"
    (Preview.status_text (current ()));
  finished ~tool_use_id:(Some "call_1") writer 133.5 "Execute";
  Alcotest.(check bool) "the return opens the next response, empty and counted from here" true
    ((current ()).open_activities = waiting 133.5);
  (* The client's stream closes the block after the call returned. *)
  Preview.note_stream ~writer ~now:134. (block_stop 1);
  Alcotest.(check bool) "the block closing behind the call leaves that response alone" true
    ((current ()).open_activities = waiting 133.5);
  Alcotest.(check string) "so the turn waits, and does not answer on the strength of old words"
    "codex · waiting for provider response · last observed tool: Execute"
    (Preview.status_text (current ()));
  Preview.note_stream ~writer ~now:140. (text_delta "the result says");
  Alcotest.(check bool) "words that arrive give it their channel and clock" true
    ((current ()).open_activities
     = [ Preview.Response_open { channel = Preview.Text; started_at = 133.5; since = 140. } ]);
  Preview.note_stream ~writer ~now:141. (tool_block 2 (Some "call_2") "Execute");
  started ~tool_use_id:(Some "call_2") writer 142. "Execute";
  finished ~tool_use_id:(Some "call_2") writer 145. "Execute";
  Preview.note_stream ~writer ~now:146. (block_stop 2);
  Alcotest.(check bool) "after the second call the turn waits again, from that return" true
    ((current ()).open_activities = waiting 145.);
  Preview.note_stream ~writer ~now:150. Agent_core.Types.MessageStop;
  Preview.note_text ~writer ~now:150.5 "final words";
  Alcotest.(check bool) "the turn's end leaves nothing open" true
    ((current ()).open_activities = []);
  Alcotest.(check string) "and keeps the answer" "final words" (current ()).text_tail
;;

(* In an official client's attempt a tool block wraps the host's whole call. A
   gate that refuses the call leaves no after-tool hook, so the block's stop is
   what ends it. Left open, the call read as a running tool for the rest of
   the turn: the dashboard reads only [activity]. *)
let test_an_official_client_tool_block_is_the_whole_call () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "client-tool-block" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let waiting since =
    [ Preview.Response_open { channel = Preview.No_content; started_at = since; since } ]
  in
  client_attempt ~now:1.5 writer "codex";
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:3. (tool_block 1 (Some "refused") "Write");
  Alcotest.(check string) "the model called a tool"
    "codex · waiting for provider response · tool called: Write · last observed tool: Write"
    (Preview.status_text (current ()));
  Preview.note_stream ~writer ~now:5. (block_stop 1);
  Alcotest.(check bool) "the block stopped and no hook came: the call is over, and the message that made it too" true
    ((current ()).open_activities = waiting 5.);
  Alcotest.(check string) "so the turn waits from here, and no tool claims to run"
    "codex · waiting for provider response · last observed tool: Write"
    (Preview.status_text (current ()));
  Preview.note_stream ~writer ~now:10. (tool_block 2 (Some "ran") "Execute");
  started ~tool_use_id:(Some "ran") writer 11. "Execute";
  finished ~tool_use_id:(Some "ran") writer 13. "Execute";
  Alcotest.(check bool) "a call that ran opens the next response at its return" true
    ((current ()).open_activities = waiting 13.);
  Preview.note_stream ~writer ~now:14. (block_stop 2);
  Alcotest.(check bool) "and its block stopping behind it changes nothing" true
    ((current ()).open_activities = waiting 13.);
  Preview.note_stream ~writer ~now:20. (tool_block 3 None "Skill");
  Preview.note_stream ~writer ~now:21. (block_stop 3);
  Alcotest.(check bool) "a call the stream named without an id ends the same way" true
    ((current ()).open_activities = waiting 21.)
;;

(* A native tool is the official client's own: its stream block is the run. No
   before-tool or after-tool hook comes for it. Measured on 2026-11-25, such a
   call stayed "requested" for the whole run, and then for the rest of the
   turn, and hid the calls that were running. *)
let test_a_native_block_is_the_clients_own_run () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-native-tool-run" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let run id started_at =
    Preview.Tool_open
      { tool_use_id = Some id; tool_name = "bash"; stage = Preview.Tool_executing
      ; started_at; since = started_at; cohort = None; reach = None }
  in
  client_attempt ~now:1.5 writer "vibe";
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:10. (native_tool_block 1 (Some "call_9") "self.sleep");
  Alcotest.(check string) "the client's own tool is running from its block, not waiting to run"
    "vibe · tool running: self.sleep · last observed tool: self.sleep"
    (Preview.status_text (current ()));
  Preview.note_stream ~writer ~now:190.5 (block_stop 1);
  Alcotest.(check bool) "its block stopping ends the run, and the turn waits on the model again" true
    ((current ()).open_activities
     = [ Preview.Response_open { channel = Preview.No_content; started_at = 190.5; since = 190.5 } ]);
  Alcotest.(check string) "no call is left claiming to be waiting to run"
    "vibe · waiting for provider response · last observed tool: self.sleep"
    (Preview.status_text (current ()));
  Preview.note_stream ~writer ~now:200. (native_tool_block 2 (Some "call_10") "bash");
  Preview.note_stream ~writer ~now:201. (native_tool_block 3 (Some "call_11") "bash");
  Alcotest.(check string) "two blocks of one tool are two runs"
    "vibe · tool running: bash · tool running: bash · last observed tool: bash"
    (Preview.status_text (current ()));
  Preview.note_stream ~writer ~now:205. (block_stop 3);
  Alcotest.(check bool) "the block that stops is the run that ends, whichever stopped first" true
    ((current ()).open_activities = [ run "call_10" 200. ]);
  Preview.note_stream ~writer ~now:207. (block_stop 2);
  Alcotest.(check bool) "the last run to end opens the next response" true
    ((current ()).open_activities
     = [ Preview.Response_open { channel = Preview.No_content; started_at = 207.; since = 207. } ]);
  Preview.note_stream ~writer ~now:210. (block_stop 3);
  Alcotest.(check bool) "a stop heard twice ends nothing and opens nothing" true
    ((current ()).open_activities
     = [ Preview.Response_open { channel = Preview.No_content; started_at = 207.; since = 207. } ])
;;

(* Antigravity names no call id on a native block and announces an active step
   more than once under one index. Two id-less runs of one tool can stop in
   the other order, and be opened at one instant. *)
let test_a_native_start_heard_again_is_one_run_and_each_run_keeps_its_clock () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-native-tool-repeats" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let run started_at =
    Preview.Tool_open
      { tool_use_id = None; tool_name = "view"; stage = Preview.Tool_executing
      ; started_at; since = started_at; cohort = None; reach = None }
  in
  let waiting since =
    [ Preview.Response_open { channel = Preview.No_content; started_at = since; since } ]
  in
  client_attempt ~now:1.5 writer "antigravity";
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:10. (native_tool_block 1 None "view");
  Preview.note_stream ~writer ~now:11. (native_tool_block 1 None "view");
  Alcotest.(check bool) "a start heard again for an open block is one run" true
    ((current ()).open_activities = [ run 10. ]);
  Preview.note_stream ~writer ~now:12. (block_stop 1);
  Preview.note_stream ~writer ~now:20. (native_tool_block 2 None "view");
  Preview.note_stream ~writer ~now:21. (native_tool_block 3 None "view");
  Preview.note_stream ~writer ~now:25. (block_stop 3);
  Alcotest.(check bool) "the run whose block stopped is the one that ends" true
    ((current ()).open_activities = [ run 20. ]);
  Preview.note_stream ~writer ~now:30. (block_stop 2);
  Alcotest.(check bool) "and the last one to end opens the next response" true
    ((current ()).open_activities = waiting 30.);
  Preview.note_stream ~writer ~now:40. (native_tool_block 4 None "view");
  Preview.note_stream ~writer ~now:40. (native_tool_block 5 None "view");
  Alcotest.(check bool) "two runs of one name opened at one instant are two runs" true
    ((current ()).open_activities = [ run 40.; run 40. ]);
  Preview.note_stream ~writer ~now:45. (block_stop 4);
  Alcotest.(check bool) "one block stopping ends one of them" true
    ((current ()).open_activities = [ run 40. ]);
  Preview.note_stream ~writer ~now:50. (block_stop 5);
  Alcotest.(check bool) "the other ends on its own block" true
    ((current ()).open_activities = waiting 50.);
  Preview.note_stream ~writer ~now:60. (block_stop 9);
  Alcotest.(check bool) "a stop for a block the stream never opened changes nothing" true
    ((current ()).open_activities = waiting 50.);
  Preview.note_stream ~writer ~now:70.
    Agent_core.Types.
      (ContentBlockStart
         { index = 6
         ; content_type = Runtime_native_tools.stream_content_type
         ; tool_id = Some "nameless"
         ; tool_name = None
         });
  Alcotest.(check bool) "a native block that names no tool opens no run" true
    ((current ()).open_activities = waiting 50.)
;;

(* Words that arrive while a call runs open a response after it. A before-tool
   hook heard twice must not close them: it says nothing new about the call. *)
let test_words_that_come_during_a_run_outlive_a_repeated_hook () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-words-during-run" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  started ~tool_use_id:(Some "call") writer 2. "Execute";
  Preview.note_stream ~writer ~now:3. (text_delta "meanwhile");
  let words =
    Preview.Response_open { channel = Preview.Text; started_at = 3.; since = 3. }
  in
  let call =
    Preview.Tool_open
      { tool_use_id = Some "call"; tool_name = "Execute"; stage = Preview.Tool_executing
      ; started_at = 2.; since = 2.; cohort = None; reach = None }
  in
  Alcotest.(check bool) "the call still outranks the words" true
    ((current ()).open_activities = [ words; call ]);
  started ~tool_use_id:(Some "call") writer 3.5 "Execute";
  Alcotest.(check bool) "a repeated hook closes nothing" true
    ((current ()).open_activities = [ words; call ]);
  finished ~tool_use_id:(Some "call") writer 4. "Execute";
  Alcotest.(check bool) "the return keeps the response that opened during the run, with its clock" true
    ((current ()).open_activities = [ words ])
;;

(* A turn of the agent loop can end at a tool boundary. A call its gates
   refused is still only requested there, and no later request comes to end
   it. *)
let test_a_turn_that_ends_at_a_tool_boundary_closes_what_is_still_open () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-turn-over" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let requested since =
    Preview.Tool_open
      { tool_use_id = Some "wait"; tool_name = "wait"; stage = Preview.Tool_requested
      ; started_at = since; since; cohort = None; reach = None }
  in
  loop_attempt ~now:1.5 writer "glm";
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:3. (tool_block 1 (Some "wait") "wait");
  Preview.note_stream ~writer ~now:4. (block_stop 1);
  Alcotest.(check bool) "the block is only the model's call, so its stop ends nothing" true
    ((current ()).open_activities
     = [ Preview.Response_open { channel = Preview.No_content; started_at = 2.; since = 2. }
       ; requested 3. ]);
  Preview.note_turn_over ~writer ~now:5.;
  Alcotest.(check bool) "the turn ending here closes what is still open" true
    ((current ()).open_activities = []);
  Alcotest.(check bool) "and the turn no longer says a tool is called" true
    ((current ()).activity = Preview.Awaiting_response);
  finished writer 5.5 "wait";
  Alcotest.(check bool) "a return that ends no call opens no response" true
    ((current ()).open_activities = [])
;;

(* A client may never send the stop of a native run: Claude Code sends none
   for a result it cannot tie to its call. Nothing else says when that run
   ended, so it stays running until the turn's run returns. *)
let test_the_turn_over_closes_a_native_run_whose_stop_never_came () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-native-run-without-stop" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  let running =
    Preview.Tool_open
      { tool_use_id = Some "call"; tool_name = "Read"; stage = Preview.Tool_executing
      ; started_at = 10.; since = 10.; cohort = None; reach = None }
  in
  client_attempt ~now:1.5 writer "claude-code";
  Preview.note_request ~writer ~now:2.;
  Preview.note_stream ~writer ~now:10. (native_tool_block 1 (Some "call") "Read");
  Preview.note_stream ~writer ~now:20. Agent_core.Types.MessageStop;
  Preview.note_text ~writer ~now:21. "done";
  Alcotest.(check bool) "the turn's text closes the response, and only the client could close the run" true
    ((current ()).open_activities = [ running ]);
  Preview.note_turn_over ~writer ~now:22.;
  Alcotest.(check bool) "the run returning closes it" true ((current ()).open_activities = []);
  Alcotest.(check bool) "and the turn no longer says a tool runs" true
    ((current ()).activity = Preview.Awaiting_response)
;;

let test_the_turn_text_ends_the_response () =
  let module Preview = Keeper_turn_preview in
  let keeper_name = "open-response-turn-text" in
  let current () = Option.get (Preview.current ~keeper_name) in
  let writer = Some (reset keeper_name ~now:1.) in
  Preview.note_request ~writer ~now:2.;
  Preview.note_text ~writer ~now:3. "final words";
  Alcotest.(check bool) "text recorded once the model's turn is over ends the response" true
    ((current ()).open_activities = []);
  Alcotest.(check string) "and is the tail" "final words" (current ()).text_tail;
  Preview.note_request ~writer ~now:4.;
  Preview.note_text ~writer ~now:5. "   ";
  Alcotest.(check bool) "a turn with no text ends the response all the same" true
    ((current ()).open_activities = []);
  Alcotest.(check string) "and keeps the last words" "final words" (current ()).text_tail
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
        ; Alcotest.test_case "a rejected tool never runs and overlapping tools stay open"
            `Quick test_a_rejected_tool_never_runs_and_overlapping_tools_stay_open
        ; Alcotest.test_case "a running tool carries its planned batch"
            `Quick test_a_running_tool_carries_its_planned_batch
        ; Alcotest.test_case "an add-on tool reaches where its openWorldHint says"
            `Quick test_an_addon_tool_reaches_where_its_open_world_hint_says
        ; Alcotest.test_case "a tool is open from its call to its return" `Quick
            test_a_tool_is_open_from_its_call_to_its_return
        ; Alcotest.test_case "reasoning and answer are two channels of one response"
            `Quick test_reasoning_and_answer_are_two_channels_of_one_response
        ; Alcotest.test_case "parallel tools stay open one by one" `Quick
            test_parallel_tools_stay_open_one_by_one
        ; Alcotest.test_case "a late return ends only its own call" `Quick
            test_a_late_return_ends_only_its_own_call
        ; Alcotest.test_case "an anonymous stream tool adopts the hook id" `Quick
            test_starting_an_anonymous_stream_tool_records_its_hook_id
        ; Alcotest.test_case "a new attempt, a failure and a new request end open work"
            `Quick test_a_new_attempt_a_failure_and_a_new_request_end_open_work
        ; Alcotest.test_case "the wire carries the open work" `Quick
            test_the_wire_carries_the_open_work
        ; Alcotest.test_case "a tool the stream never showed opens at its hook" `Quick
            test_a_tool_the_stream_never_showed_opens_at_its_hook
        ; Alcotest.test_case "in the agent loop a tool block is only the call" `Quick
            test_in_the_agent_loop_a_tool_block_is_only_the_call
        ; Alcotest.test_case "an official client tool block is the whole call" `Quick
            test_an_official_client_tool_block_is_the_whole_call
        ; Alcotest.test_case "an official client turn waits on a new response after each tool" `Quick
            test_an_official_client_turn_waits_on_a_new_response_after_each_tool
        ; Alcotest.test_case "a native block is the client's own run" `Quick
            test_a_native_block_is_the_clients_own_run
        ; Alcotest.test_case "a native start heard again is one run and each run keeps its clock" `Quick
            test_a_native_start_heard_again_is_one_run_and_each_run_keeps_its_clock
        ; Alcotest.test_case "words that come during a run outlive a repeated hook" `Quick
            test_words_that_come_during_a_run_outlive_a_repeated_hook
        ; Alcotest.test_case "a turn that ends at a tool boundary closes what is still open" `Quick
            test_a_turn_that_ends_at_a_tool_boundary_closes_what_is_still_open
        ; Alcotest.test_case "the turn over closes a native run whose stop never came" `Quick
            test_the_turn_over_closes_a_native_run_whose_stop_never_came
        ; Alcotest.test_case "the turn text ends the response" `Quick
            test_the_turn_text_ends_the_response
        ; Alcotest.test_case "live wait, failover, tool, and next-turn visibility" `Quick
            test_live_attempt_failover_and_new_turn
        ; Alcotest.test_case "a provider request after a tool is a wait" `Quick
            test_a_request_after_a_tool_waits_on_the_provider
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
