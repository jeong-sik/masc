open Alcotest

module Live = Masc_tui_keeper_chat_live
module Transcript = Masc_tui_keeper_chat_transcript
module Log = Masc_tui_keeper_chat_log

(* A stated instant rather than the wall clock: the progress row carries the
   turn age, and a test that read the real clock could not name it. *)
let origin = 1_000_000.

let fresh () =
  Transcript.create ~keeper_name:"keeper.one" ~request_id:"req-1"
    ~started_at:origin

let missing_skill_activity () =
  Transcript.make_skill_activity ~invocation:Transcript.Instruction_read
    ~skill_name:"source-review" ~skill_tool_use_id:"missing-read"
    ~turn_ref:"trace-1#3" ~state:Transcript.Skill_delivered ~actions:[] ()

let rows ?(show_timing = true) ?(now = origin) t =
  Transcript.status_rows ~show_timing ~now t

let feed ?(now = origin) t deltas =
  List.iter (Transcript.apply ~now t) deltas

let test_started_at_keeps_the_dispatch_instant () =
  let transcript = fresh () in
  check (float 0.) "live timeline source" origin
    (Transcript.started_at transcript)
;;

let occurrence ?(scope = 0) ?block_index call_id =
  { Live.stream_scope = scope
  ; block_index = Option.value ~default:(Hashtbl.hash call_id) block_index
  ; provider_message_id = None
  ; tool_call_id = Some call_id
  }
;;

let tool_started ?scope ?block_index call_id tool_name =
  Live.Tool_started
    { occurrence = occurrence ?scope ?block_index call_id; tool_name }
;;

let tool_args_delta ?scope ?block_index call_id delta =
  Live.Tool_args
    { occurrence = occurrence ?scope ?block_index call_id
    ; fragment = Live.Args_delta delta
    }
;;

let tool_args_snapshot ?scope ?block_index call_id snapshot =
  Live.Tool_args
    { occurrence = occurrence ?scope ?block_index call_id
    ; fragment = Live.Args_snapshot snapshot
    }
;;

let tool_ended ?scope ?block_index call_id =
  Live.Tool_ended { occurrence = occurrence ?scope ?block_index call_id }
;;

let tool_result ?scope ?block_index call_id execution_id =
  Live.Tool_result
    { occurrence = occurrence ?scope ?block_index call_id; execution_id }
;;

let phase_to_string : Transcript.phase -> string = function
  | Transcript.Waiting -> "waiting"
  | Transcript.Working -> "working"
  | Transcript.Stream_ended -> "stream_ended"
  | Transcript.Stream_failed message -> "stream_failed(" ^ message ^ ")"

let phase = testable (Fmt.of_to_string phase_to_string) ( = )

let outcome_to_string : Transcript.tool_outcome -> string = function
  | Transcript.Started -> "started"
  | Transcript.Native_running -> "native_running"
  | Transcript.Awaiting_result -> "awaiting_result"
  | Transcript.Returned -> "returned"
  | Transcript.Native_ended -> "native_ended"
  | Transcript.Failed -> "failed"
  | Transcript.Never_returned -> "never_returned"
  | Transcript.Outcome_unrecorded -> "outcome_unrecorded"

let call_to_string (call : Transcript.tool_activity) =
  Printf.sprintf "%s|%s|%s|%s|%s|%s|%s"
    (Option.value ~default:"-" call.call_id)
    (Option.value ~default:"-" call.execution_id)
    call.tool_name call.args (Option.value ~default:"-" call.subject)
    (outcome_to_string call.outcome)
    (Option.value ~default:"-" call.duration)

let tool_call = testable (Fmt.of_to_string call_to_string) ( = )
let tool_outcome = testable (Fmt.of_to_string outcome_to_string) ( = )

let read_file_call =
  [ tool_started "c1" "read_file"
  ; tool_args_delta "c1" "{\"file_path\":\"lib/keeper/a.ml\"}"
  ; tool_ended "c1"
  ; tool_result "c1" "exec-c1"
  ]

(* [drawn] is remembered until the transcript's revision moves. After every
   kind of mutation the remembered list must equal what a transcript fed the
   same history computes from scratch, and an untouched transcript hands back
   the same list rather than building another. *)
let test_drawn_follows_every_mutation_of_the_transcript () =
  let deltas =
    [ Live.Run_started
    ; Live.Thinking "checking "
    ; Live.Text {text="Let me "; stream_scope=None}
    ]
    @ read_file_call
    @ [ Live.Text {text="look."; stream_scope=None}
      ; Live.Thinking "again"
      ; Live.Run_finished
      ]
  in
  let live = fresh () in
  let replay prefix =
    let reference = fresh () in
    feed reference prefix;
    reference
  in
  let same label expected_from =
    let expected = Transcript.drawn expected_from in
    let first = Transcript.drawn live in
    check bool (label ^ ": equals a fresh computation") true (first = expected);
    check bool (label ^ ": an untouched transcript returns the same list") true
      (Transcript.drawn live == first)
  in
  let applied = ref [] in
  List.iter
    (fun delta ->
      Transcript.apply ~now:origin live delta;
      applied := !applied @ [ delta ];
      same "after an event" (replay !applied))
    deltas;
  (* The mutators that are not events. Each builds its reference by the same
     call on a replayed transcript. *)
  let reference = replay deltas in
  let outcome transcript =
    ignore
      (Transcript.note_tool_outcome transcript ~execution_id:"exec-c1"
         ~outcome:Transcript.Returned ~duration:(Some "1.5s")
       : bool)
  in
  outcome live;
  outcome reference;
  same "after a recorded tool outcome" reference;
  let skill = missing_skill_activity () in
  Transcript.note_skill_activity live skill;
  Transcript.note_skill_activity reference skill;
  same "after a noted skill delivery" reference
;;

let test_a_repeated_note_leaves_the_revision_alone () =
  let t = fresh () in
  feed t (Live.Run_started :: read_file_call);
  let moved label f expected =
    let before = Transcript.revision t in
    f ();
    check bool label expected (Transcript.revision t <> before)
  in
  let outcome duration () =
    ignore
      (Transcript.note_tool_outcome t ~execution_id:"exec-c1"
         ~outcome:Transcript.Returned ~duration:(Some duration)
       : bool)
  in
  moved "a new outcome moves the revision" (outcome "1.5s") true;
  moved "the same outcome again does not" (outcome "1.5s") false;
  moved "a different duration does" (outcome "2s") true;
  let skill = missing_skill_activity () in
  moved "a new skill delivery moves the revision"
    (fun () -> Transcript.note_skill_activity t skill) true;
  moved "the same delivery again does not"
    (fun () -> Transcript.note_skill_activity t skill) false;
  moved "a changed record does"
    (fun () ->
      Transcript.note_skill_activity t
        (Transcript.make_skill_activity ~invocation:Transcript.Instruction_read
           ~skill_name:"source-review" ~skill_tool_use_id:"missing-read"
           ~turn_ref:"trace-1#3" ~state:Transcript.Skill_delivered
           ~actions:[ "read" ] ()))
    true
;;

let test_text_and_thinking_accumulate () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Text {text="Let me "; stream_scope=None}
    ; Live.Thinking "checking "
    ; Live.Text {text="look."; stream_scope=None}
    ; Live.Thinking "the caller"
    ];
  check string "text is joined in arrival order" "Let me look." (Transcript.text t);
  check string "reasoning is kept apart from the reply" "checking the caller"
    (Transcript.thinking t);
  check phase "the run is working" Transcript.Working (Transcript.phase t)

let test_tool_call_is_named_the_way_the_other_surfaces_name_it () =
  let t = fresh () in
  feed t read_file_call;
  match Transcript.tool_calls t with
  | [ call ] ->
      check tool_call "the row carries the file, not the whole argument object"
        (Transcript.make_tool_activity ~execution_id:"exec-c1"
           ~call_id:(Some "c1")
           ~tool_name:"read_file"
           ~args:"{\"file_path\":\"lib/keeper/a.ml\"}"
           ~outcome:Transcript.Returned ~duration:None ())
        call
  | other -> failf "expected one call, got %d" (List.length other)

let test_calls_keep_stream_order () =
  let t = fresh () in
  feed t
    [ tool_started "c1" "read_file"
    ; tool_started "c2" "edit_file"
    ; tool_started "c3" "shell_light"
    ];
  check (list string) "rows read in the order the turn opened them"
    [ "read_file"; "edit_file"; "shell_light" ]
    (Transcript.tool_calls t
     |> List.map (fun (c : Transcript.tool_activity) -> c.Transcript.tool_name))

let test_reused_provider_id_keeps_distinct_live_occurrences () =
  let t = fresh () in
  feed t
    [ tool_started ~block_index:0 "reused" "Read"
    ; tool_ended ~block_index:0 "reused"
    ; tool_result ~block_index:0 "reused" "exec-first"
    ; tool_started ~block_index:1 "reused" "Write"
    ; tool_ended ~block_index:1 "reused"
    ; tool_result ~block_index:0 "reused" "exec-first"
    ; tool_result ~block_index:1 "reused" "exec-second"
    ];
  let calls = Transcript.tool_calls t in
  check (list string) "both tool names retain their own trail node"
    [ "Read"; "Write" ]
    (List.map (fun (call : Transcript.tool_activity) -> call.tool_name) calls);
  check (list (option string)) "each occurrence keeps its canonical execution"
    [ Some "exec-first"; Some "exec-second" ]
    (List.map (fun (call : Transcript.tool_activity) -> call.execution_id) calls)
;;

let test_tool_result_identity_is_write_once () =
  let t = fresh () in
  feed t
    [ tool_started "call-once" "Read"
    ; tool_ended "call-once"
    ; tool_result "call-once" "exec-one"
    ; tool_result "call-once" "exec-one"
    ];
  check (option bool) "same canonical replay is idempotent" None
    (Option.map (fun _ -> true) (Transcript.unreadable t));
  feed t [ tool_args_delta "call-once" "{\"changed\":true}" ];
  (match Transcript.tool_calls t with
   | [ call ] ->
     check string "canonical result freezes later arguments" "" call.args
   | calls -> failf "expected one tool call, got %d" (List.length calls));
  feed t
    [ tool_result "call-once" "exec-two" ];
  (match Transcript.unreadable t with
   | Some { count = 1; _ } -> ()
   | Some { count; _ } -> failf "expected one conflict, got %d" count
   | None -> fail "conflicting canonical replay was not surfaced");
  match Transcript.tool_calls t with
  | [ call ] ->
      check (option string) "the first canonical identity remains authoritative"
        (Some "exec-one") call.execution_id
  | calls -> failf "expected one tool call, got %d" (List.length calls)
;;

let test_same_turn_duplicate_provider_id_uses_server_occurrence () =
  let t = fresh () in
  feed t
    [ tool_started ~block_index:0 "duplicate" "Read"
    ; tool_ended ~block_index:0 "duplicate"
    ; tool_started ~block_index:1 "duplicate" "Write"
    ; tool_ended ~block_index:1 "duplicate"
    ; tool_result ~block_index:1 "duplicate" "exec-second"
    ];
  check (list (option string)) "only the named occurrence receives the result"
    [ None; Some "exec-second" ]
    (Transcript.tool_calls t
     |> List.map (fun (call : Transcript.tool_activity) -> call.execution_id));
  check (option bool) "duplicate provider correlation is not an error" None
    (Option.map (fun _ -> true) (Transcript.unreadable t))
;;

let test_protocol_error_fails_only_the_quarantined_occurrence () =
  let t = fresh () in
  let first = occurrence ~block_index:0 "duplicate" in
  let second = occurrence ~block_index:1 "duplicate" in
  feed t
    [ Live.Tool_started { occurrence = first; tool_name = "Read" }
    ; Live.Tool_started { occurrence = second; tool_name = "Write" }
    ; Live.Stream_protocol_error
        { quarantined_occurrence = Some second
        ; detail = "tool_replay_mismatch: replayed arguments changed"
        }
    ];
  check (list string) "only the exact occurrence becomes failed"
    [ "started"; "failed" ]
    (Transcript.tool_calls t
     |> List.map (fun (call : Transcript.tool_activity) ->
       outcome_to_string call.outcome));
  match Transcript.unreadable t with
  | Some { count = 1; last_detail } ->
    check bool "the typed diagnostic stays visible" true
      (String_util.contains_substring last_detail "tool_replay_mismatch")
  | Some { count; _ } -> failf "expected one protocol diagnostic, got %d" count
  | None -> fail "protocol diagnostic was dropped"
;;

let test_quarantine_freezes_late_args_and_result () =
  let t = fresh () in
  let target = occurrence ~block_index:2 "call-failed" in
  feed t
    [ Live.Tool_started { occurrence = target; tool_name = "Read" }
    ; tool_args_snapshot ~block_index:2 "call-failed" {|{"path":"before"}|}
    ; Live.Stream_protocol_error
        { quarantined_occurrence = Some target
        ; detail = "tool_replay_mismatch: occurrence quarantined"
        }
    ; tool_args_snapshot ~block_index:2 "call-failed" {|{"path":"after"}|}
    ; tool_result ~block_index:2 "call-failed" "exec-too-late"
    ];
  (match Transcript.tool_calls t with
   | [ call ] ->
     check string "quarantine freezes arguments" {|{"path":"before"}|} call.args;
     check (option string) "quarantine rejects late execution identity" None
       call.execution_id;
     check string "quarantined outcome remains failed" "failed"
       (outcome_to_string call.outcome)
   | calls -> failf "expected one tool call, got %d" (List.length calls));
  match Transcript.unreadable t with
  | Some { count = 2; last_detail } ->
    check bool "late result names the quarantined occurrence" true
      (String_util.contains_substring last_detail "targets quarantined")
  | Some { count; _ } ->
    failf "expected quarantine and late-result diagnostics, got %d" count
  | None -> fail "quarantine diagnostics were dropped"
;;

(* The attempt boundary takes nothing back (RFC-0412 §3.3). Everything the
   earlier attempt produced -- the finished stretch, the tool rows, and the
   stretch that was still growing when the runtime turned over -- stays in the
   trail as one superseded block, and the new attempt's stretches follow it.
   The buffer accessors cannot show this: they are per-attempt totals and start
   over either way. Only the trail shows it. *)
let test_runtime_attempt_keeps_the_earlier_attempt_superseded () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Text {text="finished before the tool"; stream_scope=None}
    ; tool_started "call-kept" "Read"
    ; tool_ended "call-kept"
    ; tool_result "call-kept" "exec-kept"
    ; Live.Text {text="still growing when the attempt turned over"; stream_scope=None}
    ; Live.Runtime_attempt_started { runtime_id = Some "claude-3-7-sonnet"; attempt_index = Some 1 }
    ; Live.Text {text="second attempt"; stream_scope=None}
    ];
  check int "one retry" 1 (Transcript.attempt t);
  match Transcript.trail t with
  | [ Transcript.Trail_superseded { attempt; items; _ }; Transcript.Trail_text second ] ->
      check int "the block names the attempt it came from" 0 attempt;
      check string "the new attempt follows it at the top level" "second attempt" second;
      let texts =
        List.filter_map
          (function Transcript.Trail_text text -> Some text | _ -> None)
          items
      in
      check bool "the finished stretch is kept" true
        (List.exists
           (fun text -> String_util.contains_substring text "finished before the tool")
           texts);
      check bool "the stretch that was still growing is kept too" true
        (List.exists
           (fun text -> String_util.contains_substring text "still growing")
           texts);
      check bool "the tool stretch is kept between them" true
        (List.exists (function Transcript.Trail_tools _ -> true | _ -> false) items)
  | other ->
      failf "expected a superseded block then the new attempt, got %d items"
        (List.length other)
;;

let test_runtime_attempt_restarts_the_per_attempt_totals () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Thinking "failed reasoning"
    ; Live.Text {text="failed reply"; stream_scope=None}
    ; tool_started "call-kept" "Read"
    ; tool_ended "call-kept"
    ; tool_result "call-kept" "exec-kept"
    ; Live.Runtime_attempt_started { runtime_id = Some "gpt-4o"; attempt_index = Some 1 }
    ; Live.Thinking "fallback reasoning"
    ; Live.Text {text="fallback reply"; stream_scope=None}
    ];
  check string "text is the current attempt's" "fallback reply" (Transcript.text t);
  check string "thinking is the current attempt's" "fallback reasoning"
    (Transcript.thinking t);
  (match Transcript.tool_calls t with
   | [ call ] ->
     check (option string) "execution identity survives the retry"
       (Some "exec-kept") call.execution_id;
     check string "settled outcome survives the retry" "returned"
       (outcome_to_string call.outcome)
   | calls -> failf "expected one preserved tool call, got %d" (List.length calls));
  (* A second retry folds only what came after the first boundary: the two
     superseded attempts sit side by side, each with its number, and neither
     block holds a block. *)
  feed t [ Live.Runtime_attempt_started { runtime_id = Some "deepseek-r1"; attempt_index = Some 2 }; Live.Text {text="third try"; stream_scope=None} ];
  check int "two retries" 2 (Transcript.attempt t);
  match Transcript.trail t with
  | [ Transcript.Trail_superseded { attempt = 0; items = first; _ }
    ; Transcript.Trail_superseded { attempt = 1; items = second; _ }
    ; Transcript.Trail_text "third try"
    ] ->
      let flat items =
        List.for_all (function Transcript.Trail_superseded _ -> false | _ -> true) items
      in
      check bool "the first block holds no nested block" true (flat first);
      check bool "the second block holds no nested block" true (flat second);
      check bool "the first attempt's text is still readable" true
        (List.exists
           (function
             | Transcript.Trail_text text ->
                 String_util.contains_substring text "failed reply"
             | _ -> false)
           first);
      check bool "the second attempt's text is still readable" true
        (List.exists
           (function
             | Transcript.Trail_text text ->
                 String_util.contains_substring text "fallback reply"
             | _ -> false)
           second)
  | other -> failf "expected two sibling superseded blocks, got %d items" (List.length other)
;;

let reply_details ?(reply = "Let me look.") () =
  Live.Reply_details
    { terminal_stream_scope = None; reply; turn_outcome = Masc.Keeper_turn_outcome.Visible_reply; turn_ref = "trace-1#3" }
;;

(* The reply is recorded, not drawn: the server streams the reply text as
   deltas (chunked at the end when nothing streamed), so a trail item for it
   would draw the same words twice. *)
let test_reply_details_is_recorded_not_drawn () =
  let t = fresh () in
  feed t [ Live.Run_started; Live.Text {text="Let me look."; stream_scope=None} ];
  let before = Transcript.trail t in
  let recorded t =
    Option.map
      (fun (reply : Transcript.reply) ->
        ( reply.reply_text
        , Masc.Keeper_turn_outcome.to_label reply.reply_outcome
        , reply.reply_turn_ref ))
      (Transcript.reply t)
  in
  check (option (triple string string string)) "no reply yet" None (recorded t);
  feed t [ reply_details () ];
  check (option (triple string string string))
    "the reply, its outcome and its turn are recorded"
    (Some ("Let me look.", "visible_reply", "trace-1#3"))
    (recorded t);
  check int "the trail did not grow" (List.length before) (List.length (Transcript.trail t))
;;

let drawn_to_string (item : Transcript.drawn_item) =
  let mark =
    match item.Transcript.superseded with
    | None -> ""
    | Some attempt -> Printf.sprintf "[superseded %d] " attempt
  in
  mark
  ^
  match item.Transcript.drawn with
  | Transcript.Drawn_thinking lines -> "thinking:" ^ String.concat "|" lines
  | Transcript.Drawn_skill skills ->
      "skill:" ^ String.concat "," (List.map (fun (s : Transcript.skill_activity) -> s.skill_name) skills)
  | Transcript.Drawn_tools block -> "tools:" ^ String.concat "|" (Transcript.project_tool_block Transcript.Full block).Transcript.details
  | Transcript.Drawn_text text -> "text:" ^ text
  | Transcript.Drawn_reply text -> "reply:" ^ text
  | Transcript.Drawn_status text -> "status:" ^ text
  | Transcript.Drawn_error text -> "error:" ^ text
;;

let drawn t = List.map drawn_to_string (Transcript.drawn t)

let control_reply outcome =
  Live.Reply_details
    { terminal_stream_scope = None; reply = "recorded but not chunked"; turn_outcome = outcome; turn_ref = "trace-1#3" }
;;

(* The record stands where the last stretch streamed, one row, however the
   two read: here the stream's copy ended in a newline the store did not
   keep, and the row is the store's text. *)
let test_drawn_is_one_row_when_the_record_differs_from_the_stream_by_whitespace () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Thinking "look first"
    ; tool_started "c1" "read_file"
    ; tool_ended "c1"
    ; Live.Text {text="Let me "; stream_scope=None}
    ; Live.Text {text="look.\n"; stream_scope=None}
    ; reply_details ~reply:"Let me look." ()
    ];
  check (list string) "one row per stretch, the last one the record's"
    [ "thinking:look first"; "tools:" ^ String.concat "|" (Transcript.tool_rows t); "reply:Let me look." ]
    (drawn t)
;;

(* Two operations that ended in the same words: the reply of one is a row on
   that one's transcript only. What places a reply is the transcript it was
   applied to -- one operation's log -- not what the text reads. *)
let test_drawn_places_a_reply_by_its_operation_not_by_its_text () =
  let earlier =
    Transcript.create ~keeper_name:"keeper.one" ~request_id:"req-1" ~started_at:origin
  in
  let later =
    Transcript.create ~keeper_name:"keeper.one" ~request_id:"req-2"
      ~started_at:(origin +. 1.)
  in
  feed earlier [ Live.Run_started; Live.Text {text="Done."; stream_scope=None} ];
  feed later [ Live.Run_started; Live.Text {text="Done."; stream_scope=None}; reply_details ~reply:"Done." () ];
  check (list string) "the earlier turn, still streaming, keeps its stream"
    [ "text:Done." ] (drawn earlier);
  check (list string) "the later turn's row is its own record"
    [ "reply:Done." ] (drawn later);
  check (option string) "and the earlier turn holds no reply" None
    (Option.map
       (fun (reply : Transcript.reply) -> reply.reply_text)
       (Transcript.reply earlier))
;;

(* The recorded reply is the terminal message's text. The server strips
   control tokens from it, so the last stretch can differ from what streamed;
   the recorded text stands in for that stretch only. Earlier stretches are
   the turn's earlier rounds and stay, and so does the superseded attempt. *)
let test_drawn_replaces_the_streamed_text_with_a_differing_reply () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Text {text="first try"; stream_scope=None}
    ; Live.Runtime_attempt_started { runtime_id = None; attempt_index = None }
    ; Live.Text {text="Let me check."; stream_scope=None}
    ; tool_started "c1" "read_file"
    ; tool_ended "c1"
    ; Live.Text {text="Here it is.<|eot|>"; stream_scope=None}
    ; reply_details ~reply:"Here it is." ()
    ];
  check (list string) "only the last stretch gives way to the recorded reply"
    [ "[superseded 0] text:first try"
    ; "text:Let me check."
    ; "tools:" ^ String.concat "|" (Transcript.tool_rows t)
    ; "reply:Here it is."
    ]
    (drawn t)
;;

(* A turn that spoke before its tool round and again after records only the
   second as its reply; the first is not taken back, and the second is drawn
   as the record. *)
let test_drawn_keeps_earlier_rounds_when_the_reply_is_the_last_stretch () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Text {text="Let me check."; stream_scope=None}
    ; tool_started "c1" "read_file"
    ; tool_ended "c1"
    ; Live.Text {text="Done."; stream_scope=None}
    ; reply_details ~reply:"Done." ()
    ];
  check (list string) "the earlier round stays as it streamed, the last is the record"
    [ "text:Let me check."
    ; "tools:" ^ String.concat "|" (Transcript.tool_rows t)
    ; "reply:Done."
    ]
    (drawn t)
;;

(* A turn that spoke before its tool round and streamed nothing after it:
   the reply is the terminal message, which came after the tools, so the
   words before them are progress and stay. Taking them as the reply's
   stand-in drew "Done." where "Let me check." had been. *)
let test_drawn_keeps_pre_tool_progress_when_nothing_streamed_after () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Text {text="Let me check."; stream_scope=None}
    ; tool_started "c1" "read_file"
    ; tool_ended "c1"
    ; reply_details ~reply:"Done." ()
    ];
  check (list string) "the pre-tool words stay and the reply follows the tools"
    [ "text:Let me check."
    ; "tools:" ^ String.concat "|" (Transcript.tool_rows t)
    ; "reply:Done."
    ]
    (drawn t)
;;

(* A durable skill receipt can survive a missing stream call. With no
   observed boundary, the last text may have preceded that read; it cannot
   safely stand in for the terminal reply. *)
let test_drawn_preserves_text_when_a_skill_round_was_unobserved () =
  let t = fresh () in
  feed t [ Live.Run_started; Live.Text {text="Let me check."; stream_scope=None} ];
  Transcript.note_skill_activity t (missing_skill_activity ());
  check (list string) "the receipt preserves the observed progress while running"
    [ "text:Let me check."; "skill:source-review" ] (drawn t);
  feed t [ reply_details ~reply:"Done." () ];
  check (list string) "the reply follows the unseen read without replacing progress"
    [ "text:Let me check."; "skill:source-review"; "reply:Done." ] (drawn t)
;;

let test_missing_skill_boundary_reconciles_the_identified_terminal_round () =
  List.iter (fun terminal_text ->
    let deltas =
      [ Live.Run_started
      ; Live.Stream_model_started {model="model"; stream_scope=Some 0; message_id=None; usage=None}
      ; Live.Text {text="Let me check."; stream_scope=Some 0}
      ; Live.Stream_model_started {model="model"; stream_scope=Some 1; message_id=None; usage=None}
      ] @ (if terminal_text then [Live.Text {text="Done."; stream_scope=Some 1}] else []) @
      [ Live.Reply_details {reply="Done.";turn_outcome=Masc.Keeper_turn_outcome.Visible_reply;
          turn_ref="trace-1#3";terminal_stream_scope=Some 1} ] in
    let t = fresh () in
    feed t deltas;
    Transcript.note_skill_activity t (missing_skill_activity ());
    check (list string) "known final scope replaces only its text; absent final text preserves progress"
      ["text:Let me check.";"skill:source-review";"reply:Done."] (drawn t)) [true;false]
;;

let test_terminal_scope_survives_a_missing_start () =
  List.iter (fun repeated_start ->
    let t = fresh () in
    feed t [Live.Run_started;
      Live.Text {text="Let me check."; stream_scope=Some 0};
      Live.Text {text="Do"; stream_scope=Some 1}];
    let text_origins () = Transcript.drawn t |> List.filter_map
      (fun (item : Transcript.drawn_item) -> match item.origin, item.drawn with
       | Transcript.Text_stretch id, (Transcript.Drawn_text _ | Transcript.Drawn_reply _) -> Some id
       | _ -> None) in
    let before = text_origins () in
    check int "distinct scoped text has distinct stable stretches" 2 (List.length before);
    check bool "each scoped stretch keeps its own identity" true
      (List.sort_uniq Int.compare before = before);
    if repeated_start then
      feed t [Live.Stream_model_started {model="model"; stream_scope=Some 1; message_id=None; usage=None}];
    feed t [Live.Text {text="ne"; stream_scope=Some 1};
      Live.Reply_details {reply="Done.";
        turn_outcome=Masc.Keeper_turn_outcome.Visible_reply;
        turn_ref="trace-1#3"; terminal_stream_scope=Some 1}];
    Transcript.note_skill_activity t (missing_skill_activity ());
    check (list int) "late start and canonical reply retain both source origins"
      before (text_origins ());
    check (list string) "text identity reconciles the terminal reply without its first start"
      ["text:Let me check."; "skill:source-review"; "reply:Done."] (drawn t))
    [false; true]
;;

let test_final_response_boundary_survives_a_missing_skill_call () =
  List.iter (fun stop_reason ->
    List.iter (fun final_text ->
      List.iter (fun progress ->
        let t = fresh () in
        feed t [Live.Run_started; Live.Stream_model_started {usage = None; message_id = None; stream_scope=Some 1; model="observed"};
          Live.Text {text=progress; stream_scope=None};
          Live.Stream_details {stream_scope=Some 1; usage=None; stop_reason=Some Agent_core.Types.StopToolUse};
          Live.Stream_model_started {usage = None; message_id = None; stream_scope=Some 2; model="observed"}];
        Option.iter (fun text -> feed t [Live.Text {text=text; stream_scope=None}]) final_text;
        feed t [Live.Stream_details {stream_scope=Some 2; usage=None; stop_reason=Some stop_reason}];
        Transcript.note_skill_activity t (missing_skill_activity ());
        feed t [reply_details ~reply:"Done." ()];
        check (list string) "only text observed after the terminal boundary is replaced"
          ["text:" ^ progress; "skill:source-review"; "reply:Done."] (drawn t))
        ["Let me check."; "Done."])
      [Some "Done."; None])
    [Agent_core.Types.EndTurn; StopSequence; MaxTokens; Refusal; ContentFilter;
     RepetitionTruncation; PauseTurn; Compaction; ContextWindowExceeded]
;;

let test_stop_from_an_unobserved_response_preserves_progress () =
  List.iter (fun stopped_scope ->
    let t = fresh () in
    feed t [Live.Run_started;
      Live.Stream_model_started {usage = None; message_id = None; stream_scope=Some 1; model="observed"};
      Live.Text {text="Let me check."; stream_scope=None};
      (* The tool call and the next MessageStart were not retained. *)
      Live.Stream_details {stream_scope=stopped_scope; usage=None; stop_reason=Some Agent_core.Types.EndTurn}];
    Transcript.note_skill_activity t (missing_skill_activity ());
    feed t [reply_details ~reply:"Done." ()];
    check (list string) "another or unidentified response ending cannot consume earlier progress"
      ["text:Let me check."; "skill:source-review"; "reply:Done."] (drawn t))
    [Some 2; None]
;;

let test_repeated_response_start_is_not_a_boundary () =
  List.iter (fun tail ->
    let t = fresh () in
    let start = Live.Stream_model_started {usage = None; message_id = None; stream_scope=Some 4; model="observed"} in
    feed t [Live.Run_started; start; Live.Text {text="Done"; stream_scope=None}; start];
    Option.iter (fun text -> feed t [Live.Text {text=text; stream_scope=None}]) tail;
    feed t [Live.Stream_details {stream_scope=Some 4; usage=None; stop_reason=Some Agent_core.Types.EndTurn}];
    Transcript.note_skill_activity t (missing_skill_activity ());
    feed t [reply_details ~reply:"Done." ()];
    check (list string) "an identical start cannot leave a prefix or a second final answer"
      ["skill:source-review"; "reply:Done."] (drawn t)) [None; Some "."]
;;

let test_scoped_text_retires_prior_response_metadata () =
  let t = fresh () in
  feed t [Live.Run_started;
    Live.Stream_model_started {usage = None; message_id = None; stream_scope=Some 1; model="first"};
    Live.Stream_details {stream_scope=Some 1;
      usage=Some {input_tokens=Some 100; output_tokens=Some 20;
        cache_read_input_tokens=None; cache_creation_input_tokens=None};
      stop_reason=Some Agent_core.Types.EndTurn};
    Live.Text {text="next response"; stream_scope=Some 2}];
  check (option string) "a distinct text scope retires prior counters and stop" None
    (Transcript.stream_details_text ~keeper_name:"keeper.one" (Some t));
  feed t [Live.Stream_details {stream_scope=Some 2; usage=None;
    stop_reason=Some Agent_core.Types.MaxTokens};
    Live.Stream_model_started {usage = None; message_id = None; stream_scope=Some 2; model="second"}];
  check (option string) "the delayed equal start preserves current stop metadata"
    (Some "stopped: max_tokens")
    (Transcript.stream_details_text ~keeper_name:"keeper.one" (Some t));
  check string "the delayed equal start still records the observed model"
    "model: second · configured: configured"
    (Transcript.runtime_identity_text ~keeper_name:"keeper.one"
       ~configured_runtime:"configured" (Some t))
;;

let test_drawn_reconciles_text_after_an_observed_skill_round () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Text {text="Let me check."; stream_scope=None}
    ; tool_started "seen-read" "keeper_compose_source-review"
    ; tool_ended "seen-read"
    ; tool_result "seen-read" "skill-exec"
    ; Live.Text {text="Done."; stream_scope=None}
    ];
  Transcript.note_skill_activity t
    (Transcript.make_skill_activity
       ~invocation:(Transcript.Composition_run { tool_name = "keeper_compose_source-review" })
       ~skill_name:"source-review" ~skill_tool_use_id:"seen-read"
       ~turn_ref:"trace-1#3" ~state:Transcript.Skill_delivered ~actions:[] ());
  feed t [ reply_details ~reply:"Done." () ];
  check (list string) "an observed skill still identifies the final reply stretch"
    [ "text:Let me check."; "skill:source-review"; "reply:Done." ] (drawn t)
;;

(* The wire carries neither a call's duration nor whether it failed; the
   durable transcript does. Folded in by execution id, the block says what
   the loaded row it replaces would have said. A durable word that says less
   than the stream saw changes nothing. *)
let test_note_tool_outcome_folds_the_durable_facts_in () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; tool_started "c1" "read_file"
    ; tool_ended "c1"
    ; tool_result "c1" "exec-1"
    ; tool_started "c2" "grep"
    ; tool_ended "c2"
    ; tool_result "c2" "exec-2"
    ];
  let outcomes () =
    List.map
      (fun (a : Transcript.tool_activity) -> (a.outcome, a.duration))
      (Transcript.tool_calls t)
  in
  let before = Transcript.revision t in
  check bool "an unknown execution id matches nothing" false
    (Transcript.note_tool_outcome t ~execution_id:"exec-9" ~outcome:Transcript.Failed
       ~duration:None);
  check bool "the failed call is found" true
    (Transcript.note_tool_outcome t ~execution_id:"exec-1" ~outcome:Transcript.Failed
       ~duration:(Some "32ms"));
  check bool "a durable word that says less leaves the stream's" true
    (Transcript.note_tool_outcome t ~execution_id:"exec-2"
       ~outcome:Transcript.Never_returned ~duration:(Some "5ms"));
  check (list (pair tool_outcome (option string))) "outcome and duration per call"
    [ (Transcript.Failed, Some "32ms"); (Transcript.Returned, Some "5ms") ]
    (outcomes ());
  check bool "the revision moved" true (Transcript.revision t > before)
;;

let test_drawn_appends_the_reply_when_nothing_streamed () =
  let t = fresh () in
  feed t [ Live.Run_started; Live.Thinking "quiet"; reply_details ~reply:"Said at the end." () ];
  check (list string) "the reply follows what did stream"
    [ "thinking:quiet"; "reply:Said at the end." ]
    (drawn t)
;;

let test_drawn_ends_a_blank_visible_reply_with_a_status_row () =
  let t = fresh () in
  feed t [ Live.Run_started; reply_details ~reply:"   " () ];
  check (list string) "non-text visible content is named"
    [ "status:Turn completed with non-text visible content (turn trace-1#3)" ]
    (drawn t)
;;

(* Each control outcome ends in the sentence the strict decode used to write,
   and what did stream stays above it. *)
let test_drawn_ends_each_control_outcome_with_its_status_row () =
  List.iter
    (fun (outcome, expected) ->
      let t = fresh () in
      feed t [ Live.Run_started; Live.Text {text="partial words"; stream_scope=None}; control_reply outcome ];
      check (list string) (Masc.Keeper_turn_outcome.to_label outcome)
        [ "text:partial words"; "status:" ^ expected ]
        (drawn t))
    [ ( Masc.Keeper_turn_outcome.Continuation_checkpoint
      , "Continuation checkpoint recorded (turn trace-1#3)" )
    ; ( Masc.Keeper_turn_outcome.Terminal_effect_settled
      , "Reply delivered by a terminal tool (turn trace-1#3)" )
    ; ( Masc.Keeper_turn_outcome.Awaiting_gate_approval
      , "승인 후 턴을 이어서 진행합니다 (turn trace-1#3)" )
    ; ( Masc.Keeper_turn_outcome.No_visible_reply
      , "Turn completed without a visible reply (turn trace-1#3)" )
    ]
;;

let test_snapshot_replaces_accumulated_args () =
  let t = fresh () in
  feed t
    [ tool_started "c1" "read_file"
    ; tool_args_delta "c1" "{\"file_"
    ; tool_args_snapshot "c1" "{\"file_path\":\"b.ml\"}"
    ];
  match Transcript.tool_calls t with
  | [ call ] ->
      check string "the snapshot replaced the fragments, it did not append"
        "{\"file_path\":\"b.ml\"}" call.Transcript.args;
      check (option string) "and the row is named from it" (Some "b.ml")
        call.Transcript.subject
  | other -> failf "expected one call, got %d" (List.length other)

let test_fragment_for_an_unopened_call_is_dropped () =
  let t = fresh () in
  feed t
    [ tool_args_delta "never-opened" "{\"a\":1}"
    ; tool_ended "never-opened"
    ];
  check int "no nameless row is opened for it" 0
    (List.length (Transcript.tool_calls t))

let test_run_failure_and_finish_set_the_phase () =
  let failed = fresh () in
  feed failed [ Live.Run_started; Live.Run_failed { message = "provider 429" } ];
  check phase "a failed run says so"
    (Transcript.Stream_failed "provider 429")
    (Transcript.phase failed);
  check (list string) "a failure before any output remains in the transcript"
    [ "error:provider 429" ] (drawn failed);
  check string "failure progress carries the cause without another error label"
    "provider 429 \xc2\xb7 0s"
    (List.assoc Transcript.Progress (rows failed));
  let missing = fresh () in
  feed missing [ Live.Run_started; Live.Run_failed { message = " " } ];
  check (list string) "a missing failure cause remains visible"
    [ "error:cause not reported" ] (drawn missing);
  check string "a missing cause is explicit" "cause not reported \xc2\xb7 0s"
    (List.assoc Transcript.Progress (rows missing));
  let missing_on_runtime = fresh () in
  feed missing_on_runtime
    [ Live.Run_started
    ; Live.Runtime_attempt_started
        { runtime_id = Some "glm-coding.glm-5.3-flash"; attempt_index = Some 0 }
    ; Live.Run_failed { message = " " }
    ];
  check string "a runtime cannot hide a missing cause"
    "[glm-coding.glm-5.3-flash] cause not reported \xc2\xb7 0s"
    (List.assoc Transcript.Progress (rows missing_on_runtime));
  let finished = fresh () in
  feed finished [ Live.Run_started; Live.Run_finished ];
  check phase "a finished run says so" Transcript.Stream_ended
    (Transcript.phase finished)

let test_failure_after_recorded_reply_preserves_both () =
  List.iter (fun (outcome, expected_reply) ->
    let t = fresh () in
    feed t [ Live.Run_started; control_reply outcome; Live.Run_finished ];
    feed ~now:(origin +. 12.) t [ Live.Run_failed {message="resumed operation failed"} ];
    check (list string) "the prior reply and later terminal failure both remain"
      [expected_reply; "error:resumed operation failed"] (drawn t);
    match List.rev (Transcript.drawn t) with
    | { Transcript.drawn = Drawn_error _; at; segment; _ } :: _ ->
        check (option (float 0.001)) "failure retains its later observation time"
          (Some (origin +. 12.)) at;
        check int "failure belongs to its original segment" 0 segment
    | _ -> fail "terminal failure disappeared from the drawn timeline")
    [ Masc.Keeper_turn_outcome.Visible_reply, "reply:recorded but not chunked"
    ; Masc.Keeper_turn_outcome.Continuation_checkpoint,
      "status:Continuation checkpoint recorded (turn trace-1#3)" ]
;;

let test_terminal_turn_marks_only_unresolved_tools () =
  List.iter
    (fun terminal ->
      let t = fresh () in
      let deltas =
        [ Live.Run_started
        ; tool_started "preparing" "keeper_analyze_image"
        ; tool_args_snapshot "preparing" {|{"image":"screen.png"}|}
        ; tool_started "waiting" "Read"
        ; tool_ended "waiting"
        ; tool_started "returned" "Read"
        ; tool_ended "returned"
        ; tool_result "returned" "exec-returned"
        ; tool_started "failed" "Write"
        ; Live.Stream_protocol_error
            { quarantined_occurrence = Some (occurrence "failed")
            ; detail = "invalid tool arguments"
            }
        ]
      in
      feed t deltas;
      let outcomes () =
        Transcript.tool_calls t
        |> List.map (fun (call : Transcript.tool_activity) -> call.outcome)
      in
      check (list tool_outcome) "live tools retain their distinct stages"
        [ Transcript.Started; Awaiting_result; Returned; Failed ] (outcomes ());
      feed t [ terminal ];
      check (list tool_outcome) "terminal turn has no unresolved waiting rows"
        [ Transcript.Never_returned; Never_returned; Returned; Failed ] (outcomes ());
      let log = Log.create ~keeper_name:"keeper.one" ~request_id:"req-1"
        ~started_at:origin in
      List.iteri
        (fun seq delta -> ignore (Log.add log ~seq:(Some seq) delta : bool))
        (deltas @ [ terminal ]);
      let replayed = Transcript.of_log ~now:origin log in
      check (list tool_call) "journal replay preserves terminal tool outcomes"
        (Transcript.tool_calls t) (Transcript.tool_calls replayed);
      check bool "journal replay and live trail draw the same outcomes" true
        (Transcript.trail t = Transcript.trail replayed);
      feed t [ tool_result "waiting" "exec-late" ];
      check (list tool_outcome) "late recorded result upgrades only its call"
        [ Transcript.Never_returned; Returned; Returned; Failed ] (outcomes ()))
    [ Live.Run_failed { message = "provider timeout after 900s" }; Live.Run_finished ]

let test_superseded_calls_keep_attempt_identity () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; tool_started ~scope:0 "reused" "keeper_analyze_image"
    ; tool_ended ~scope:0 "reused"
    ; Live.Runtime_attempt_started
        { runtime_id = Some "next-runtime"; attempt_index = Some 1 }
    ; tool_started ~scope:1 "reused" "keeper_analyze_image"
    ; tool_ended ~scope:1 "reused"
    ];
  let outcomes () = Transcript.tool_calls t
    |> List.map (fun (call : Transcript.tool_activity) -> call.outcome) in
  check (list tool_outcome) "only the abandoned attempt is interrupted"
    [ Transcript.Never_returned; Awaiting_result ] (outcomes ());
  (match Transcript.trail t with
   | [ Transcript.Trail_superseded { attempt = 0; items = [Transcript.Trail_tools old]; _ }
     ; Transcript.Trail_tools current ] ->
     check (list tool_outcome) "old trail block is terminal"
       [ Transcript.Never_returned ]
       (List.map (fun (call : Transcript.tool_activity) -> call.outcome) old.activities);
     check (list tool_outcome) "new trail block is still waiting"
       [ Transcript.Awaiting_result ]
       (List.map (fun (call : Transcript.tool_activity) -> call.outcome) current.activities)
   | _ -> fail "attempt boundary or tool evidence was lost");
  feed t [ tool_result ~scope:0 "reused" "old-execution" ];
  check (list tool_outcome) "late result belongs to the old occurrence"
    [ Transcript.Returned; Awaiting_result ] (outcomes ());
  feed t [ Live.Run_failed { message = "second attempt failed" } ];
  check (list tool_outcome) "failure preserves earlier completed evidence"
    [ Transcript.Returned; Never_returned ] (outcomes ())

(* The settle instant is the block's far end: it is stamped by the first
   end-of-turn delta and never moved by the ones that follow, so a turn that
   ran twenty minutes can say so while the deltas that closed it arrive
   moments apart. A turn still working has no far end to name. *)
let test_settled_at_takes_the_first_end_of_turn_delta () =
  let settled = fresh () in
  check (option (float 0.001)) "a working turn has not settled" None
    (Transcript.settled_at settled);
  feed ~now:(origin +. 120.) settled
    [ Live.Run_started; Live.Run_finished ];
  check (option (float 0.001)) "RUN_FINISHED stamps the settle instant"
    (Some (origin +. 120.))
    (Transcript.settled_at settled);
  feed ~now:(origin +. 125.) settled [ reply_details () ];
  check (option (float 0.001)) "a later reply does not move it" (Some (origin +. 120.))
    (Transcript.settled_at settled)

let test_settled_at_keeps_a_failure_instant_too () =
  let failed = fresh () in
  feed ~now:(origin +. 45.) failed
    [ Live.Run_started; Live.Run_failed { message = "provider 429" } ];
  check (option (float 0.001)) "a failed turn settled when it failed"
    (Some (origin +. 45.))
    (Transcript.settled_at failed)

let test_a_finished_run_does_not_go_back_to_working () =
  let t = fresh () in
  feed t [ Live.Run_started; Live.Run_finished; Live.Run_started ];
  check phase "a repeated RUN_STARTED does not reopen the turn"
    Transcript.Stream_ended (Transcript.phase t)

let test_unreadable_lines_are_counted_with_their_last_reason () =
  let t = fresh () in
  check (option bool) "a clean turn reports nothing unreadable" None
    (Option.map (fun _ -> true) (Transcript.unreadable t));
  feed t
    [ Live.Undecodable "invalid JSON: x"; Live.Undecodable "event has no type" ];
  match Transcript.unreadable t with
  | Some { count; last_detail } ->
      check int "both are counted" 2 count;
      check string "and the latest reason is kept" "event has no type"
        last_detail
  | None -> fail "expected the unreadable lines to be reported"

let test_interrupt_is_recorded_as_a_signal_not_an_outcome () =
  let t = fresh () in
  check bool "nothing requested yet" true
    (Transcript.interrupt t = Transcript.Not_requested);
  Transcript.note_interrupt t
    (Transcript.Signal_sent { turn_id = Some 7; signalled_at_ns = 100_000_000_000L });
  check bool "the signal is recorded" true
    (Transcript.interrupt t
     = Transcript.Signal_sent { turn_id = Some 7; signalled_at_ns = 100_000_000_000L });
  (* The signal says nothing about whether the turn stopped, so the phase has
     to stay whatever the stream last said. *)
  check phase "signalling does not end the turn" Transcript.Waiting
    (Transcript.phase t)

(* Everything the pane draws for a live turn arrived from the keeper over the
   wire, so a reply that carries terminal control bytes must not be able to
   move the cursor or repaint the screen. The escape is assembled across two
   deltas on purpose: scrubbing each fragment as it lands would let this
   through, because neither half is an escape by itself. *)
let contains ~needle haystack =
  let needle_length = String.length needle in
  let limit = String.length haystack - needle_length in
  let rec scan index =
    index <= limit
    && (String.sub haystack index needle_length = needle || scan (index + 1))
  in
  needle_length = 0 || scan 0

let test_control_bytes_never_reach_the_pane () =
  let t = fresh () in
  feed t
    [ Live.Text {text="before\x1b"; stream_scope=None}
    ; Live.Text {text="[2Jafter"; stream_scope=None}
    ; Live.Thinking "\x1b[31mred"
    ; tool_started "c1" "read_file"
    ; tool_args_delta "c1" "{\"file_path\":\"a\x1b[2Jb.ml\"}"
    ; Live.Run_failed { message = "boom\x1b[2J" }
    ];
  let has_escape text = String.contains text '\x1b' in
  check bool "no escape survives in the reply text" false
    (has_escape (Transcript.text t));
  check bool "the text either side of the escape is kept" true
    (contains ~needle:"before" (Transcript.text t)
     && contains ~needle:"after" (Transcript.text t));
  check bool "no escape survives in the reasoning" false
    (has_escape (Transcript.thinking t));
  check bool "no escape survives in a tool row" false
    (List.exists has_escape (Transcript.tool_rows t));
  check bool "no escape survives in a status row" false
    (List.exists (fun (_, text) -> has_escape text) (rows t))

let approval_rows t =
  rows t
  |> List.filter_map (fun (kind, text) ->
         if kind = Transcript.Answer_needed then Some text else None)

let requested ~call_id ~tool_name ~question =
  Live.Approval_requested
    { call_id; tool_name; args = ""; question; because = "" }

let test_a_held_call_shows_its_question () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; tool_started "c1" "Edit"
    ; requested ~call_id:"c1" ~tool_name:"Edit" ~question:"Run Edit on a.ml?"
    ];
  (match Transcript.awaiting_approval t with
   | Some awaiting ->
       check string "the held call is named" "c1"
         awaiting.Transcript.call_id
   | None -> fail "expected a held call");
  match approval_rows t with
  | [ row ] ->
      check bool "the question is on screen" true
        (contains ~needle:"Run Edit on a.ml?" row);
      (* Without the keys the prompt is a statement, not a question. *)
      check bool "and so is how to answer it" true
        (contains ~needle:"/approve" row && contains ~needle:"/deny" row)
  | rows -> failf "expected one prompt row, got %d" (List.length rows)

let test_an_answer_clears_the_prompt () =
  let t = fresh () in
  feed t
    [ requested ~call_id:"c1" ~tool_name:"Edit" ~question:"Run Edit?"
    ; Live.Approval_settled { call_id = "c1"; outcome = "approve" }
    ];
  check bool "nothing is held any more" true
    (Option.is_none (Transcript.awaiting_approval t));
  check (list string) "and no prompt is drawn" [] (approval_rows t);
  check bool "the decision is approved, not success" true
    (List.exists
       (fun (kind, text) ->
         kind = Transcript.Approval Transcript.Approved
         && contains ~needle:"approval approved" text)
       (rows t))

let test_a_timeout_clears_the_prompt_too () =
  let t = fresh () in
  feed t
    [ requested ~call_id:"c1" ~tool_name:"Edit" ~question:"Run Edit?"
    ; Live.Approval_settled { call_id = "c1"; outcome = "timed_out" }
    ];
  (* The decision is over even though nobody made one. Leaving the prompt up
     would ask again for a call that has already been denied. *)
  check bool "the prompt is gone" true
    (Option.is_none (Transcript.awaiting_approval t));
  check bool "the absent decision is timed out, not failed" true
    (List.exists
       (fun (kind, text) ->
         kind = Transcript.Approval Transcript.Timed_out
         && contains ~needle:"approval timed out" text)
       (rows t))

let test_a_denial_uses_decision_vocabulary () =
  let t = fresh () in
  feed t
    [ requested ~call_id:"c1" ~tool_name:"Edit" ~question:"Run Edit?"
    ; Live.Approval_settled { call_id = "c1"; outcome = "deny" }
    ];
  check bool "the decision is denied, not failed" true
    (List.exists
       (fun (kind, text) ->
         kind = Transcript.Approval Transcript.Denied
         && contains ~needle:"approval denied" text)
       (rows t))

let test_a_late_settle_for_another_call_leaves_the_prompt () =
  let t = fresh () in
  feed t
    [ requested ~call_id:"c2" ~tool_name:"Write" ~question:"Run Write?"
    ; Live.Approval_settled { call_id = "c1"; outcome = "timed_out" }
    ];
  match Transcript.awaiting_approval t with
  | Some awaiting ->
      check string "the prompt on screen is still c2's" "c2"
        awaiting.Transcript.call_id
  | None -> fail "a settle for a different call cleared the wrong prompt"

let test_the_whole_reasoning_trail_is_kept () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Thinking "weighing the first option\n"
    ; Live.Thinking "\n\n"
    ; Live.Thinking "the second one costs less\n"
    ; Live.Thinking "so: the second"
    ];
  (* Not the last line alone. The durable transcript does not keep reasoning,
     so a pane that shows only the conclusion loses how the keeper got there. *)
  check (list string) "every non-blank reasoning line survives, in order"
    [ "weighing the first option"; "the second one costs less"; "so: the second" ]
    (Transcript.thinking_lines t);
  let empty = fresh () in
  check (list string) "a turn that has not reasoned yet has no lines" []
    (Transcript.thinking_lines empty)

let kind_to_string : Transcript.status_kind -> string = function
  | Transcript.Progress -> "progress"
  | Transcript.Answer_needed -> "answer_needed"
  | Transcript.Attention -> "attention"
  | Transcript.Approval outcome ->
      "approval:" ^ Transcript.approval_outcome_to_string outcome

let test_status_rows_grow_only_with_what_they_report () =
  let t = fresh () in
  check (list string) "a turn in flight reports how it is going and nothing else"
    [ "progress" ]
    (rows t |> List.map (fun (kind, _) -> kind_to_string kind));
  Transcript.note_interrupt t
    (Transcript.Signal_sent { turn_id = None; signalled_at_ns = 100_000_000_000L });
  check int "an interrupt adds one row" 2
    (List.length (rows t));
  Transcript.apply ~now:origin t (Live.Undecodable "invalid JSON: x");
  check int "an unreadable line adds one more" 3
    (List.length (rows t))

(* The wait before RUN_STARTED is the one an operator cannot read from the
   outside, and two waits of the same length mean different things: a keeper
   busy with something else, and a run that should already have begun. The
   server says which; before it does, the row can only say the request went
   out. *)
let progress_text ?(now = origin) t =
  match rows ~now t with
  | (Transcript.Progress, text) :: _ -> text
  | rows -> failf "expected a progress row, got %d rows" (List.length rows)

let test_runtime_failover_visibility_and_error_attribution () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Runtime_attempt_started
        { runtime_id = Some "claude-3-7-sonnet"; attempt_index = Some 0 }
    ];
  (* "waiting on", not "connecting to": a named runtime that has sent nothing
     is all the screen observed, and the wait may be a process still starting,
     an endpoint still authenticating, a provider queue or a model thinking. *)
  check bool "the row names the runtime it is waiting on" true
    (contains ~needle:"waiting on [claude-3-7-sonnet]" (progress_text t));
  check (option string) "current runtime is claude" (Some "claude-3-7-sonnet")
    (Transcript.current_runtime_id t);
  feed t [ Live.Text {text="streaming token"; stream_scope=None} ];
  (* A text token identifies answer streaming and the serving runtime. *)
  check bool "a text token identifies answer streaming" true
    (contains ~needle:"STREAMING · answering · [claude-3-7-sonnet]" (progress_text t));
  feed t
    [ Live.Runtime_attempt_started
        { runtime_id = Some "gpt-4o"; attempt_index = Some 1 }
    ];
  check bool "failover attempt is indicated" true
    (* Second attempt: [attempt_index] is 0-based on the wire and the row
       counts from 1, the way the superseded blocks beside it do. *)
    (contains ~needle:"runtime candidate: waiting on [gpt-4o] (attempt 2)" (progress_text t));
  check (option string) "current runtime updated to failover" (Some "gpt-4o")
    (Transcript.current_runtime_id t);
  feed t [ Live.Run_failed { message = "RateLimitExceeded (429)" } ];
  check phase "error is attributed to active runtime"
    (Transcript.Stream_failed "[gpt-4o] RateLimitExceeded (429)")
    (Transcript.phase t)

let test_the_turn_reports_the_tokens_it_has_spent () =
  let usage ?(keeper_name = "keeper.one") transcript =
    Transcript.stream_details_text ~keeper_name transcript
  in
  let counters ?stop_reason usage = Live.Stream_details { stream_scope = None; usage = Some usage; stop_reason } in
  check (option string) "nothing is claimed without a transcript" None (usage None);
  let t = fresh () in
  check (option string) "a turn that reported no counters says nothing" None
    (usage (Some t));
  feed t
    [ Live.Run_started
    ; Live.Runtime_attempt_started
        { runtime_id = Some "observed-glm"; attempt_index = Some 0 }
    ; counters
        { input_tokens = Some 1200
        ; output_tokens = Some 340
        ; cache_read_input_tokens = None
        ; cache_creation_input_tokens = None
        }
    ];
  (* Counters that were not reported are absent rather than drawn as zero, and
     the digits are written out: a reader checking this against a bill needs
     the number, not a rounded stand-in. *)
  check (option string) "the reported counters are drawn whole"
    (Some "tokens: in 1200 \xc2\xb7 out 340") (usage (Some t));
  check (option string) "another keeper's transcript reports nothing" None
    (usage ~keeper_name:"keeper.other" (Some t));
  (* Cumulative: a later report replaces the earlier one instead of adding. *)
  feed t
    [ counters
        { input_tokens = Some 1200
        ; output_tokens = Some 900
        ; cache_read_input_tokens = Some 4096
        ; cache_creation_input_tokens = None
        }
    ];
  check (option string) "the latest report stands for the request"
    (Some "tokens: in 1200 \xc2\xb7 out 900 \xc2\xb7 cache read 4096") (usage (Some t));
  (* The provider's word for why it stopped writing. [Keeper_turn_outcome.t]
     cannot say this: a reply cut off at max_tokens is still a visible reply,
     so without this clause the screen shows a finished answer and no sign
     that the provider ran out of room. *)
  feed t [ Live.Stream_details { stream_scope = None; usage = None; stop_reason = Some Agent_core.Types.MaxTokens } ];
  check (option string) "why the provider stopped joins the same clause"
    (Some
       "tokens: in 1200 \xc2\xb7 out 900 \xc2\xb7 cache read 4096 \xc2\xb7 stopped: max_tokens")
    (usage (Some t));
  (* A delta that carried only counters leaves the reason standing, and the
     ordinary reason is drawn too: keeping a list of reasons worth hiding
     would go stale the day a provider adds one. *)
  feed t
    [ counters ~stop_reason:Agent_core.Types.EndTurn
        { input_tokens = Some 1200
        ; output_tokens = Some 950
        ; cache_read_input_tokens = Some 4096
        ; cache_creation_input_tokens = None
        }
    ];
  check (option string) "an ordinary stop reason is drawn like any other"
    (Some
       "tokens: in 1200 \xc2\xb7 out 950 \xc2\xb7 cache read 4096 \xc2\xb7 stopped: end_turn")
    (usage (Some t));
  (* Both facts belong to the request that reported them. A turn that calls
     tools asks again after every tool result, and the counters accumulate
     inside one request while the reason arrives at its end. Round two starts
     from neither: leaving round one's numbers up would call one round's
     tokens what the turn has spent, and leaving [stopped: tool_use] up would
     say the provider has stopped while round two is still writing. *)
  feed t
    [ counters ~stop_reason:Agent_core.Types.StopToolUse
        { input_tokens = Some 1200
        ; output_tokens = Some 980
        ; cache_read_input_tokens = Some 4096
        ; cache_creation_input_tokens = None
        }
    ; Live.Stream_model_started { stream_scope = None; message_id = None; model = "glm-5-turbo"; usage = None }
    ];
  check (option string) "a second round starts from neither" None
    (usage (Some t));
  feed t [ Live.Text {text="still writing"; stream_scope=None} ];
  check (option string) "and text arriving does not bring the old ones back"
    None (usage (Some t));
  feed t
    [ counters
        { input_tokens = Some 30
        ; output_tokens = Some 12
        ; cache_read_input_tokens = None
        ; cache_creation_input_tokens = None
        }
    ];
  check (option string) "it reports only what that round has spent"
    (Some "tokens: in 30 \xc2\xb7 out 12") (usage (Some t));
  (* A new attempt counts its own tokens: carrying the old ones over would
     bill the new runtime for what the failed one spent. *)
  feed t
    [ Live.Runtime_attempt_started
        { runtime_id = Some "gpt-4o"; attempt_index = Some 1 }
    ];
  check (option string) "a new attempt starts from no counters" None (usage (Some t));
  (* The reason belongs to the attempt as much as the counters do: carrying it
     over would blame the new runtime for how the old runtime's answer ended.
     The reason has to be on the header when the attempt changes or this
     asserts nothing -- the request reset above has already cleared it. *)
  feed t
    [ counters ~stop_reason:Agent_core.Types.MaxTokens
        { input_tokens = Some 40
        ; output_tokens = Some 20
        ; cache_read_input_tokens = None
        ; cache_creation_input_tokens = None
        }
    ];
  check (option string) "the reason is on the header before the failover"
    (Some "tokens: in 40 \xc2\xb7 out 20 \xc2\xb7 stopped: max_tokens")
    (usage (Some t));
  feed t
    [ Live.Runtime_attempt_started
        { runtime_id = Some "gpt-4o-mini"; attempt_index = Some 2 }
    ];
  check (option string) "a new attempt starts from no reason either" None
    (usage (Some t))

(* The stop reason arrived after the counters were already on the header, so a
   frame that had room for the counters and not for both must keep drawing the
   counters. Losing them would be a regression against the row as it shipped,
   and the narrow frames are exactly where a reader has least to go on. *)
let test_a_narrow_row_keeps_the_counters_it_was_drawing () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Runtime_attempt_started
        { runtime_id = Some "observed-glm"; attempt_index = Some 0 }
    ; (let counters ?stop_reason usage =
         Live.Stream_details { stream_scope = None; usage = Some usage; stop_reason }
       in
       counters ~stop_reason:Agent_core.Types.MaxTokens
         { input_tokens = Some 1200
         ; output_tokens = Some 900
         ; cache_read_input_tokens = Some 4096
         ; cache_creation_input_tokens = None
         })
    ];
  let cells text = Masc_tui_message_layout.display_width (" \xc2\xb7 " ^ text) in
  let tokens = "tokens: in 1200 \xc2\xb7 out 900 \xc2\xb7 cache read 4096" in
  let both = tokens ^ " \xc2\xb7 stopped: max_tokens" in
  let within room =
    Transcript.stream_details_within ~keeper_name:"keeper.one" ~room (Some t)
  in
  check (option string) "a frame with room for both draws both"
    (Some (" \xc2\xb7 " ^ both))
    (within (cells both));
  (* The dividing width: one cell short of both, and only there does the
     fallback decide anything. Without it the row draws nothing here. *)
  check (option string) "one cell short of both keeps the counters"
    (Some (" \xc2\xb7 " ^ tokens))
    (within (cells both - 1));
  check (option string) "and so does a frame with room for the counters alone"
    (Some (" \xc2\xb7 " ^ tokens))
    (within (cells tokens));
  check (option string) "below that the row is what it was before" None
    (within (cells tokens - 1));
  check (option string) "a room of nothing claims nothing" None (within 0);
  check (option string) "another keeper's transcript claims nothing" None
    (Transcript.stream_details_within ~keeper_name:"keeper.other"
       ~room:(cells both) (Some t))

let test_new_attempt_does_not_inherit_previous_runtime () =
  List.iter (fun attempt_index ->
    let t = fresh () in
    feed t
      [ Live.Run_started
      ; Live.Runtime_attempt_started
          { runtime_id = Some "old-runtime"; attempt_index = Some 0 }
      ; Live.Text {text="old attempt text"; stream_scope=None}
      ; Live.Runtime_attempt_started { runtime_id = None; attempt_index }
      ];
    check (option string) "new attempt starts with unknown runtime" None
      (Transcript.current_runtime_id t);
    check string "unknown attempt header falls back to labelled configuration"
      "configured: assigned-runtime"
      (Transcript.runtime_identity_text ~keeper_name:"keeper.one"
         ~configured_runtime:"assigned-runtime" (Some t));
    feed t [ Live.Stream_model_started { stream_scope = None; message_id = None; model = "new-model"; usage = None } ];
    (* A model name is not a runtime id: the header says which it has. *)
    check (option string) "the model event does not name a runtime" None
      (Transcript.current_runtime_id t);
    check string "the header labels the observed model as a model"
      "model: new-model · configured: assigned-runtime"
      (Transcript.runtime_identity_text ~keeper_name:"keeper.one"
         ~configured_runtime:"assigned-runtime" (Some t));
    feed t [ Live.Runtime_attempt_started
      { runtime_id = None; attempt_index = Some 1 } ];
    check string "same-attempt repeat preserves the observed model"
      "model: new-model · configured: assigned-runtime"
      (Transcript.runtime_identity_text ~keeper_name:"keeper.one"
         ~configured_runtime:"assigned-runtime" (Some t));
    feed t [ Live.Runtime_attempt_started
      { runtime_id = Some "named-runtime"; attempt_index = Some 1 } ];
    check string "a runtime id named for the attempt takes the turn label"
      "turn: named-runtime · configured: assigned-runtime"
      (Transcript.runtime_identity_text ~keeper_name:"keeper.one"
         ~configured_runtime:"assigned-runtime" (Some t));
    (match Transcript.trail t with
     | [ Transcript.Trail_superseded { attempt = 0; runtime_id; _ } ] ->
       check (option string) "superseded block retains its old runtime"
         (Some "old-runtime") runtime_id
     | _ -> fail "old attempt boundary changed");
    check string "header keeps the runtime named for this attempt"
      "turn: named-runtime · configured: assigned-runtime"
      (Transcript.runtime_identity_text ~keeper_name:"keeper.one"
         ~configured_runtime:"assigned-runtime" (Some t)))
    [ Some 1; None ]

let test_drawn_items_carry_superseded_runtime_id () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Runtime_attempt_started
        { runtime_id = Some "claude-3-7-sonnet"; attempt_index = Some 0 }
    ; Live.Text {text="attempt zero reply"; stream_scope=None}
    ; Live.Runtime_attempt_started
        { runtime_id = Some "gpt-4o"; attempt_index = Some 1 }
    ; Live.Text {text="attempt one reply"; stream_scope=None}
    ];
  let items = Transcript.drawn t in
  match items with
  | [ first; second ] ->
      check (option int) "first item is superseded attempt 0" (Some 0) first.superseded;
      check (option string) "first item records superseded runtime"
        (Some "claude-3-7-sonnet") first.superseded_runtime_id;
      check (option int) "second item is current attempt" None second.superseded;
      check (option string) "second item has no superseded runtime" None
        second.superseded_runtime_id
  | _ -> failf "expected 2 drawn items, got %d" (List.length items)

let activity ~name ~outcome =
  Transcript.make_tool_activity ~call_id:(Some name) ~tool_name:name ~args:""
    ~outcome ~duration:None ()

let summary_outcome mode activities =
  (Transcript.project_tool_block mode (Transcript.tool_block ~omitted_steps:0 activities))
    .Transcript.summary_outcome

let test_a_fold_reports_the_outcome_its_marker_stands_for () =
  let outcome = tool_outcome in
  check (option outcome) "a fold holding a failure reports it"
    (Some Transcript.Failed)
    (summary_outcome Transcript.Compact
       [ activity ~name:"read_file" ~outcome:Transcript.Returned
       ; activity ~name:"edit_file" ~outcome:Transcript.Failed
       ]);
  check (option outcome) "one call still out outranks the ones that returned"
    (Some Transcript.Awaiting_result)
    (summary_outcome Transcript.Compact
       [ activity ~name:"read_file" ~outcome:Transcript.Returned
       ; activity ~name:"glob" ~outcome:Transcript.Awaiting_result
       ]);
  check (option outcome) "a fold where every call returned reports that"
    (Some Transcript.Returned)
    (summary_outcome Transcript.Compact
       [ activity ~name:"read_file" ~outcome:Transcript.Returned
       ; activity ~name:"glob" ~outcome:Transcript.Returned
       ]);
  check (option outcome) "a settled unresolved call is not labelled preparing"
    (Some Transcript.Never_returned)
    (summary_outcome Transcript.Compact
       [ activity ~name:"Read" ~outcome:Transcript.Returned
       ; activity ~name:"keeper_analyze_image" ~outcome:Transcript.Never_returned
       ]);
  (* Expanded, every call keeps a row and a marker of its own, so there is no
     one outcome the entry stands for and nothing to colour it by. *)
  check (option outcome) "an expanded block reports no summary outcome" None
    (summary_outcome Transcript.Full
       [ activity ~name:"read_file" ~outcome:Transcript.Returned
       ; activity ~name:"edit_file" ~outcome:Transcript.Failed
       ]);
  (* A single call is not folded in either mode: it already has its own row. *)
  check (option outcome) "a lone call is never a fold" None
    (summary_outcome Transcript.Compact
       [ activity ~name:"edit_file" ~outcome:Transcript.Failed ])

let test_compact_and_full_keep_the_same_typed_facts () =
  let activities =
    [ Transcript.make_tool_activity ~call_id:(Some "c1")
        ~tool_name:"read_file" ~args:"{\"file_path\":\"a.ml\"}"
        ~outcome:Transcript.Returned ~duration:(Some "12ms") ()
    ; Transcript.make_tool_activity ~call_id:(Some "c2")
        ~tool_name:"edit_file" ~args:"{\"file_path\":\"b.ml\"}"
        ~outcome:Transcript.Failed ~duration:(Some "18ms") ()
    ; Transcript.make_tool_activity ~call_id:None ~tool_name:"glob" ~args:""
        ~outcome:Transcript.Outcome_unrecorded ~duration:None ()
    ]
  in
  let block = Transcript.tool_block ~omitted_steps:2 activities in
  let full = Transcript.project_tool_block Transcript.Full block in
  let compact = Transcript.project_tool_block Transcript.Compact block in
  check (list tool_call) "full retains identity, order, outcome and duration"
    activities full.Transcript.activities;
  check (list tool_call) "compact retains the exact same typed facts" activities
    compact.Transcript.activities;
  check int "full retains the source omission count" 2 full.omitted_steps;
  check int "compact retains the same source omission count" 2
    compact.omitted_steps;
  check (list string) "full keeps the shipping row bytes"
    [ "✓ read_file a.ml · 12ms"
    ; "✗ edit_file b.ml · 18ms"
    ; "? glob"
    ; "(2 steps not carried by the transcript)"
    ]
    full.details;
  check int "full has three details plus the transcript omission" 4
    (List.length full.details);
  check int "full hides no detail row" 0 full.hidden_activity_rows;
  (* Full draws a header too now, over details that are all visible: it is a
     rollup, not a fold, so it claims no folded count. *)
  check bool "full heads the block" true (full.header <> None);
  check int "compact keeps the trouble row and the transcript omission" 2
    (List.length compact.details);
  check int "compact states exactly how many rows it hid" 3
    compact.hidden_activity_rows;
  let inventory =
    match compact.header with
    | Some inventory -> inventory
    | None -> Alcotest.fail "a folded three-call block heads with its inventory"
  in
  let trouble = List.hd compact.details in
  (* The mark opens the row and the names follow it; the row does not spell
     the TOOLS label the transcript already draws beside it. *)
  check bool "the inventory row opens with the block's mark and a name" true
    (String.starts_with ~prefix:"✗ read_file 1" inventory);
  check bool "the inventory row does not spell its own label" false
    (contains ~needle:"Tools" inventory);
  check bool "the inventory row claims no fold" false
    (contains ~needle:"folded" inventory);
  check bool "the inventory row keeps what returned" true
    (contains ~needle:"1 returned" inventory);
  check bool "the inventory row leaves the failure to the row below" false
    (contains ~needle:"1 failed" inventory);
  check bool "the trouble row names the failure" true
    (contains ~needle:"1 failed" trouble);
  check bool "an unrecorded outcome is bookkeeping, so it stays above" true
    (contains ~needle:"1 outcome unrecorded" inventory);
  check bool "and does not reach the trouble row" false
    (contains ~needle:"unrecorded" trouble);
  check bool "the trouble row carries its own mark" true
    (String.starts_with ~prefix:"✗ " trouble);
  check string "compact does not count the visible omission as hidden"
    (List.nth full.details 3) (List.nth compact.details 1)

let full_tool_rows block =
  (Transcript.project_tool_block Transcript.Full block).Transcript.details

let rec trail_item_to_string : Transcript.trail_item -> string = function
  | Transcript.Trail_thinking lines ->
      "thinking(" ^ String.concat "\\n" lines ^ ")"
  | Transcript.Trail_skill skills ->
      "skill("
      ^ String.concat "\\n" (Transcript.skill_rows ~full:true skills)
      ^ ")"
  | Transcript.Trail_tools block ->
      "tools(" ^ String.concat "\\n" (full_tool_rows block) ^ ")"
  | Transcript.Trail_text text -> "text(" ^ text ^ ")"
  | Transcript.Trail_superseded { attempt; items; runtime_id } ->
      Printf.sprintf "superseded(%d,%s,[%s])" attempt
        (Option.value ~default:"-" runtime_id)
        (String.concat "; " (List.map trail_item_to_string items))

let trail_item = testable (Fmt.of_to_string trail_item_to_string) ( = )

(* [of_log] is the same fold the live path runs delta by delta. *)
let test_of_log_equals_the_incremental_fold () =
  let deltas =
    [ Live.Run_started
    ; Live.Thinking "find the file"
    ; tool_started "c1" "read_file"
    ; tool_args_delta "c1" "{\"file_path\":\"a.ml\"}"
    ; tool_ended "c1"
    ; tool_result "c1" "exec-c1"
    ; Live.Text {text="half "; stream_scope=None}
    ; Live.Runtime_attempt_started { runtime_id = Some "claude-3-7-sonnet"; attempt_index = Some 1 }
    ; Live.Thinking "again"
    ; Live.Text {text="whole reply"; stream_scope=None}
    ; reply_details ~reply:"whole reply" ()
    ; Live.Run_finished
    ]
  in
  let incremental = fresh () in
  feed incremental deltas;
  let log = Log.create ~keeper_name:"keeper.one" ~request_id:"req-1" ~started_at:origin in
  List.iteri (fun seq delta -> ignore (Log.add log ~seq:(Some seq) delta : bool)) deltas;
  let refolded = Transcript.of_log ~now:origin log in
  check (list trail_item) "same trail" (Transcript.trail incremental) (Transcript.trail refolded);
  check string "same text" (Transcript.text incremental) (Transcript.text refolded);
  check string "same thinking" (Transcript.thinking incremental) (Transcript.thinking refolded);
  check int "same attempt" (Transcript.attempt incremental) (Transcript.attempt refolded);
  check phase "same phase" (Transcript.phase incremental) (Transcript.phase refolded);
  check (list string) "same tool rows" (Transcript.tool_rows incremental)
    (Transcript.tool_rows refolded);
  check bool "same reply" true (Transcript.reply incremental = Transcript.reply refolded);
  check string "identity comes from the log" "req-1" (Transcript.request_id refolded)
;;

let test_trail_keeps_arrival_order () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Thinking "find the file first"
    ; tool_started "c1" "read_file"
    ; tool_args_delta "c1" "{\"file_path\":\"lib/keeper/a.ml\"}"
    ; tool_ended "c1"
    ; tool_result "c1" "exec-c1"
    ; Live.Thinking "now the caller"
    ; Live.Text {text="The caller is safe."; stream_scope=None}
    ];
  match Transcript.trail t with
  | [ Transcript.Trail_thinking first
    ; Transcript.Trail_tools block
    ; Transcript.Trail_thinking second
    ; Transcript.Trail_text reply
    ] ->
      check (list string) "the first stretch of reasoning stands alone"
        [ "find the file first" ] first;
      let rows = full_tool_rows block in
      check int "one call, one row" 1 (List.length rows);
      check bool "the row carries the result marker" true
        (contains ~needle:"✓" (List.hd rows));
      check (list string) "the round-two reasoning is its own stretch"
        [ "now the caller" ] second;
      check string "the reply closes the trail" "The caller is safe." reply
  | items ->
      failf "expected thinking/tools/thinking/text, got %d item(s): %s"
        (List.length items)
        (String.concat "; " (List.map trail_item_to_string items))

(* A GLM stretch as it streams: paragraphs split by runs of blank lines, a
   padded blank, a leading and a trailing break. The pane keeps one empty line
   per break and none at either end. *)
let test_trail_keeps_one_empty_line_per_paragraph_break () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Thinking "\n\nMain is red."
    ; Live.Thinking "\nTwo causes:\n\n\n\n1. the board test"
    ; Live.Thinking "\n  \n2. the stale cmi\n\n"
    ];
  match Transcript.trail t with
  | [ Transcript.Trail_thinking lines ] ->
      check (list string) "one empty line per break"
        [ "Main is red."; "Two causes:"; ""; "1. the board test"; "";
          "2. the stale cmi" ]
        lines
  | items -> failf "expected one reasoning stretch, got %d items" (List.length items)

let test_trail_groups_consecutive_calls_into_one_block () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; tool_started "c1" "read_file"
    ; tool_started "c2" "execute"
    ; Live.Text {text="done"; stream_scope=None}
    ];
  match Transcript.trail t with
  | [ Transcript.Trail_tools block; Transcript.Trail_text _ ] ->
      let rows = full_tool_rows block in
      check int "two consecutive calls draw as one block" 2 (List.length rows)
  | items ->
      failf "expected tools/text, got %d item(s): %s" (List.length items)
        (String.concat "; " (List.map trail_item_to_string items))

let test_trail_updates_a_call_after_later_stretches_open () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; tool_started "c1" "read_file"
    ; Live.Thinking "while it runs"
    ; tool_args_snapshot "c1" "{\"file_path\":\"lib/keeper/a.ml\"}"
    ; tool_result "c1" "exec-c1"
    ];
  match Transcript.trail t with
  | [ Transcript.Trail_tools block; Transcript.Trail_thinking _ ] ->
      let rows = full_tool_rows block in
      let row = List.hd rows in
      check bool "the late arguments reach the earlier row" true
        (contains ~needle:"a.ml" row);
      check bool "the late result reaches the earlier row" true
        (contains ~needle:"✓" row)
  | items ->
      failf "expected tools/thinking, got %d item(s): %s" (List.length items)
        (String.concat "; " (List.map trail_item_to_string items))

let test_trail_drops_blank_stretches () =
  let t = fresh () in
  feed t [ Live.Run_started; Live.Thinking "\n\n"; Live.Text {text="  "; stream_scope=None} ];
  check (list trail_item) "blank stretches draw nothing" []
    (Transcript.trail t)

let test_live_skill_is_not_folded_into_generic_tools () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; tool_started "skill-use-1" "keeper_skill"
    ; tool_args_snapshot "skill-use-1"
        {|{"identity":{"source_id":"local","package_id":"ops","name":"ci-red-attribution"}}|}
    ; tool_ended "skill-use-1"
    ; tool_result "skill-use-1" "exec-skill-1"
    ; Live.Text {text="done"; stream_scope=None}
    ];
  match Transcript.trail t with
  | [ Transcript.Trail_skill [ skill ]; Transcript.Trail_text "done" ] ->
      check string "the nested identity names the Skill" "ci-red-attribution"
        skill.skill_name;
      check bool "the read tool is an instruction read" true
        (skill.invocation = Some Transcript.Instruction_read);
      check bool "a returned body is not yet claimed as used" true
        (skill.state = Transcript.Skill_served_pending);
      (match Transcript.skill_rows ~full:false [ skill ] with
       | [ row ] ->
           check string "the compact row is the bold name and nothing else"
             "**ci-red-attribution**" row
       | rows -> failf "expected one compact Skill row, got %d" (List.length rows));
      (match Transcript.skill_rows ~full:true [ skill ] with
       | row :: _ ->
           check bool "the full row says the delivery is pending" true
             (contains ~needle:"**읽음, 전달 확인 중**" row)
       | [] -> fail "expected full Skill rows")
  | items ->
      failf "expected skill/text, got %d item(s): %s" (List.length items)
        (String.concat "; " (List.map trail_item_to_string items))

let test_terminal_skill_is_not_still_calling () =
  let t = fresh () in
  feed t [ Live.Run_started; tool_started "skill" "keeper_skill";
           tool_ended "skill"; Live.Run_failed { message = "provider timeout" } ];
  match Transcript.trail t with
  | [ Transcript.Trail_skill [ skill ] ] ->
    check bool "a missing result does not keep a skill call active" true
      (skill.state = Transcript.Skill_evidence_missing)
  | _ -> fail "expected the skill row to remain visible"

(* A turn that runs the same composition seven times is one skill stretch,
   and the compact row counts the triggers. Seven identical rows between a
   journal row and a tool block is what the pane drew before
   (msx-retro-mania, 2026-09-22). *)
let test_consecutive_live_skill_calls_are_one_counted_block () =
  let t = fresh () in
  let call index =
    let id = Printf.sprintf "compose-%d" index in
    [ tool_started id "keeper_compose_msx-observe"
    ; tool_ended id
    ; tool_result id (Printf.sprintf "exec-%d" index)
    ]
  in
  feed t
    (Live.Run_started
     :: List.concat_map call [ 1; 2; 3; 4; 5; 6; 7 ]
     @ [ tool_started "press" "masc_msx_press"
       ; tool_ended "press"
       ; tool_result "press" "exec-press"
       ]);
  match Transcript.trail t with
  | [ Transcript.Trail_skill skills; Transcript.Trail_tools tools ] ->
      check int "seven invocations in one block" 7 (List.length skills);
      check bool "a composition's own tool names it as run" true
        ((List.hd skills).invocation
         = Some (Transcript.Composition_run { tool_name = "keeper_compose_msx-observe" }));
      check (list string) "the compact row counts the triggers"
        [ "**msx-observe** \xc3\x977" ]
        (Transcript.skill_rows ~full:false skills);
      let full = Transcript.skill_rows ~full:true skills in
      check int "full: one summary and one proof line per invocation" 7
        (List.length
           (List.filter (fun row -> contains ~needle:"**msx-observe**" row) full));
      check bool "full: a composition ran, it was not read" true
        (contains ~needle:"**실행됨, 전달 확인 중** \xc2\xb7 **msx-observe**"
           (List.hd full));
      check int "the generic call is its own block" 1
        (List.length tools.Transcript.activities)
  | items ->
      failf "expected one skill block then one tool block, got %d: %s"
        (List.length items)
        (String.concat "; " (List.map trail_item_to_string items))

(* A trigger that failed is the one thing the compact row says beside the
   count: the others are bookkeeping the full rows keep. *)
let test_a_failed_trigger_is_named_on_the_compact_row () =
  let ok =
    Transcript.make_skill_activity ~invocation:Transcript.Instruction_read
      ~skill_name:"prior-art" ~state:Transcript.Skill_used ~actions:[ "Read" ] ()
  in
  let failed =
    Transcript.make_skill_activity ~invocation:Transcript.Instruction_read
      ~skill_name:"prior-art" ~state:Transcript.Skill_failed ~actions:[] ()
  in
  check (list string) "the count, then what went wrong"
    [ "**prior-art** \xc3\x972 \xc2\xb7 실패 1" ]
    (Transcript.skill_rows ~full:false [ ok; failed ]);
  check bool "the block draws in the failure's state" true
    (Transcript.skill_block_state [ ok; failed ] = Transcript.Skill_failed)

let test_checkpoint_wait_keeps_the_request_live () =
  let t = fresh () in
  feed t [Live.Run_started; tool_started ~block_index:0 "before" "read_file"; tool_ended ~block_index:0 "before";
    tool_result ~block_index:0 "before" "exec-before"; Live.Reply_details {terminal_stream_scope = None; reply="";
    turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint; turn_ref="trace-1#3"}; Live.Run_finished];
  check bool "checkpoint waits for continuation" true (Transcript.awaiting_continuation t);
  check (option (float 0.)) "checkpoint does not settle request" None (Transcript.settled_at t);
  check int "an idle continuation reserves no status row even days later" 0
    (List.length (rows ~now:(origin +. 172_800.) t));
  feed t [Live.Run_started];
  check bool "the next segment restores progress" true
    (List.exists (fun (kind, _) -> kind = Transcript.Progress) (rows t));
  check phase "continued segment is working" Transcript.Working (Transcript.phase t);
  check bool "new segment no longer waits" false (Transcript.awaiting_continuation t);
  feed t [tool_started ~block_index:0 "after" "read_file"; tool_ended ~block_index:0 "after";
    tool_result ~block_index:0 "after" "exec-after"; Live.Text {text="answer"; stream_scope=None}; reply_details ~reply:"answer" (); Live.Run_finished];
  check phase "actual answer ends request" Transcript.Stream_ended (Transcript.phase t);
  check int "reused stream coordinates preserve both segments" 2 (List.length (Transcript.tool_calls t))
;;

(* The sheet's legend for the chat is built from the same functions the rows
   draw with, so every outcome mark and every skill phrase the pane can
   print is on it, once, spelled as the pane spells it. A phrase holds no
   interpunct: on the row that is the separator between the phrase and the
   skill name, and a phrase with one inside would read as two phrases. *)
let test_the_legend_names_every_mark_and_phrase_the_rows_draw () =
  let keys = List.map fst Transcript.legend in
  check bool "received result mark is explained without a success claim" true
    (List.mem (Transcript.received_marker ^ " received") keys);
  (* The two lists are written by hand: a constructor added later compiles
     (the label functions are exhaustive) but would be missing from the
     rollup and the legend, so their lengths are held here. *)
  check int "eight outcomes" 8 (List.length Transcript.all_outcomes);
  check int "eight skill states" 8 (List.length Transcript.all_skill_states);
  List.iter
    (fun outcome ->
      let key =
        Transcript.marker_of_outcome outcome ^ " " ^ Transcript.outcome_label outcome
      in
      check bool ("outcome " ^ key ^ " is on the legend with its mark") true
        (List.mem key keys))
    Transcript.all_outcomes;
  (* The two words a full skill row draws beside its ids and actions are
     on the legend as the row spells them. *)
  let full =
    String.concat "\n"
      (Transcript.skill_rows ~full:true
         [ Transcript.make_skill_activity ~skill_name:"s" ~skill_tool_use_id:"use-1"
             ~state:Transcript.Skill_used ~actions:[ "Read" ] () ])
  in
  List.iter
    (fun word ->
      check bool ("the row draws " ^ word) true (contains ~needle:word full);
      check bool ("the legend explains " ^ word) true (List.mem word keys))
    [ "proof"; "observed action" ];
  List.iter
    (fun state ->
      let phrase = Transcript.skill_state_label state in
      check bool ("phrase " ^ phrase ^ " is on the legend") true (List.mem phrase keys);
      check bool ("phrase " ^ phrase ^ " holds no interpunct") false
        (contains ~needle:"\xc2\xb7" phrase))
    Transcript.all_skill_states;
  check int "no key twice" (List.length keys)
    (List.length (List.sort_uniq String.compare keys));
  List.iter
    (fun (key, meaning) ->
      check bool ("legend row " ^ key ^ " says something") true
        (String.length (String.trim meaning) > 0))
    Transcript.legend

let test_event_times_survive_log_replay_and_continuation () =
  let log = Log.create ~keeper_name:"keeper.one" ~request_id:"timed" ~started_at:100. in
  let put at delta = ignore (Log.add ~at log ~seq:None delta) in
  put 101. Live.Run_started;
  put 110. (Live.Text {text="First segment."; stream_scope=None});
  put 115. (Live.Reply_details {terminal_stream_scope = None; reply="";
    turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint; turn_ref="trace#1"});
  put 116. Live.Run_finished;
  let checkpoint = Transcript.of_log ~now:999. log |> Transcript.drawn in
  check (list (option (float 0.001))) "checkpoint uses its event time"
    [Some 110.; Some 115.] (List.map (fun (item : Transcript.drawn_item) -> item.at) checkpoint);
  put 140. Live.Run_started;
  put 141. (Live.Runtime_attempt_started {runtime_id=Some "codex"; attempt_index=Some 0});
  (* This continuation supplies a canonical answer without a text delta.
     It cannot replace the first segment's text. *)
  put 150. (Live.Reply_details {terminal_stream_scope = None; reply="Second segment.";
    turn_outcome=Masc.Keeper_turn_outcome.Visible_reply; turn_ref="trace#2"});
  put 151. Live.Run_finished;
  let replayed = Transcript.of_log ~now:999. log |> Transcript.drawn in
  check (list (option (float 0.001))) "server times survive refolding"
    [Some 110.; Some 150.] (List.map (fun (item : Transcript.drawn_item) -> item.at) replayed);
  check (list string) "new canonical reply preserves earlier segment"
    ["First segment."; "Second segment."]
    (List.filter_map (fun (item : Transcript.drawn_item) -> match item.drawn with
      | Drawn_text text | Drawn_reply text -> Some text | _ -> None) replayed);
  check bool "continuation is not a superseded runtime attempt" true
    (List.for_all (fun (item : Transcript.drawn_item) -> item.superseded=None) replayed)
;;

let test_native_tools_are_observations_without_execution_receipts () =
  let t = fresh () in
  let occurrence = occurrence ~block_index:7 "native-7" in
  feed t [Live.Run_started; Live.Native_tool_started {occurrence;tool_name=Some "Read"}];
  let call () = match Transcript.tool_calls t with
    | [call] -> call | calls -> failf "expected one native step, got %d" (List.length calls) in
  check tool_outcome "provider step runs; arguments are not inferred" Transcript.Native_running (call ()).outcome;
  feed t [Live.Native_tool_started {occurrence;tool_name=Some "Read"};
          Live.Native_tool_ended {occurrence}; Live.Native_tool_ended {occurrence}];
  check tool_outcome "provider end is not a result receipt" Transcript.Native_ended (call ()).outcome;
  check (option string) "no invented physical execution" None (call ()).execution_id;
  feed t [Live.Tool_result {occurrence; execution_id="wrong-authority"}];
  check (option string) "MASC receipt cannot attach to native observation" None (call ()).execution_id;
  check bool "mixed-authority event is reported" true (Option.is_some (Transcript.unreadable t));
  let rows = Transcript.project_tool_block Transcript.Compact
      (Transcript.tool_block (Transcript.tool_calls t)) in
  check bool "a single native step has no roll-up summary" true
    (Option.is_none rows.summary_outcome)
;;

let test_response_boundaries_preserve_origins () =
  let speech t = Transcript.drawn t |> List.filter_map (fun (item:Transcript.drawn_item) ->
    match item.drawn with Drawn_text text | Drawn_reply text -> Some text | _ -> None) in
  let cases = [
    "tool round", [Live.Text {text="COMMENTARY"; stream_scope=None}] @ read_file_call;
    "native tool round", [Live.Text {text="COMMENTARY"; stream_scope=None};
      Live.Native_tool_started {occurrence=occurrence "native";tool_name=Some "Read"};
      Live.Native_tool_ended {occurrence=occurrence "native"}];
    "provider response", [Live.Text {text="COMMENTARY"; stream_scope=None};
      Live.Stream_model_started {stream_scope = None; message_id=Some "new";model="glm";usage=None}];
    "retry", [Live.Text {text="COMMENTARY"; stream_scope=None};
      Live.Runtime_attempt_started {runtime_id=Some "retry";attempt_index=Some 1}];
    "continuation", [Live.Text {text="COMMENTARY"; stream_scope=None};
      Live.Reply_details {terminal_stream_scope = None; reply="";turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint;
        turn_ref="trace#1"}; Live.Run_finished; Live.Run_started]
  ] in
  List.iter (fun (label,boundary) ->
    let log = Log.create ~keeper_name:"keeper.one" ~request_id:"req-1" ~started_at:origin in
    let t = fresh () in
    let put delta = ignore (Log.add ~at:origin log ~seq:None delta); Transcript.apply ~now:origin t delta in
    List.iter put (Live.Run_started :: boundary @ [Live.Text {text="PREFIX"; stream_scope=None}; Live.Thinking "thought"; Live.Text {text="SUFFIX"; stream_scope=None}]);
    let before = Transcript.drawn t in
    let last = List.hd (List.rev before) in
    put (reply_details ~reply:"SUFFIX" ());
    put Live.Run_finished;
    check (list string) (label ^ ": prior content and observed order preserved")
      ["COMMENTARY"; "PREFIX"; "SUFFIX"] (speech t);
    let after = Transcript.drawn t in
    let reply = List.find (fun (item:Transcript.drawn_item) -> match item.drawn with Drawn_reply _ -> true | _ -> false) after in
    check bool (label ^ ": reply keeps surviving stretch origin") true (last.origin = reply.origin);
    check bool (label ^ ": origins are unique across boundaries") true
      (let origins = List.map (fun (item:Transcript.drawn_item) -> item.origin) after in
       List.length origins = List.length (List.sort_uniq compare origins));
    check bool (label ^ ": refolding preserves origins and content") true
      (after = Transcript.drawn (Transcript.of_log ~now:origin log))) cases
;;

let test_usage_resets_only_at_response_boundaries () =
  let t = fresh () in
  let usage input output = {Live.input_tokens=input;output_tokens=output;
    cache_read_input_tokens=None;cache_creation_input_tokens=None} in
  let tokens () = Transcript.stream_tokens_text ~keeper_name:"keeper.one" (Some t) in
  let seed () = feed t [Live.Stream_model_started {stream_scope = None; message_id=Some "message";
    model="glm";usage=Some (usage (Some 99) (Some 0))};
    Live.Stream_details {stream_scope=None; usage=Some (usage None (Some 7));stop_reason=Some Agent_core.Types.StopToolUse}] in
  feed t [Live.Run_started]; seed ();
  check (option string) "sparse report retains earlier fields"
    (Some "tokens: in 99 · out 7") (tokens ());
  feed t [Live.Stream_model_started {stream_scope = None; message_id=Some "next";model="glm";usage=None}];
  check (option string) "new message clears old counters" None (tokens ());
  seed ();
  feed t [Live.Stream_model_started {stream_scope = None; message_id=Some "message";model="glm";
    usage=Some (usage (Some 200) (Some 0))}];
  check (option string) "a published response boundary may reuse its provider id"
    (Some "tokens: in 200 · out 0") (tokens ());
  check (option string) "reused provider id retains only its new usage, not the previous stop reason"
    (tokens ()) (Transcript.stream_details_text ~keeper_name:"keeper.one" (Some t));
  feed t [Live.Runtime_attempt_started {runtime_id=Some "retry";attempt_index=Some 1}];
  check (option string) "retry clears prior message counters" None (tokens ());
  seed ();
  feed t [Live.Reply_details {terminal_stream_scope = None; reply="";turn_outcome=Masc.Keeper_turn_outcome.Continuation_checkpoint;
    turn_ref="trace#1"};Live.Run_finished;Live.Run_started];
  check (option string) "continuation does not inherit old counters" None (tokens ());
  check (option string) "continuation does not inherit old stop reason" None
    (Transcript.stream_details_text ~keeper_name:"keeper.one" (Some t));
  seed ();
  check (option string) "same provider id may start again in a new segment"
    (Some "tokens: in 99 · out 7") (tokens ());
  feed t [Live.Stream_details {stream_scope=None; usage=Some {Live.input_tokens=Some 0;
    output_tokens=None;cache_read_input_tokens=Some 12;
    cache_creation_input_tokens=Some 3};stop_reason=None}];
  check (option string) "zero updates one field while absent output is retained"
    (Some "tokens: in 0 · out 7 · cache read 12 · cache write 3") (tokens ());
  feed t [Live.Stream_details {stream_scope=None; usage=Some {Live.input_tokens=None;
    output_tokens=Some 8;cache_read_input_tokens=None;
    cache_creation_input_tokens=None};stop_reason=None}];
  check (option string) "a later sparse output retains both cache fields"
    (Some "tokens: in 0 · out 8 · cache read 12 · cache write 3") (tokens ());
  feed t [Live.Stream_model_started {stream_scope = None; message_id=None;model="unknown-id";usage=None}];
  check (option string) "unidentified start cannot inherit another response's usage"
    None (tokens ())
;;

let test_empty_new_response_does_not_replace_prior_message () =
  let t = fresh () in
  feed t [Live.Run_started;Live.Text {text="EARLIER"; stream_scope=None};
    Live.Stream_model_started {stream_scope = None; message_id=Some "next";model="observed";usage=None};
    reply_details ~reply:"FINAL" ();Live.Run_finished];
  let items = Transcript.drawn t in
  check (list string) "a response without streamed text leaves earlier output in place"
    ["EARLIER";"FINAL"]
    (List.filter_map (fun (item:Transcript.drawn_item) ->
       match item.drawn with Drawn_text text | Drawn_reply text -> Some text | _ -> None) items);
  check bool "unstreamed final uses its own synthetic origin" true
    ((List.hd (List.rev items)).origin = Transcript.Reply_of_segment 0)
;;

let test_scoped_details_retire_prior_model_activity () =
  List.iter (fun activity ->
    let t = fresh () in
    feed t [Live.Run_started;
      Live.Stream_model_started {stream_scope=Some 1;message_id=Some "first";
        model="first-model";usage=None};
      Live.Text {text="earlier response";stream_scope=Some 1};activity];
    let body = Transcript.drawn t in
    let observed = progress_text ~now:(origin +. 40.) t in
    check bool "prior response has observed quiet activity" true
      (contains ~needle:"nothing back for" observed);
    feed ~now:(origin +. 20.) t
      [Live.Stream_details {stream_scope=Some 1;usage=None;
        stop_reason=Some Agent_core.Types.StopToolUse}];
    check string "same-scope details preserve model activity and its observation age"
      observed (progress_text ~now:(origin +. 40.) t);
    feed ~now:(origin +. 30.) t
      [Live.Stream_details {stream_scope=Some 2;usage=None;
        stop_reason=Some Agent_core.Types.StopToolUse}];
    let incoming = progress_text ~now:(origin +. 40.) t in
    check bool "details-only response cannot inherit prior streaming or thinking" false
      (contains ~needle:"STREAMING" incoming || contains ~needle:"THINKING" incoming);
    check bool "details-only response cannot inherit prior model quiet age" false
      (contains ~needle:"nothing back for" incoming);
    check phase "new response metadata keeps Keeper turn running" Transcript.Working
      (Transcript.phase t);
    check bool "retiring model activity preserves prior authored stretches" true
      (body=Transcript.drawn t))
    [Live.Text {text=" continued";stream_scope=Some 1};Live.Thinking "observed reasoning"]
;;

let test_scoped_details_retire_prior_response_usage () =
  let t = fresh () in
  let initial : Live.stream_usage =
    { input_tokens=Some 99; output_tokens=Some 7;
      cache_read_input_tokens=Some 12; cache_creation_input_tokens=Some 3 } in
  let incoming : Live.stream_usage =
    { input_tokens=None; output_tokens=Some 8;
      cache_read_input_tokens=None; cache_creation_input_tokens=None } in
  feed t [Live.Run_started;
    Live.Stream_model_started {stream_scope=Some 1;message_id=Some "first";
      model="first-model";usage=Some initial};
    Live.Text {text="earlier response";stream_scope=Some 1};
    Live.Stream_details {stream_scope=Some 1;usage=None;
      stop_reason=Some Agent_core.Types.StopToolUse};
    Live.Stream_details {stream_scope=Some 2;usage=Some incoming;stop_reason=None}];
  check (option string) "detail-only next response has no prior input/cache/stop"
    (Some "tokens: out 8")
    (Transcript.stream_details_text ~keeper_name:"keeper.one" (Some t));
  feed t [Live.Stream_model_started {stream_scope=Some 2;message_id=Some "second";
    model="second-model";usage=Some {initial with output_tokens=Some 0}}];
  check (option string) "late start fills this response without rewinding output"
    (Some "tokens: in 99 · out 8 · cache read 12 · cache write 3")
    (Transcript.stream_tokens_text ~keeper_name:"keeper.one" (Some t));
  feed t [reply_details ~reply:"final response" ();Live.Run_finished];
  check (list string) "missing start before details keeps earlier speech"
    ["text:earlier response";"reply:final response"] (drawn t)
;;

let () =
  run "tui_keeper_chat_transcript"
    [ ( "response boundaries", [test_case "scoped details retire prior model activity" `Quick test_scoped_details_retire_prior_model_activity;
      test_case "scoped details retire prior response usage" `Quick test_scoped_details_retire_prior_response_usage;
      test_case "boundaries and stable origins" `Quick test_response_boundaries_preserve_origins; test_case "usage reset boundaries" `Quick test_usage_resets_only_at_response_boundaries; test_case "new response without text" `Quick test_empty_new_response_does_not_replace_prior_message])
    ; ( "event timeline"
      , [test_case "replay preserves continuation event times" `Quick test_event_times_survive_log_replay_and_continuation;
         test_case "native tools have no MASC receipt" `Quick test_native_tools_are_observations_without_execution_receipts] )
    ; ( "content"
      , [ test_case "the legend names every mark and phrase the rows draw" `Quick
            test_the_legend_names_every_mark_and_phrase_the_rows_draw
        ; test_case "checkpoint keeps original request live" `Quick test_checkpoint_wait_keeps_the_request_live
        ; test_case "started_at keeps the dispatch instant" `Quick
            test_started_at_keeps_the_dispatch_instant
        ; test_case "settled_at takes the first end-of-turn delta" `Quick
            test_settled_at_takes_the_first_end_of_turn_delta
        ; test_case "settled_at keeps a failure instant too" `Quick
            test_settled_at_keeps_a_failure_instant_too
        ; test_case "text and reasoning accumulate separately" `Quick
            test_text_and_thinking_accumulate
        ; test_case "the whole reasoning trail is kept" `Quick
            test_the_whole_reasoning_trail_is_kept
        ; test_case "runtime attempt restarts the per-attempt totals" `Quick
            test_runtime_attempt_restarts_the_per_attempt_totals
        ; test_case "runtime attempt keeps the earlier attempt superseded" `Quick
            test_runtime_attempt_keeps_the_earlier_attempt_superseded
        ; test_case "reply details is recorded, not drawn" `Quick
            test_reply_details_is_recorded_not_drawn
        ; test_case "drawn is one row when the record differs from the stream by whitespace"
            `Quick test_drawn_is_one_row_when_the_record_differs_from_the_stream_by_whitespace
        ; test_case "drawn places a reply by its operation, not by its text" `Quick
            test_drawn_places_a_reply_by_its_operation_not_by_its_text
        ; test_case "drawn replaces the streamed text with a differing reply" `Quick
            test_drawn_replaces_the_streamed_text_with_a_differing_reply
        ; test_case "drawn keeps earlier rounds when the reply is the last stretch" `Quick
            test_drawn_keeps_earlier_rounds_when_the_reply_is_the_last_stretch
        ; test_case "drawn keeps pre-tool progress when nothing streamed after" `Quick
            test_drawn_keeps_pre_tool_progress_when_nothing_streamed_after
        ; test_case "drawn preserves text around an unobserved skill round" `Quick
            test_drawn_preserves_text_when_a_skill_round_was_unobserved
        ; test_case "missing skill boundaries retain the identified terminal round" `Quick
            test_missing_skill_boundary_reconciles_the_identified_terminal_round
        ; test_case "terminal text scope survives a missing response start" `Quick
            test_terminal_scope_survives_a_missing_start
        ; test_case "final response boundary survives missing Skill call" `Quick
            test_final_response_boundary_survives_a_missing_skill_call
        ; test_case "missing response start keeps prior progress" `Quick
            test_stop_from_an_unobserved_response_preserves_progress
        ; test_case "duplicate response start keeps one reply" `Quick
            test_repeated_response_start_is_not_a_boundary
        ; test_case "scoped text retires prior metadata" `Quick
            test_scoped_text_retires_prior_response_metadata
        ; test_case "drawn reconciles text after an observed skill round" `Quick
            test_drawn_reconciles_text_after_an_observed_skill_round
        ; test_case "note_tool_outcome folds the durable facts in" `Quick
            test_note_tool_outcome_folds_the_durable_facts_in
        ; test_case "drawn appends the reply when nothing streamed" `Quick
            test_drawn_appends_the_reply_when_nothing_streamed
        ; test_case "drawn ends a blank visible reply with a status row" `Quick
            test_drawn_ends_a_blank_visible_reply_with_a_status_row
        ; test_case "drawn ends each control outcome with its status row" `Quick
            test_drawn_ends_each_control_outcome_with_its_status_row
        ; test_case "of_log equals the incremental fold" `Quick
            test_of_log_equals_the_incremental_fold
        ] )
    ; ( "trail"
      , [ test_case "arrival order is kept" `Quick
            test_trail_keeps_arrival_order
        ; test_case "one empty line per paragraph break" `Quick
            test_trail_keeps_one_empty_line_per_paragraph_break
        ; test_case "consecutive calls are one block" `Quick
            test_trail_groups_consecutive_calls_into_one_block
        ; test_case "a call updates after later stretches open" `Quick
            test_trail_updates_a_call_after_later_stretches_open
        ; test_case "blank stretches are dropped" `Quick
            test_trail_drops_blank_stretches
        ; test_case "live Skill is separate from generic tools" `Quick
            test_live_skill_is_not_folded_into_generic_tools
        ; test_case "terminal Skill is not still calling" `Quick
            test_terminal_skill_is_not_still_calling
        ; test_case "consecutive live Skill calls are one counted block" `Quick
            test_consecutive_live_skill_calls_are_one_counted_block
        ; test_case "a failed trigger is named on the compact row" `Quick
            test_a_failed_trigger_is_named_on_the_compact_row
        ;] )
    ; ( "tool calls"
      , [ test_case "named as the other surfaces name it" `Quick
            test_tool_call_is_named_the_way_the_other_surfaces_name_it
        ; test_case "kept in stream order" `Quick test_calls_keep_stream_order
        ; test_case "reused provider id keeps distinct live occurrences" `Quick
            test_reused_provider_id_keeps_distinct_live_occurrences
        ; test_case "canonical result identity is write-once" `Quick
            test_tool_result_identity_is_write_once
        ; test_case "same-turn duplicate provider id is never guessed" `Quick
            test_same_turn_duplicate_provider_id_uses_server_occurrence
        ; test_case "protocol error uses exact quarantined occurrence" `Quick
            test_protocol_error_fails_only_the_quarantined_occurrence
        ; test_case "quarantine freezes late args and result" `Quick
            test_quarantine_freezes_late_args_and_result
        ; test_case "a snapshot replaces the fragments" `Quick
            test_snapshot_replaces_accumulated_args
        ; test_case "a fragment with no open call is dropped" `Quick
            test_fragment_for_an_unopened_call_is_dropped
        ; test_case "compact and full keep the same typed facts" `Quick
            test_compact_and_full_keep_the_same_typed_facts
        ; test_case "a fold reports the outcome its marker stands for" `Quick
            test_a_fold_reports_the_outcome_its_marker_stands_for
        ;] )
    ; ( "terminal safety"
      , [ test_case "control bytes never reach the pane" `Quick
            test_control_bytes_never_reach_the_pane
        ] )
    ; ( "held calls"
      , [ test_case "a held call shows its question" `Quick
            test_a_held_call_shows_its_question; test_case "an answer clears the prompt" `Quick
            test_an_answer_clears_the_prompt
        ; test_case "a timeout clears the prompt too" `Quick
            test_a_timeout_clears_the_prompt_too
        ; test_case "a denial uses decision vocabulary" `Quick
            test_a_denial_uses_decision_vocabulary
        ; test_case "a settle for another call leaves the prompt" `Quick
            test_a_late_settle_for_another_call_leaves_the_prompt
        ;] )
    ; ( "status rows"
      , [ test_case "rows grow only with what they report" `Quick
            test_status_rows_grow_only_with_what_they_report
        ;] )
    ; ( "phase"
      , [ test_case "failure and finish are distinct" `Quick
            test_run_failure_and_finish_set_the_phase
        ; test_case "failure after recorded reply preserves both" `Quick
            test_failure_after_recorded_reply_preserves_both
        ; test_case "terminal turns settle only unresolved tool projections" `Quick
            test_terminal_turn_marks_only_unresolved_tools
        ; test_case "superseded tools keep attempt identity" `Quick
            test_superseded_calls_keep_attempt_identity
        ; test_case "a finished run stays finished" `Quick
            test_a_finished_run_does_not_go_back_to_working
        ; test_case "an interrupt signal is not an outcome" `Quick
            test_interrupt_is_recorded_as_a_signal_not_an_outcome
        ; test_case "unreadable lines are counted" `Quick
            test_unreadable_lines_are_counted_with_their_last_reason
        ; test_case "runtime failover visibility and error attribution" `Quick
            test_runtime_failover_visibility_and_error_attribution
        ; test_case "a narrow row keeps the counters it was drawing" `Quick
            test_a_narrow_row_keeps_the_counters_it_was_drawing
        ; test_case "the turn reports the tokens it has spent" `Quick
            test_the_turn_reports_the_tokens_it_has_spent
        ; test_case "new attempt does not inherit previous runtime" `Quick
            test_new_attempt_does_not_inherit_previous_runtime
        ; test_case "drawn items carry superseded runtime id" `Quick
            test_drawn_items_carry_superseded_runtime_id
        ; test_case "a repeated note leaves the revision alone" `Quick
            test_a_repeated_note_leaves_the_revision_alone
        ; test_case "drawn follows every mutation of the transcript" `Quick
            test_drawn_follows_every_mutation_of_the_transcript
        ] )
    ]
