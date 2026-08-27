(* The loop between a human answering and the Keeper that asked.

   Before this, an answer was validated, written to the log, and the request
   returned 200 — and the Keeper was never told. It could only find out by
   calling masc_ask_status, and nothing prompted it to. In a live workspace
   with ten Keepers and a month of history, not one question had ever been
   asked: asking was a dead end.

   These tests cover the two halves that close it. The wake has to survive the
   durable queue, and the row the Keeper reads has to carry what the human
   actually said. *)

open Masc
open Alcotest

let choice ~id ~label =
  match Keeper_ask.choice ~choice_id:id ~label () with
  | Ok c -> c
  | Error e -> failf "choice: %s" (Keeper_ask.invalid_choice_to_string e)
;;

let question ~id ~header ~choices =
  match
    Keeper_ask.question ~question_id:id ~header ~prompt:("Which way for " ^ header ^ "?")
      ~choices ~mode:Keeper_ask.Single ~free_text:Keeper_ask.Choices_only
  with
  | Ok q -> q
  | Error e -> failf "question: %s" (Keeper_ask.invalid_question_to_string e)
;;

let ask_with questions =
  match
    Keeper_ask.ask ~ask_id:"ask-1" ~keeper_name:"alpha" ~questions ~context:"why"
      ~continuation:(Keeper_continuation_channel.unrouted "test")
      ~asked_at:100. ()
  with
  | Ok a -> a
  | Error e -> failf "ask: %s" (Keeper_ask.invalid_ask_to_string e)
;;

let answers_for ask submissions =
  match Keeper_ask.parse_answers ~ask ~submissions with
  | Ok answers -> answers
  | Error failures ->
    failf "answers: %s"
      (String.concat ", " (List.map Keeper_ask.invalid_answer_to_string failures))
;;

let responder =
  { Keeper_ask.surface = Surface_ref.Dashboard { session_id = None }
  ; actor_id = Some "U1"
  ; display_name = Some "Vincent"
  }
;;

let meta =
  let json =
    `Assoc
      [ ("name", `String "alpha")
      ; ("agent_name", `String (Keeper_identity.keeper_agent_name "alpha"))
      ; ("trace_id", `String "trace-ask-alpha")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> failf "meta: %s" err
;;

let contains haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  let rec at i = i + nn <= hn && (String.sub haystack i nn = needle || at (i + 1)) in
  at 0
;;

(* The wake carries a pointer, so it has to come back out of the durable queue
   as the same pointer. A writer without a matching reader is how the field
   would go quiet. *)
let test_the_wake_survives_the_queue () =
  let payload =
    { Keeper_event_queue.ask_id = "ask-1"
    ; channel = Keeper_continuation_channel.unrouted "test"
    }
  in
  let stimulus =
    { Keeper_event_queue.post_id = Keeper_event_queue.ask_answered_post_id payload
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 12.5
    ; payload = Keeper_event_queue.Ask_answered payload
    }
  in
  match
    Keeper_event_queue.stimulus_of_yojson (Keeper_event_queue.stimulus_to_yojson stimulus)
  with
  | Error e -> failf "the wake did not survive the queue: %s" e
  | Ok back ->
    (match back.Keeper_event_queue.payload with
     | Keeper_event_queue.Ask_answered read ->
       check string "ask_id" "ask-1" read.Keeper_event_queue.ask_id
     | _ -> fail "decoded as some other stimulus")
;;

(* One answer per question, so the ask id alone identifies the wake. *)
let test_the_wake_is_keyed_by_the_question () =
  let key ask_id =
    Keeper_event_queue.ask_answered_post_id
      { Keeper_event_queue.ask_id
      ; channel = Keeper_continuation_channel.unrouted "test"
      }
  in
  check string "keyed by the ask" "keeper-ask:ask-1" (key "ask-1");
  check bool "different asks do not collide" false
    (String.equal (key "ask-1") (key "ask-2"))
;;

(* The Keeper reads labels, not identities. Answers reference choice ids so
   that rewording a choice cannot orphan them — which means the row has to do
   the resolving, or the Keeper is handed an opaque id. *)
let test_the_row_says_what_the_human_picked () =
  let ask =
    ask_with
      [ question ~id:"q1" ~header:"deploy"
          ~choices:
            [ choice ~id:"c1" ~label:"roll forward"
            ; choice ~id:"c2" ~label:"roll back"
            ]
      ]
  in
  let answers = answers_for ask [ "q1", Keeper_ask.Chose { choice_ids = [ "c2" ] } ] in
  let row =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask ~answers
      ~responder ~answered_at:200.
  in
  check bool "the label, not the id" true
    (contains row.Keeper_world_observation.preview "roll back");
  check bool "the id is not what the Keeper reads" false
    (contains row.Keeper_world_observation.preview "c2");
  check bool "which question" true
    (contains row.Keeper_world_observation.preview "deploy");
  check string "who answered" "Vincent" row.Keeper_world_observation.author;
  check string "identity points back at the ask" "keeper-ask:ask-1"
    row.Keeper_world_observation.post_id
;;

(* Free text and a declined question are answers too; neither may come through
   blank. *)
let test_written_and_skipped_answers_are_readable () =
  let ask =
    ask_with
      [ (match
           Keeper_ask.question ~question_id:"q1" ~header:"notes" ~prompt:"Anything?"
             ~choices:[]
             ~mode:Keeper_ask.Single
             ~free_text:(Keeper_ask.Free_text_allowed { hint = None })
         with
         | Ok q -> q
         | Error e -> failf "question: %s" (Keeper_ask.invalid_question_to_string e))
      ]
  in
  let written =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask
      ~answers:(answers_for ask [ "q1", Keeper_ask.Wrote "ship it on Friday" ])
      ~responder ~answered_at:200.
  in
  check bool "the words the human wrote" true
    (contains written.Keeper_world_observation.preview "ship it on Friday");
  let skipped =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask
      ~answers:(answers_for ask [ "q1", Keeper_ask.Skipped ])
      ~responder ~answered_at:200.
  in
  check bool "a declined question still says so" true
    (contains skipped.Keeper_world_observation.preview "skipped")
;;

(* The row is what the turn renders. Left out of the rendered set, the Keeper
   is woken with an empty pending-events list — a wake it cannot act on, which
   is the failure this whole change is about. *)
let test_the_row_is_one_the_turn_renders () =
  let ask =
    ask_with
      [ question ~id:"q1" ~header:"deploy" ~choices:[ choice ~id:"c1" ~label:"yes" ] ]
  in
  let row =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask
      ~answers:(answers_for ask [ "q1", Keeper_ask.Chose { choice_ids = [ "c1" ] } ])
      ~responder ~answered_at:200.
  in
  check bool "rendered" true (Keeper_world_observation.is_board_activity_event row)
;;

(* No Board post stands behind this row. Marked as a human's post, the Keeper
   read it as one it could fetch and burned a masc_board_post_get on
   "Invalid post_id: keeper-ask" — seen four times in one live run before this
   was corrected. *)
let test_the_row_is_not_a_board_post () =
  let ask =
    ask_with
      [ question ~id:"q1" ~header:"deploy" ~choices:[ choice ~id:"c1" ~label:"yes" ] ]
  in
  let row =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask
      ~answers:(answers_for ask [ "q1", Keeper_ask.Chose { choice_ids = [ "c1" ] } ])
      ~responder ~answered_at:200.
  in
  check bool "nothing to fetch" true
    (row.Keeper_world_observation.post_kind = Board.System_post)
;;

(* Storing the answer and telling the Keeper are one act. The handler has to
   make the call; a wake nothing emits is the state this started in. *)
let test_the_answer_route_emits_the_wake () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"lib/server/server_routes_http_keeper_stream.ml"
      ~binding_name:"handle_keeper_ask_answer"
      ~callee:"wake_keeper_for_answered_ask"
  in
  if n < 1 then
    failf
      "answering a question must wake the Keeper that asked; \
       wake_keeper_for_answered_ask is called %d time(s) in handle_keeper_ask_answer"
      n
;;

(* Recording the answer and telling the Keeper are one act, so the route cannot
   report success when only the first half happened. An operator who reads 200
   stops thinking about it while the Keeper waits forever. *)
let test_an_undelivered_answer_is_not_reported_as_success () =
  let status, body =
    Server_routes_http_keeper_stream.ask_answer_response ~ask_id:"ask-1"
      ~answer_count:1 ~open_remaining:0 ~delivered:false
  in
  check bool "not a success" true (status = `Internal_server_error);
  (match body with
   | `Assoc fields ->
     check bool "says the keeper was not told" true
       (List.assoc_opt "delivered" fields = Some (`Bool false));
     check bool "and says so in words" true (List.mem_assoc "error" fields)
   | _ -> fail "the body is not an object")
;;

let test_a_delivered_answer_is_a_success () =
  let status, body =
    Server_routes_http_keeper_stream.ask_answer_response ~ask_id:"ask-1"
      ~answer_count:1 ~open_remaining:0 ~delivered:true
  in
  check bool "success" true (status = `OK);
  (match body with
   | `Assoc fields ->
     check bool "delivered" true
       (List.assoc_opt "delivered" fields = Some (`Bool true));
     check bool "nothing to explain" false (List.mem_assoc "error" fields)
   | _ -> fail "the body is not an object")
;;

(* The retry that finishes a delivery. An answer already recorded but never
   delivered can only be rescued by answering again, so the refusal path has
   to re-enqueue rather than stop at "you lost the race". *)
let test_answering_again_completes_a_lost_delivery () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"lib/server/server_routes_http_keeper_stream.ml"
      ~binding_name:"handle_keeper_ask_answer"
      ~callee:"wake_keeper_for_answered_ask"
  in
  if n < 2 then
    failf
      "answering again must complete a delivery that failed the first time; \
       wake_keeper_for_answered_ask is called %d time(s)"
      n
;;

let () =
  run "keeper_ask_answer_wake"
    [ ( "wake"
      , [ test_case "the wake survives the queue" `Quick test_the_wake_survives_the_queue
        ; test_case "the wake is keyed by the question" `Quick
            test_the_wake_is_keyed_by_the_question
        ; test_case "the answer route emits the wake" `Quick
            test_the_answer_route_emits_the_wake
        ; test_case "an undelivered answer is not reported as success" `Quick
            test_an_undelivered_answer_is_not_reported_as_success
        ; test_case "a delivered answer is a success" `Quick
            test_a_delivered_answer_is_a_success
        ; test_case "answering again completes a lost delivery" `Quick
            test_answering_again_completes_a_lost_delivery
        ] )
    ; ( "row"
      , [ test_case "the row says what the human picked" `Quick
            test_the_row_says_what_the_human_picked
        ; test_case "written and skipped answers are readable" `Quick
            test_written_and_skipped_answers_are_readable
        ; test_case "the row is one the turn renders" `Quick
            test_the_row_is_one_the_turn_renders
        ; test_case "the row is not a Board post" `Quick
            test_the_row_is_not_a_board_post
        ] )
    ]
;;
