(* RFC librarian-call-only-proposes §7.4: the head item's size facts, and the
   verdict folded over the slots the lane declares now. The same rules are
   in specs/bug-models/LibrarianBottom.tla: [Learn] and [Fold] there. *)

open Alcotest
module Bottom = Masc.Librarian_bottom
module Lane = Masc.Librarian_memory_lane
module Outcome = Masc.Librarian_slot_outcome

let slot id : Lane.slot_key =
  { id; target = Cli { runtime_id = id; api_name = "claude-haiku-5" }; window = 200_000 }
;;

let fast = slot "claude_code.fast"
let wide = slot "claude_code.wide"

let lane ?(unadmitted = []) cli : Lane.t =
  { question =
      { prompt = "memory prompt"
      ; answer_schemas =
          { Lane.range = `Assoc [ "type", `String "object" ]
          ; item_alone = `Assoc [ "type", `String "object" ]
          ; room = `Assoc [ "type", `String "object" ]
          }
      ; max_output_tokens = 4096
      ; thinking = None
      }
  ; http = []
  ; cli
  ; unadmitted
  }
;;

let id front =
  match
    Masc.Librarian_question_id.of_halves ~front:(String.make 32 front) ~back:(String.make 32 'd')
  with
  | Some id -> id
  | None -> fail "the test halves are not 32 hexadecimal characters"
;;

let first = id 'a'
let second = id 'b'

let verdict_text : Bottom.verdict -> string = function
  | Input -> "input"
  | All_not_input -> "all, not input"
  | Not_all -> "not all"
;;

let fact_text : Outcome.size_fact -> string = function
  | Input_too_large -> "input"
  | Output_over_reserve -> "output"
  | Window_reached -> "window"
;;

let known_text bottom which question =
  List.map
    (fun ((key : Lane.slot_key), fact) -> key.id ^ " " ^ fact_text fact)
    (Bottom.known bottom which question)
;;

let input : Outcome.unanswered = Refused (Sized Input_too_large)

(* The model's DescendsOnlyOnInput, BottomOnlyWhenAllSized and
   UnsizedLaneStaysAbove: only a size fact from every slot declared now is a
   verdict to go below the item or stop at it. *)
let test_the_verdict_reads_every_slot_declared_now () =
  check (list string) "the verdicts"
    [ "input"; "all, not input"; "not all"; "not all"; "not all"; "not all"; "not all" ]
    (List.map verdict_text
       [ Bottom.fold (lane [ fast; wide ]) [ fast, input; wide, input ]
       ; Bottom.fold (lane [ fast; wide ]) [ fast, input; wide, Refused (Sized Output_over_reserve) ]
       ; Bottom.fold (lane [ fast; wide ]) [ fast, input; wide, Refused Unsized ]
       ; Bottom.fold (lane [ fast; wide ]) [ fast, input; wide, Silent Busy ]
       (* [wide] was declared after the walk started. *)
       ; Bottom.fold (lane [ fast; wide ]) [ fast, input ]
       ; Bottom.fold (lane ~unadmitted:[ "openrouter.down" ] [ fast ]) [ fast, input ]
       ; Bottom.fold (lane []) []
       ]);
  check string "a slot no longer declared is not read" "input"
    (verdict_text (Bottom.fold (lane [ fast ]) [ fast, input; wide, Refused Unsized ]))
;;

(* §7.4 「기억하는 것은 한 항목짜리 질문에 대한 Refused (Sized _) 뿐이다」 and
   「기록은 다른 질문 id 의 크기 사실이 올 때만 갈아 쓴다」. *)
let test_only_size_facts_are_kept () =
  let bottom =
    Bottom.learn Bottom.empty With_memory first [ fast, input; wide, Refused Unsized ]
  in
  check (list string) "the sized refusal" [ "claude_code.fast input" ]
    (known_text bottom With_memory first);
  check (list string) "nothing under the other question" [] (known_text bottom Alone first);
  check (list string) "nothing under another id" [] (known_text bottom With_memory second);
  let bottom = Bottom.learn bottom With_memory first [ wide, Refused (Sized Window_reached) ] in
  check (list string) "the same id joins"
    [ "claude_code.wide window"; "claude_code.fast input" ]
    (known_text bottom With_memory first);
  let bottom =
    Bottom.learn bottom With_memory first [ fast, Refused (Sized Output_over_reserve) ]
  in
  check (list string) "a slot's new fact replaces its old one"
    [ "claude_code.fast output"; "claude_code.wide window" ]
    (known_text bottom With_memory first);
  let unchanged = Bottom.learn bottom With_memory second [ fast, Silent Busy ] in
  check (list string) "a result with no size fact changes nothing"
    [ "claude_code.fast output"; "claude_code.wide window" ]
    (known_text unchanged With_memory first);
  let replaced = Bottom.learn bottom With_memory second [ wide, input ] in
  check (list string) "another id replaces them" [ "claude_code.wide input" ]
    (known_text replaced With_memory second);
  check (list string) "and the old id finds none" [] (known_text replaced With_memory first)
;;

let () =
  run "librarian_bottom"
    [ ( "bottom"
      , [ test_case "the verdict reads every slot declared now" `Quick
            test_the_verdict_reads_every_slot_declared_now
        ; test_case "only size facts are kept" `Quick test_only_size_facts_are_kept
        ] )
    ]
;;
