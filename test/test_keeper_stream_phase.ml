(* Table tests for the stream phase rules that the SSE bridge and the tool
   accumulator share. Every stop reason constructor is listed, so the replay
   comparison runs on each of them, and [Unknown] carries two distinct values. *)

open Alcotest

module P = Masc.Keeper_stream_phase
module T = Agent_core.Types

let stop_reason_name : T.stop_reason -> string = function
  | T.EndTurn -> "EndTurn"
  | T.StopToolUse -> "StopToolUse"
  | T.MaxTokens -> "MaxTokens"
  | T.StopSequence -> "StopSequence"
  | T.Refusal -> "Refusal"
  | T.ContentFilter -> "ContentFilter"
  | T.RepetitionTruncation -> "RepetitionTruncation"
  | T.PauseTurn -> "PauseTurn"
  | T.Compaction -> "Compaction"
  | T.ContextWindowExceeded -> "ContextWindowExceeded"
  | T.UnmatchedToolCalls -> "UnmatchedToolCalls"
  | T.Unknown raw -> Printf.sprintf "Unknown %S" raw
;;

(* All values differ, so the position in this list tells whether two of them
   are the same stop reason. *)
let stop_reasons : T.stop_reason list =
  [ T.EndTurn
  ; T.StopToolUse
  ; T.MaxTokens
  ; T.StopSequence
  ; T.Refusal
  ; T.ContentFilter
  ; T.RepetitionTruncation
  ; T.PauseTurn
  ; T.Compaction
  ; T.ContextWindowExceeded
  ; T.UnmatchedToolCalls
  ; T.Unknown "a"
  ; T.Unknown "b"
  ]
;;

let phase_name = function
  | P.Accepting_content -> "Accepting_content"
  | P.Stop_reason_seen reason -> "Stop_reason_seen " ^ stop_reason_name reason
  | P.Message_stopped -> "Message_stopped"
;;

let phases =
  (P.Accepting_content :: List.map (fun reason -> P.Stop_reason_seen reason) stop_reasons)
  @ [ P.Message_stopped ]
;;

let stop_reason_event_name = function
  | P.Stop_reason_unchanged -> "Stop_reason_unchanged"
  | P.Stop_reason_first reason -> "Stop_reason_first " ^ stop_reason_name reason
  | P.Stop_reason_conflict -> "Stop_reason_conflict"
;;

let message_stop_event_name = function
  | P.Message_stop_replayed -> "Message_stop_replayed"
  | P.Message_stop_without_reason -> "Message_stop_without_reason"
  | P.Message_stop_after_reason -> "Message_stop_after_reason"
;;

(* The event types have no printer, so a testable prints them by name. *)
let named name_of =
  testable (fun ppf value -> Format.pp_print_string ppf (name_of value)) ( = )
;;

let stop_reason_event = named stop_reason_event_name
let message_stop_event = named message_stop_event_name

let test_content_admission () =
  List.iter
    (fun phase ->
       let name = phase_name phase in
       check
         bool
         (name ^ ": block start and delta")
         (phase = P.Accepting_content)
         (P.admits_block_open_or_delta phase);
       check
         bool
         (name ^ ": block stop")
         (phase <> P.Message_stopped)
         (P.admits_block_stop phase))
    phases
;;

let test_stop_reason () =
  let expect phase input expected =
    let input_name =
      match input with
      | None -> "no stop reason"
      | Some reason -> stop_reason_name reason
    in
    check
      stop_reason_event
      (Printf.sprintf "%s with %s" (phase_name phase) input_name)
      expected
      (P.on_stop_reason phase input)
  in
  (* The first stop reason is recorded. *)
  expect P.Accepting_content None P.Stop_reason_unchanged;
  List.iter
    (fun reason -> expect P.Accepting_content (Some reason) (P.Stop_reason_first reason))
    stop_reasons;
  (* Once recorded, a delta without a reason or with the same reason changes
     nothing, and a different reason conflicts. *)
  List.iteri
    (fun recorded_at recorded ->
       expect (P.Stop_reason_seen recorded) None P.Stop_reason_unchanged;
       List.iteri
         (fun incoming_at incoming ->
            expect
              (P.Stop_reason_seen recorded)
              (Some incoming)
              (if recorded_at = incoming_at
               then P.Stop_reason_unchanged
               else P.Stop_reason_conflict))
         stop_reasons)
    stop_reasons;
  (* After the message stopped, every delta conflicts. *)
  expect P.Message_stopped None P.Stop_reason_conflict;
  List.iter
    (fun reason -> expect P.Message_stopped (Some reason) P.Stop_reason_conflict)
    stop_reasons
;;

let test_message_stop () =
  let expect phase expected =
    check message_stop_event (phase_name phase) expected (P.on_message_stop phase)
  in
  expect P.Accepting_content P.Message_stop_without_reason;
  List.iter
    (fun reason -> expect (P.Stop_reason_seen reason) P.Message_stop_after_reason)
    stop_reasons;
  expect P.Message_stopped P.Message_stop_replayed
;;

let () =
  run
    "keeper_stream_phase"
    [ ( "phase rules"
      , [ test_case "content admission by phase" `Quick test_content_admission
        ; test_case "stop reason: first, replay, conflict" `Quick test_stop_reason
        ; test_case
            "message stop: without reason, after reason, replay"
            `Quick
            test_message_stop
        ] )
    ]
;;
