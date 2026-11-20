(* The text of a reading question (RFC librarian-call-only-proposes §6.1).
   The same inputs give the same bytes, with the two halves on the line after
   the prompt and on the last line. A change to Memory alone moves the front
   half and leaves the back half. A range whose items are all missing makes
   no question and keeps what is missing for the commit line. *)

open Alcotest
module Question = Masc.Librarian_question
module Question_id = Masc.Librarian_question_id
module Read_result = Masc.Librarian_read_result
module Read_unit = Masc.Librarian_read_unit
module Missing = Masc.Librarian_unit
module Log = Masc.Librarian_log
module Lane = Masc.Librarian_memory_lane
module Current = Masc.Keeper_memory_os_current_types
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Digest = Agent_core.Checkpoint_objects
module Agent = Agent_core.Types

let lane : Lane.question_side =
  { prompt = "Read the units and answer with one JSON document."
  ; answer_schema = `Assoc [ "type", `String "object" ]
  ; max_output_tokens = 4096
  ; thinking = Some false
  }
;;

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let mark closed_messages : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages
  ; session = "session-1"
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let from : Log.line =
  Log.Committed
    { seq = 1
    ; at = 1_763_500_000.0
    ; basis = Digest.digest_of_bytes "before"
    ; after = Digest.digest_of_bytes "after"
    ; revision = 2
    ; cause = Log.Adopt { by = "operator"; observed = Digest.digest_of_bytes "after" }
    ; effects = Masc.Librarian_effects.empty
    ; turn_log
    ; turn_log_offset = 0
    ; covers_through = Log.Before_first
    ; covered = mark 0
    ; working_state = Some "triage the release blockers"
    }
;;

let reach : Read_result.reach =
  { line = 300; within = Log.Whole; covered = mark 3; turn_log_offset = 360 }
;;

let authored : Types.origin = { kind = Types.Authored; trace_id = "trace-1" }

let observed claim =
  Types.observed ~claim ~category:Types.Constraint ~now:1_763_510_400.0 ~origin:authored
;;

let memory facts : Current.t =
  { revision = 2
  ; updated_at = 1_763_510_400.0
  ; source = { kind = Current.Librarian; trace_id = "trace-1" }
  ; facts
  ; change = { added = []; removed = []; retained = 0; invalidated = [] }
  }
;;

(* Built again at each call, so equal bytes come from equal values. *)
let facts () =
  let frozen = observed "the release branch is frozen on Fridays" in
  match
    Types.derived
      ~claim:"no deploy goes out on a Friday"
      ~category:Types.Lesson
      ~now:1_763_510_400.0
      ~origin:authored
      ~derivations:[ { rule_id = "rule"; premise_ids = [ Types.memory_id frozen ] } ]
  with
  | Ok derived -> [ frozen; derived ]
  | Error detail -> fail detail
;;

let opened : Read_unit.opened = { runtime = "glm"; task = Turn_log.No_task; stimuli = [] }

let units () : Read_unit.t list =
  [ { line = 120
    ; at = 1_763_600_000.0
    ; kind =
        Read_unit.Turn
          { turn = 40
          ; outcome = Turn_log.Completed
          ; opened
          ; unattributed = []
          ; own =
              [ { index = 0
                ; name = { store = Agent_core; at = 0 }
                ; body = Read_unit.Message (Agent.user_msg "ship the fix before Friday")
                }
              ; { index = 1
                ; name = { store = Agent_core; at = 1 }
                ; body =
                    Read_unit.Message
                      (Agent.make_message
                         ~role:Agent.Assistant
                         [ Agent.ToolUse { id = "call-1"; name = "board_read"; input = `Null } ])
                }
              ; { index = 2
                ; name = { store = Agent_core; at = 2 }
                ; body =
                    Read_unit.Message
                      (Agent.tool_result_msg ~tool_use_id:"call-1" ~content:"two posts" ())
                }
              ]
          }
    ; missing = []
    }
  ; { line = 300
    ; at = 1_763_600_060.0
    ; kind = Read_unit.Reset { cause = Turn_log.Cleared; items = [] }
    ; missing = []
    }
  ]
;;

let ask held units =
  match
    Question.make ~lane ~memory:(memory held) ~from ~reach ~trace:"trace-1"
      ~offered:{ units = 1; head_items = 3 } units
  with
  | Question.Made { question; text } -> question, text
  | Question.Nothing_readable _ -> fail "a range with items made no question"
;;

let same_inputs_same_bytes () =
  let question, text = ask (facts ()) (units ()) in
  let again, text_again = ask (facts ()) (units ()) in
  check string "the text" text text_again;
  check bool "the id" true (Question_id.equal question.id again.id);
  let lines = String.split_on_char '\n' text in
  check string "the line after the prompt" ("question: " ^ question.id.front) (List.nth lines 1);
  check
    string
    "the last line"
    ("question-end: " ^ question.id.back)
    (List.nth lines (List.length lines - 2))
;;

let memory_alone_moves_the_front_half () =
  let question, text = ask (facts ()) (units ()) in
  let revised, revised_text =
    ask [ observed "the release branch is frozen on Fridays and Saturdays" ] (units ())
  in
  check bool "the text changed" false (String.equal text revised_text);
  check bool "the front half changed" false (String.equal question.id.front revised.id.front);
  check string "the back half" question.id.back revised.id.back
;;

let all_missing_asks_nothing () =
  let slice : Turn_log.slice = { bundle = Digest.digest_of_bytes "bundle"; skip = 0; take = 2 } in
  let lost_chat = Missing.Chat_bytes { from = 10; until = 90 } in
  let lost : Read_unit.t list =
    [ { line = 120
      ; at = 1_763_600_000.0
      ; kind =
          Read_unit.Turn
            { turn = 40; outcome = Turn_log.Completed; opened; unattributed = []; own = [] }
      ; missing = [ Missing.Bundle slice ]
      }
    ; { line = 300
      ; at = 1_763_600_060.0
      ; kind = Read_unit.Reset { cause = Turn_log.Cleared; items = [] }
      ; missing = [ lost_chat ]
      }
    ]
  in
  match
    Question.make ~lane ~memory:(memory (facts ())) ~from ~reach ~trace:"trace-1"
      ~offered:{ units = 2; head_items = 0 } lost
  with
  | Question.Made _ -> fail "a range with no item made a question"
  | Question.Nothing_readable { reach = through; missing } ->
    check bool "the reader's reach" true (through = reach);
    check
      bool
      "each unit's missing parts"
      true
      (missing
       = [ { Missing.line = 120; parts = [ Missing.Bundle slice ] }
         ; { Missing.line = 300; parts = [ lost_chat ] }
         ])
;;

let () =
  run
    "librarian_question"
    [ ( "question"
      , [ test_case "the same inputs give the same bytes" `Quick same_inputs_same_bytes
        ; test_case
            "a change to Memory alone moves the front half"
            `Quick
            memory_alone_moves_the_front_half
        ; test_case
            "a range whose items are all missing asks nothing"
            `Quick
            all_missing_asks_nothing
        ] )
    ]
;;
