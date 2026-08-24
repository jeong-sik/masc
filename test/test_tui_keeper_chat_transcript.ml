open Alcotest

module Live = Masc_tui_keeper_chat_live
module Transcript = Masc_tui_keeper_chat_transcript

(* A stated instant rather than the wall clock: the progress row carries the
   turn age, and a test that read the real clock could not name it. *)
let origin = 1_000_000.

let fresh () =
  Transcript.create ~keeper_name:"keeper.one" ~request_id:"req-1"
    ~started_at:origin

let rows ?(now = origin) t = Transcript.status_rows ~now t

let feed t deltas = List.iter (Transcript.apply t) deltas

let phase_to_string : Transcript.phase -> string = function
  | Transcript.Waiting -> "waiting"
  | Transcript.Working -> "working"
  | Transcript.Stream_ended -> "stream_ended"
  | Transcript.Stream_failed message -> "stream_failed(" ^ message ^ ")"

let phase = testable (Fmt.of_to_string phase_to_string) ( = )

let outcome_to_string : Transcript.tool_outcome -> string = function
  | Transcript.Started -> "started"
  | Transcript.Awaiting_result -> "awaiting_result"
  | Transcript.Returned -> "returned"
  | Transcript.Failed -> "failed"
  | Transcript.Never_returned -> "never_returned"
  | Transcript.Outcome_unrecorded -> "outcome_unrecorded"

let call_to_string (call : Transcript.tool_activity) =
  Printf.sprintf "%s|%s|%s|%s|%s|%s"
    (Option.value ~default:"-" call.call_id)
    call.tool_name call.args (Option.value ~default:"-" call.subject)
    (outcome_to_string call.outcome)
    (Option.value ~default:"-" call.duration)

let tool_call = testable (Fmt.of_to_string call_to_string) ( = )

let read_file_call =
  [ Live.Tool_started { call_id = "c1"; tool_name = "read_file" }
  ; Live.Tool_args
      { call_id = "c1"
      ; fragment = Live.Args_delta "{\"file_path\":\"lib/keeper/a.ml\"}"
      }
  ; Live.Tool_ended { call_id = "c1" }
  ; Live.Tool_result { call_id = "c1" }
  ]

let test_text_and_thinking_accumulate () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Text "Let me "
    ; Live.Thinking "checking "
    ; Live.Text "look."
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
        (Transcript.make_tool_activity ~call_id:(Some "c1")
           ~tool_name:"read_file"
           ~args:"{\"file_path\":\"lib/keeper/a.ml\"}"
           ~outcome:Transcript.Returned ~duration:None)
        call
  | other -> failf "expected one call, got %d" (List.length other)

let test_calls_keep_stream_order () =
  let t = fresh () in
  feed t
    [ Live.Tool_started { call_id = "c1"; tool_name = "read_file" }
    ; Live.Tool_started { call_id = "c2"; tool_name = "edit_file" }
    ; Live.Tool_started { call_id = "c3"; tool_name = "shell_light" }
    ];
  check (list string) "rows read in the order the turn opened them"
    [ "read_file"; "edit_file"; "shell_light" ]
    (Transcript.tool_calls t
     |> List.map (fun (c : Transcript.tool_activity) -> c.Transcript.tool_name))

let test_snapshot_replaces_accumulated_args () =
  let t = fresh () in
  feed t
    [ Live.Tool_started { call_id = "c1"; tool_name = "read_file" }
    ; Live.Tool_args { call_id = "c1"; fragment = Live.Args_delta "{\"file_" }
    ; Live.Tool_args
        { call_id = "c1"
        ; fragment = Live.Args_snapshot "{\"file_path\":\"b.ml\"}"
        }
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
    [ Live.Tool_args
        { call_id = "never-opened"; fragment = Live.Args_delta "{\"a\":1}" }
    ; Live.Tool_ended { call_id = "never-opened" }
    ];
  check int "no nameless row is opened for it" 0
    (List.length (Transcript.tool_calls t))

let test_run_failure_and_finish_set_the_phase () =
  let failed = fresh () in
  feed failed [ Live.Run_started; Live.Run_failed { message = "provider 429" } ];
  check phase "a failed run says so"
    (Transcript.Stream_failed "provider 429")
    (Transcript.phase failed);
  let finished = fresh () in
  feed finished [ Live.Run_started; Live.Run_finished ];
  check phase "a finished run says so" Transcript.Stream_ended
    (Transcript.phase finished)

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
  Transcript.note_interrupt t (Transcript.Signal_sent { turn_id = Some 7 });
  check bool "the signal is recorded" true
    (Transcript.interrupt t = Transcript.Signal_sent { turn_id = Some 7 });
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
    [ Live.Text "before\x1b"
    ; Live.Text "[2Jafter"
    ; Live.Thinking "\x1b[31mred"
    ; Live.Tool_started { call_id = "c1"; tool_name = "read_file" }
    ; Live.Tool_args
        { call_id = "c1"
        ; fragment = Live.Args_delta "{\"file_path\":\"a\x1b[2Jb.ml\"}"
        }
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

let test_progress_row_carries_the_turn_age () =
  let t = fresh () in
  (* Aged before RUN_STARTED too: a request that never reaches the run is the
     shape that hid a 63-minute hang (masc #29229). *)
  (match rows ~now:(origin +. 12.) t with
   | (Transcript.Progress, text) :: _ ->
       check bool "a turn that has not started yet still reports its age" true
         (contains ~needle:"12s" text)
   | got -> failf "expected a progress row, got %d rows" (List.length got));
  feed t [ Live.Run_started ];
  (match rows ~now:(origin +. 90.) t with
   | (Transcript.Progress, text) :: _ ->
       check bool "past a minute the age reads as minutes and seconds" true
         (contains ~needle:"1m30s" text)
   | got -> failf "expected a progress row, got %d rows" (List.length got));
  (* A clock that moved backwards says nothing rather than a negative age. *)
  match rows ~now:(origin -. 5.) t with
  | (Transcript.Progress, text) :: _ ->
      check string "a backwards clock drops the age" "working" text
  | got -> failf "expected a progress row, got %d rows" (List.length got)

(* The prompt. It is the one row an operator has to act on, so what matters is
   that it appears, that it says how to answer, and that it goes away on every
   path -- a prompt left up asks again for a call already decided. *)

let approval_rows t =
  rows t
  |> List.filter_map (fun (kind, text) ->
         if kind = Transcript.Attention then Some text else None)

let requested ~call_id ~tool_name ~question =
  Live.Approval_requested { call_id; tool_name; args = ""; question }

let test_a_held_call_shows_its_question () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Tool_started { call_id = "c1"; tool_name = "Edit" }
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
        (contains ~needle:"[y]" row && contains ~needle:"[n]" row)
  | rows -> failf "expected one prompt row, got %d" (List.length rows)

let test_a_held_turn_does_not_say_it_is_working () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; requested ~call_id:"c1" ~tool_name:"Edit" ~question:"Run Edit?"
    ];
  match rows t with
  | (Transcript.Progress, text) :: _ ->
      (* "working" would read as a slow tool rather than a question waiting on
         screen for someone. *)
      check bool "it says it is waiting on a person" true
        (contains ~needle:"waiting for your answer" text)
  | rows -> failf "expected a progress row, got %d rows" (List.length rows)

let test_an_answer_clears_the_prompt () =
  let t = fresh () in
  feed t
    [ requested ~call_id:"c1" ~tool_name:"Edit" ~question:"Run Edit?"
    ; Live.Approval_settled { call_id = "c1"; outcome = "approve" }
    ];
  check bool "nothing is held any more" true
    (Option.is_none (Transcript.awaiting_approval t));
  check (list string) "and no prompt is drawn" [] (approval_rows t)

let test_a_timeout_clears_the_prompt_too () =
  let t = fresh () in
  feed t
    [ requested ~call_id:"c1" ~tool_name:"Edit" ~question:"Run Edit?"
    ; Live.Approval_settled { call_id = "c1"; outcome = "timed_out" }
    ];
  (* The decision is over even though nobody made one. Leaving the prompt up
     would ask again for a call that has already been denied. *)
  check bool "the prompt is gone" true
    (Option.is_none (Transcript.awaiting_approval t))

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

let test_the_arguments_reach_the_call_row () =
  let t = fresh () in
  feed t
    [ Live.Tool_started { call_id = "c1"; tool_name = "Edit" }
    ; Live.Approval_requested
        { call_id = "c1"
        ; tool_name = "Edit"
        ; args = "{\"file_path\":\"lib/a.ml\"}"
        ; question = "Run Edit on lib/a.ml?"
        }
    ];
  (* A reader deciding whether to allow it needs to see what it would touch,
     and the call's own row is where the pane already shows that. *)
  check bool "the row names the file" true
    (List.exists (contains ~needle:"lib/a.ml") (Transcript.tool_rows t))

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
  | Transcript.Attention -> "attention"

let test_status_rows_grow_only_with_what_they_report () =
  let t = fresh () in
  check (list string) "a turn in flight reports how it is going and nothing else"
    [ "progress" ]
    (rows t |> List.map (fun (kind, _) -> kind_to_string kind));
  Transcript.note_interrupt t (Transcript.Signal_sent { turn_id = None });
  check int "an interrupt adds one row" 2
    (List.length (rows t));
  Transcript.apply t (Live.Undecodable "invalid JSON: x");
  check int "an unreadable line adds one more" 3
    (List.length (rows t))

let test_progress_row_reports_a_context_checkpoint () =
  let t = fresh () in
  feed t [ Live.Run_started; Live.Checkpoint ];
  match rows t with
  | (Transcript.Progress, text) :: _ ->
      (* A turn that carried on past a context limit looks the same as a stall
         from the outside, so the row has to distinguish them. *)
      check bool "carrying on past a checkpoint is reported" true
        (contains ~needle:"checkpoint" text)
  | rows -> failf "expected a progress row, got %d rows" (List.length rows)

let test_progress_row_counts_the_tool_calls () =
  let t = fresh () in
  feed t [ Live.Run_started ];
  (match rows t with
   | (Transcript.Progress, text) :: _ ->
       (* Its own concern only. The row also carries the turn age, and
          matching the whole string here would tie tool-call counting to
          the age format. *)
       check bool "a turn with no calls does not mention them" false
         (contains ~needle:"tool call" text)
   | rows -> failf "expected a progress row, got %d rows" (List.length rows));
  feed t read_file_call;
  match rows t with
  | (Transcript.Progress, text) :: _ ->
      check bool "once it calls tools the row counts them" true
        (contains ~needle:"1 tool call" text)
  | rows -> failf "expected a progress row, got %d rows" (List.length rows)

let test_interrupt_row_does_not_claim_the_turn_stopped () =
  let t = fresh () in
  Transcript.note_interrupt t (Transcript.Signal_sent { turn_id = Some 12 });
  match
    rows t
    |> List.filter (fun (kind, _) -> kind = Transcript.Attention)
  with
  | [ (_, text) ] ->
      check bool "the row says the signal went out" true
        (contains ~needle:"signalled" text);
      (* The server reports that it signalled the turn switch, not that the
         turn ended: a turn parked in an uncancellable section keeps running.
         Wording this as "stopped" is what hid a 63-minute hang. *)
      check bool "and that the turn is still streaming" true
        (contains ~needle:"still streaming" text);
      check bool "it names the turn it signalled" true
        (contains ~needle:"12" text)
  | rows -> failf "expected one attention row, got %d" (List.length rows)

let test_a_declined_interrupt_carries_the_reason () =
  let t = fresh () in
  Transcript.note_interrupt t
    (Transcript.Signal_declined "no_in_flight_turn");
  match
    rows t
    |> List.filter (fun (kind, _) -> kind = Transcript.Attention)
  with
  | [ (_, text) ] ->
      check bool "the reason reaches the row" true
        (contains ~needle:"no_in_flight_turn" text)
  | rows -> failf "expected one attention row, got %d" (List.length rows)

let test_tool_rows_mark_how_far_each_call_got () =
  let t = fresh () in
  feed t
    [ Live.Tool_started { call_id = "c1"; tool_name = "read_file" }
    ; Live.Tool_args
        { call_id = "c1"; fragment = Live.Args_delta "{\"file_path\":\"a.ml\"}" }
    ; Live.Tool_started { call_id = "c2"; tool_name = "edit_file" }
    ; Live.Tool_ended { call_id = "c2" }
    ; Live.Tool_started { call_id = "c3"; tool_name = "glob" }
    ; Live.Tool_ended { call_id = "c3" }
    ; Live.Tool_result { call_id = "c3" }
    ];
  match Transcript.tool_rows t with
  | [ open_call; running; done_call ] ->
      check bool "a call still taking arguments is marked as open" true
        (contains ~needle:"·" open_call);
      check bool "a closed call with no result yet is marked as running" true
        (contains ~needle:"▶" running);
      check bool "a call whose result landed is marked as done" true
        (contains ~needle:"✓" done_call);
      check bool "the open call is named by its file" true
        (contains ~needle:"a.ml" open_call)
  | rows -> failf "expected three rows, got %d" (List.length rows)

let test_compact_and_full_keep_the_same_typed_facts () =
  let activities =
    [ Transcript.make_tool_activity ~call_id:(Some "c1")
        ~tool_name:"read_file" ~args:"{\"file_path\":\"a.ml\"}"
        ~outcome:Transcript.Returned ~duration:(Some "12ms")
    ; Transcript.make_tool_activity ~call_id:(Some "c2")
        ~tool_name:"edit_file" ~args:"{\"file_path\":\"b.ml\"}"
        ~outcome:Transcript.Failed ~duration:(Some "18ms")
    ; Transcript.make_tool_activity ~call_id:None ~tool_name:"glob" ~args:""
        ~outcome:Transcript.Outcome_unrecorded ~duration:None
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
    full.rows;
  check int "full has three details plus the transcript omission" 4
    (List.length full.rows);
  check int "full hides no detail row" 0 full.hidden_activity_rows;
  check int "compact keeps its summary and the transcript omission" 2
    (List.length compact.rows);
  check int "compact states exactly how many rows it hid" 3
    compact.hidden_activity_rows;
  let summary = List.hd compact.rows in
  check bool "the compact row does not hide the failure" true
    (contains ~needle:"1 failed" summary);
  check bool "the compact row carries the exact hidden count" true
    (contains ~needle:"3 detail rows hidden" summary);
  check string "compact does not count the visible omission as hidden"
    (List.nth full.rows 3) (List.nth compact.rows 1)

let full_tool_rows block =
  (Transcript.project_tool_block Transcript.Full block).Transcript.rows

(* The shape a reader follows a long turn by: thinking, then the call, then
   more thinking, then the reply — not three pooled blocks. This is the order
   the live pane draws. *)
let trail_item_to_string : Transcript.trail_item -> string = function
  | Transcript.Trail_thinking lines ->
      "thinking(" ^ String.concat "\\n" lines ^ ")"
  | Transcript.Trail_tools block ->
      "tools(" ^ String.concat "\\n" (full_tool_rows block) ^ ")"
  | Transcript.Trail_text text -> "text(" ^ text ^ ")"

let trail_item = testable (Fmt.of_to_string trail_item_to_string) ( = )

let test_trail_keeps_arrival_order () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Thinking "find the file first"
    ; Live.Tool_started { call_id = "c1"; tool_name = "read_file" }
    ; Live.Tool_args
        { call_id = "c1"
        ; fragment = Live.Args_delta "{\"file_path\":\"lib/keeper/a.ml\"}"
        }
    ; Live.Tool_ended { call_id = "c1" }
    ; Live.Tool_result { call_id = "c1" }
    ; Live.Thinking "now the caller"
    ; Live.Text "The caller is safe."
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

let test_trail_groups_consecutive_calls_into_one_block () =
  let t = fresh () in
  feed t
    [ Live.Run_started
    ; Live.Tool_started { call_id = "c1"; tool_name = "read_file" }
    ; Live.Tool_started { call_id = "c2"; tool_name = "execute" }
    ; Live.Text "done"
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
    ; Live.Tool_started { call_id = "c1"; tool_name = "read_file" }
    ; Live.Thinking "while it runs"
    ; Live.Tool_args
        { call_id = "c1"
        ; fragment = Live.Args_snapshot "{\"file_path\":\"lib/keeper/a.ml\"}"
        }
    ; Live.Tool_result { call_id = "c1" }
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
  feed t [ Live.Run_started; Live.Thinking "\n\n"; Live.Text "  " ];
  check (list trail_item) "blank stretches draw nothing" []
    (Transcript.trail t)

let () =
  run "tui_keeper_chat_transcript"
    [ ( "content"
      , [ test_case "text and reasoning accumulate separately" `Quick
            test_text_and_thinking_accumulate
        ; test_case "the whole reasoning trail is kept" `Quick
            test_the_whole_reasoning_trail_is_kept
        ] )
    ; ( "trail"
      , [ test_case "arrival order is kept" `Quick
            test_trail_keeps_arrival_order
        ; test_case "consecutive calls are one block" `Quick
            test_trail_groups_consecutive_calls_into_one_block
        ; test_case "a call updates after later stretches open" `Quick
            test_trail_updates_a_call_after_later_stretches_open
        ; test_case "blank stretches are dropped" `Quick
            test_trail_drops_blank_stretches
        ] )
    ; ( "tool calls"
      , [ test_case "named as the other surfaces name it" `Quick
            test_tool_call_is_named_the_way_the_other_surfaces_name_it
        ; test_case "kept in stream order" `Quick test_calls_keep_stream_order
        ; test_case "a snapshot replaces the fragments" `Quick
            test_snapshot_replaces_accumulated_args
        ; test_case "a fragment with no open call is dropped" `Quick
            test_fragment_for_an_unopened_call_is_dropped
        ; test_case "compact and full keep the same typed facts" `Quick
            test_compact_and_full_keep_the_same_typed_facts
        ] )
    ; ( "terminal safety"
      , [ test_case "control bytes never reach the pane" `Quick
            test_control_bytes_never_reach_the_pane
        ] )
    ; ( "held calls"
      , [ test_case "a held call shows its question" `Quick
            test_a_held_call_shows_its_question
        ; test_case "a held turn does not say it is working" `Quick
            test_a_held_turn_does_not_say_it_is_working
        ; test_case "an answer clears the prompt" `Quick
            test_an_answer_clears_the_prompt
        ; test_case "a timeout clears the prompt too" `Quick
            test_a_timeout_clears_the_prompt_too
        ; test_case "a settle for another call leaves the prompt" `Quick
            test_a_late_settle_for_another_call_leaves_the_prompt
        ; test_case "the arguments reach the call row" `Quick
            test_the_arguments_reach_the_call_row
        ] )
    ; ( "status rows"
      , [ test_case "rows grow only with what they report" `Quick
            test_status_rows_grow_only_with_what_they_report
        ; test_case "the progress row counts tool calls" `Quick
            test_progress_row_counts_the_tool_calls
        ; test_case "the progress row reports a context checkpoint" `Quick
            test_progress_row_reports_a_context_checkpoint
        ; test_case "an interrupt row does not claim the turn stopped" `Quick
            test_interrupt_row_does_not_claim_the_turn_stopped
        ; test_case "a declined interrupt carries its reason" `Quick
            test_a_declined_interrupt_carries_the_reason
        ; test_case "tool rows mark how far each call got" `Quick
            test_tool_rows_mark_how_far_each_call_got
        ; test_case "the progress row carries the turn age" `Quick
            test_progress_row_carries_the_turn_age
        ] )
    ; ( "phase"
      , [ test_case "failure and finish are distinct" `Quick
            test_run_failure_and_finish_set_the_phase
        ; test_case "a finished run stays finished" `Quick
            test_a_finished_run_does_not_go_back_to_working
        ; test_case "an interrupt signal is not an outcome" `Quick
            test_interrupt_is_recorded_as_a_signal_not_an_outcome
        ; test_case "unreadable lines are counted" `Quick
            test_unreadable_lines_are_counted_with_their_last_reason
        ] )
    ]
