open Alcotest

module Live = Masc_tui_keeper_chat_live
module Transcript = Masc_tui_keeper_chat_transcript

let fresh () = Transcript.create ~keeper_name:"keeper.one" ~request_id:"req-1"

let feed t deltas = List.iter (Transcript.apply t) deltas

let phase_to_string : Transcript.phase -> string = function
  | Transcript.Waiting -> "waiting"
  | Transcript.Working -> "working"
  | Transcript.Stream_ended -> "stream_ended"
  | Transcript.Stream_failed message -> "stream_failed(" ^ message ^ ")"

let phase = testable (Fmt.of_to_string phase_to_string) ( = )

let call_to_string (call : Transcript.tool_call) =
  Printf.sprintf "%s|%s|%s|%b|%b" call.tool_name call.args
    (Option.value ~default:"-" call.subject)
    call.ended call.result_ready

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
        { Transcript.call_id = "c1"
        ; tool_name = "read_file"
        ; args = "{\"file_path\":\"lib/keeper/a.ml\"}"
        ; subject = Some "lib/keeper/a.ml"
        ; ended = true
        ; result_ready = true
        }
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
    (Transcript.tool_calls t |> List.map (fun c -> c.Transcript.tool_name))

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
    (List.exists (fun (_, text) -> has_escape text) (Transcript.status_rows t))

let kind_to_string : Transcript.status_kind -> string = function
  | Transcript.Progress -> "progress"
  | Transcript.Attention -> "attention"

let test_status_rows_grow_only_with_what_they_report () =
  let t = fresh () in
  check (list string) "a turn in flight reports how it is going and nothing else"
    [ "progress" ]
    (Transcript.status_rows t |> List.map (fun (kind, _) -> kind_to_string kind));
  Transcript.note_interrupt t (Transcript.Signal_sent { turn_id = None });
  check int "an interrupt adds one row" 2
    (List.length (Transcript.status_rows t));
  Transcript.apply t (Live.Undecodable "invalid JSON: x");
  check int "an unreadable line adds one more" 3
    (List.length (Transcript.status_rows t))

let test_progress_row_reports_a_context_checkpoint () =
  let t = fresh () in
  feed t [ Live.Run_started; Live.Checkpoint ];
  match Transcript.status_rows t with
  | (Transcript.Progress, text) :: _ ->
      (* A turn that carried on past a context limit looks the same as a stall
         from the outside, so the row has to distinguish them. *)
      check bool "carrying on past a checkpoint is reported" true
        (contains ~needle:"checkpoint" text)
  | rows -> failf "expected a progress row, got %d rows" (List.length rows)

let test_progress_row_counts_the_tool_calls () =
  let t = fresh () in
  feed t [ Live.Run_started ];
  (match Transcript.status_rows t with
   | (Transcript.Progress, text) :: _ ->
       check string "a turn with no calls just says it is working" "working" text
   | rows -> failf "expected a progress row, got %d rows" (List.length rows));
  feed t read_file_call;
  match Transcript.status_rows t with
  | (Transcript.Progress, text) :: _ ->
      check bool "once it calls tools the row counts them" true
        (contains ~needle:"1 tool call" text)
  | rows -> failf "expected a progress row, got %d rows" (List.length rows)

let test_interrupt_row_does_not_claim_the_turn_stopped () =
  let t = fresh () in
  Transcript.note_interrupt t (Transcript.Signal_sent { turn_id = Some 12 });
  match
    Transcript.status_rows t
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
    Transcript.status_rows t
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

let () =
  run "tui_keeper_chat_transcript"
    [ ( "content"
      , [ test_case "text and reasoning accumulate separately" `Quick
            test_text_and_thinking_accumulate
        ] )
    ; ( "tool calls"
      , [ test_case "named as the other surfaces name it" `Quick
            test_tool_call_is_named_the_way_the_other_surfaces_name_it
        ; test_case "kept in stream order" `Quick test_calls_keep_stream_order
        ; test_case "a snapshot replaces the fragments" `Quick
            test_snapshot_replaces_accumulated_args
        ; test_case "a fragment with no open call is dropped" `Quick
            test_fragment_for_an_unopened_call_is_dropped
        ] )
    ; ( "terminal safety"
      , [ test_case "control bytes never reach the pane" `Quick
            test_control_bytes_never_reach_the_pane
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
