(* The lines of a Keeper's turn log (RFC librarian-call-only-proposes §5.1
   to §5.3): the wire shape, what a line means for the unit before and after
   it, and the one order of lines a reader accepts. *)

open Alcotest
module Log = Masc.Keeper_turn_log
module Codec = Masc.Keeper_turn_log_codec
module Stimulus_codec = Masc.Keeper_turn_log_stimulus_codec
module Types = Masc.Keeper_memory_os_types

let ok_or_fail label = function
  | Ok value -> value
  | Error detail -> failf "%s: %s" label detail
;;

let log_id =
  match Log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let bundle fill =
  ok_or_fail "bundle" (Agent_core.Checkpoint_objects.digest_of_hex (String.make 64 fill))
;;

let task = ok_or_fail "task id" (Keeper_id.Task_id.of_string "task-3718")
let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:7

let mark ?(trace = "trace-1") ?(session = "") closed_messages : Log.mark =
  { trace
  ; closed_messages
  ; session
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 120
  ; external_rows = 2
  }
;;

let started = Log.Log_started { id = log_id; at = 100.0; mark = mark 4 }

let opened ?(task = Log.No_task) ?(stimuli = []) () =
  Log.Opened { at = 101.0; turn_ref; runtime = "glm-main"; task; stimuli; baseline = mark 5 }
;;

let board ?(event = Log.Post_created) () : Log.board_item =
  { post = "post-9"; author = "alice"; event }
;;

(* Every constructor, every Board event and every judge, each with the text
   it is written as. A renamed token or field fails here. *)
let every_stimulus : (Log.stimulus * string) list =
  [ Board (board ()), {|{"kind":"board","post":"post-9","author":"alice","event":"post_created"}|}
  ; ( Board (board ~event:Post_updated ())
    , {|{"kind":"board","post":"post-9","author":"alice","event":"post_updated"}|} )
  ; ( Board (board ~event:(Comment_added { comment = "comment-3" }) ())
    , {|{"kind":"board","post":"post-9","author":"alice","event":"comment_added","comment":"comment-3"}|}
    )
  ; ( Board (board ~event:(Reaction_changed { by = "bob" }) ())
    , {|{"kind":"board","post":"post-9","author":"alice","event":"reaction_changed","by":"bob"}|} )
  ; ( Board (board ~event:(Vote_cast { by = "carol" }) ())
    , {|{"kind":"board","post":"post-9","author":"alice","event":"vote_cast","by":"carol"}|} )
  ; ( Board_routing_pending (board ())
    , {|{"kind":"board_routing_pending","post":"post-9","author":"alice","event":"post_created"}|}
    )
  ; ( Board_attention { candidate = "candidate-1"; item = board () }
    , {|{"kind":"board_attention","candidate":"candidate-1","post":"post-9","author":"alice","event":"post_created"}|}
    )
  ; Bootstrap, {|{"kind":"bootstrap"}|}
  ; Tool_result { receipt = "receipt-1" }, {|{"kind":"tool_result","receipt":"receipt-1"}|}
  ; Fusion { run = "run-1" }, {|{"kind":"fusion","run":"run-1"}|}
  ; ( Schedule { schedule = "schedule-1"; occurrence = "occurrence-1" }
    , {|{"kind":"schedule","schedule":"schedule-1","occurrence":"occurrence-1"}|} )
  ; Connector { event = "attention-1" }, {|{"kind":"connector","attention":"attention-1"}|}
  ; Hitl { approval = "approval-1" }, {|{"kind":"hitl","approval":"approval-1"}|}
  ; Ask { ask = "ask-1" }, {|{"kind":"ask","ask":"ask-1"}|}
  ; ( Completion_rejected
        { task = "task-1"
        ; verification = "verification-1"
        ; judge = Human_operator { operator = "owner" }
        }
    , {|{"kind":"completion_rejected","task":"task-1","verification":"verification-1","judge":"human_operator","operator":"owner"}|}
    )
  ; ( Completion_approved
        { task = "task-1"
        ; verification = "verification-1"
        ; judge = System_agent { run = "judge-run-1" }
        }
    , {|{"kind":"completion_approved","task":"task-1","verification":"verification-1","judge":"system_agent","run":"judge-run-1"}|}
    )
  ; ( Task_cancelled { task = "task-2"; by = "dave" }
    , {|{"kind":"task_cancelled","task":"task-2","by":"dave"}|} )
  ; ( Workspace_message { request = "request-1"; from = "erin" }
    , {|{"kind":"workspace_message","request":"request-1","from":"erin"}|} )
  ; ( Delegate { operation = "operation-1"; keeper = "frank" }
    , {|{"kind":"delegate","operation":"operation-1","keeper":"frank"}|} )
  ; ( Composition { request = "request-2"; tool = "compose" }
    , {|{"kind":"composition","request":"request-2","tool":"compose"}|} )
  ; Owned_job { job = "job-1" }, {|{"kind":"owned_job","job":"job-1"}|}
  ]
;;

let woken : Log.stimulus list =
  [ Bootstrap; Workspace_message { request = "request-1"; from = "erin" } ]
;;

let own_slices : Log.slice list = [ { bundle = bundle 'c'; skip = 1; take = 3 } ]

let closed ?(outcome = Log.Completed) ?(own = own_slices) turn =
  Log.Closed
    { turn
    ; at = 102.5
    ; outcome
    ; after = mark 9
    ; unattributed = [ { bundle = bundle 'b'; skip = 0; take = 1 } ]
    ; own
    }
;;

let reset ?(cause = Log.Unannounced) () =
  Log.Reset
    { at = 103.0
    ; cause
    ; before = mark 9
    ; after = mark ~trace:"trace-2" 0
    ; closed_before = [ { bundle = bundle 'd'; skip = 0; take = 2 } ]
    }
;;

let text line = Yojson.Safe.to_string (Codec.to_json line)

let decoded label json_text =
  match Codec.of_json (Yojson.Safe.from_string json_text) with
  | Ok line -> line
  | Error error -> failf "%s: %s" label (Types.wire_error_to_string error)
;;

let every_line =
  [ started
  ; opened ()
  ; opened ~task:Log.Task_source_unavailable ()
  ; opened ~task:(Log.Task { task; goals = None }) ()
  ; opened ~task:(Log.Task { task; goals = Some [] }) ()
  ; opened
      ~task:
        (Log.Task
           { task; goals = Some [ { goal = "goal-12"; shown = "Review: the probe is green" } ] })
      ()
  ; opened ~stimuli:(List.map fst every_stimulus) ()
  ; reset ()
  ; reset ~cause:(Log.Announced Cleared) ()
  ; reset ~cause:(Log.Announced Recovered) ()
  ]
  @ List.map
      (fun outcome -> closed ~outcome 512)
      [ Log.Completed
      ; Errored
      ; Cancelled
      ; Save_failed
      ; Stale_save
      ; Close_missing
      ; Process_exited
      ]
;;

let test_round_trip () =
  List.iter
    (fun line ->
       let written = text line in
       check string "decode (encode line) = line" written (text (decoded "round trip" written)))
    every_line
;;

(* The shape is pinned as text, so a renamed field or token fails here and
   not only in a round trip that renames both directions together. *)
let golden_mark closed trace =
  Printf.sprintf
    {|{"trace":"%s","closed_messages":%d,"session":"","history_bytes":0,"internal_bytes":0,"chat_bytes":120,"external_rows":2}|}
    trace closed
;;

let golden =
  [ ( started
    , Printf.sprintf {|{"line":"log_started","id":"%s","at":100.0,"mark":%s}|}
        (String.make 32 'a') (golden_mark 4 "trace-1") )
  ; ( opened
        ~task:
          (Log.Task
             { task; goals = Some [ { goal = "goal-12"; shown = "Review: the probe is green" } ] })
        ()
    , Printf.sprintf
        {|{"line":"opened","at":101.0,"turn_ref":"%s","runtime":"glm-main","task":{"kind":"task","task":"task-3718","goals":[{"goal":"goal-12","shown":"Review: the probe is green"}]},"stimuli":[],"baseline":%s}|}
        (Ids.Turn_ref.to_string turn_ref)
        (golden_mark 5 "trace-1") )
  ; ( opened ~stimuli:woken ()
    , Printf.sprintf
        {|{"line":"opened","at":101.0,"turn_ref":"%s","runtime":"glm-main","task":{"kind":"no_task"},"stimuli":[{"kind":"bootstrap"},{"kind":"workspace_message","request":"request-1","from":"erin"}],"baseline":%s}|}
        (Ids.Turn_ref.to_string turn_ref)
        (golden_mark 5 "trace-1") )
  ; ( closed ~outcome:Log.Process_exited 512
    , Printf.sprintf
        {|{"line":"closed","turn":512,"at":102.5,"outcome":"process_exited","after":%s,"unattributed":[{"bundle":"%s","skip":0,"take":1}],"own":[{"bundle":"%s","skip":1,"take":3}]}|}
        (golden_mark 9 "trace-1") (String.make 64 'b') (String.make 64 'c') )
  ; ( reset ~cause:(Log.Announced Cleared) ()
    , Printf.sprintf
        {|{"line":"reset","at":103.0,"cause":"cleared","before":%s,"after":%s,"closed_before":[{"bundle":"%s","skip":0,"take":2}]}|}
        (golden_mark 9 "trace-1") (golden_mark 0 "trace-2") (String.make 64 'd') )
  ]
;;

let test_golden () =
  List.iter
    (fun (line, expected) ->
       check string "written" expected (text line);
       check string "read" expected (text (decoded "golden" expected)))
    golden
;;

let test_every_stimulus () =
  List.iter
    (fun (stimulus, expected) ->
       check string "written" expected
         (Yojson.Safe.to_string (Stimulus_codec.to_json stimulus));
       match Stimulus_codec.of_json (Yojson.Safe.from_string expected) with
       | Ok read ->
         check string "read" expected (Yojson.Safe.to_string (Stimulus_codec.to_json read))
       | Error error -> failf "%s: %s" expected (Types.wire_error_to_string error))
    every_stimulus;
  let kinds =
    List.sort_uniq String.compare
      (List.map
         (fun (stimulus, (_ : string)) ->
            match Stimulus_codec.to_json stimulus with
            | `Assoc fields ->
              (match List.assoc_opt "kind" fields with
               | Some (`String kind) -> kind
               | Some _ | None -> fail "a stimulus without a kind")
            | _ -> fail "a stimulus that is not an object")
         every_stimulus)
  in
  check int "kinds on the wire" 17 (List.length kinds)
;;

let replace_once ~old ~by source =
  let replaced = String_util.replace_substring ~needle:old ~by source in
  if String.equal replaced source then failf "the golden line does not hold %s" old else replaced
;;

let golden_of line = List.assoc line golden

let expect_rejected label ~path ~reason json_text =
  match Codec.of_json (Yojson.Safe.from_string json_text) with
  | Ok (_ : Log.line) -> failf "%s: accepted" label
  | Error error ->
    check string label
      (Types.wire_error_to_string { path; reason })
      (Types.wire_error_to_string error)
;;

let test_rejections () =
  let started_text = golden_of started in
  let closed_text = golden_of (closed ~outcome:Log.Process_exited 512) in
  let reset_text = golden_of (reset ~cause:(Log.Announced Cleared) ()) in
  expect_rejected "not an object" ~path:[] ~reason:Expected_object "[]";
  expect_rejected "an unknown line" ~path:[ Wire_field "line" ] ~reason:(Unknown_token "ended")
    (replace_once ~old:{|"log_started"|} ~by:{|"ended"|} started_text);
  expect_rejected "an extra field" ~path:[]
    ~reason:(Field_set_mismatch { missing = []; unexpected = [ "note" ] })
    (replace_once ~old:{|{"line"|} ~by:{|{"note":"x","line"|} started_text);
  expect_rejected "a log id that is not 32 hexadecimal characters" ~path:[ Wire_field "id" ]
    ~reason:(Unknown_token "abc")
    (replace_once ~old:(String.make 32 'a') ~by:"abc" started_text);
  expect_rejected "a negative count"
    ~path:[ Wire_field "mark"; Wire_field "closed_messages" ]
    ~reason:Negative
    (replace_once ~old:{|"closed_messages":4|} ~by:{|"closed_messages":-1|} started_text);
  expect_rejected "a mark without a store"
    ~path:[ Wire_field "mark" ]
    ~reason:(Field_set_mismatch { missing = [ "external_rows" ]; unexpected = [] })
    (replace_once ~old:{|,"external_rows":2|} ~by:"" started_text);
  expect_rejected "an unknown outcome" ~path:[ Wire_field "outcome" ]
    ~reason:(Unknown_token "finished")
    (replace_once ~old:{|"process_exited"|} ~by:{|"finished"|} closed_text);
  expect_rejected "a slice that takes nothing"
    ~path:[ Wire_field "own"; Wire_index 0; Wire_field "take" ]
    ~reason:Not_positive
    (replace_once ~old:{|"take":3|} ~by:{|"take":0|} closed_text);
  expect_rejected "a bundle that is not a digest"
    ~path:[ Wire_field "unattributed"; Wire_index 0; Wire_field "bundle" ]
    ~reason:(Unknown_token "bbbb")
    (replace_once ~old:(String.make 64 'b') ~by:"bbbb" closed_text);
  expect_rejected "an unknown cause" ~path:[ Wire_field "cause" ]
    ~reason:(Unknown_token "announced")
    (replace_once ~old:{|"cleared"|} ~by:{|"announced"|} reset_text);
  let task_text =
    List.assoc
      (opened
         ~task:
           (Log.Task
              { task; goals = Some [ { goal = "goal-12"; shown = "Review: the probe is green" } ] })
         ())
      golden
  in
  expect_rejected "a turn ref that is not one" ~path:[ Wire_field "turn_ref" ]
    ~reason:(Not_a_turn_ref "seven")
    (replace_once ~old:(Ids.Turn_ref.to_string turn_ref) ~by:"seven" task_text);
  expect_rejected "a task id that is not one"
    ~path:[ Wire_field "task"; Wire_field "task" ]
    ~reason:(Unknown_token "")
    (replace_once ~old:{|"task":"task-3718"|} ~by:{|"task":""|} task_text);
  expect_rejected "goals that are neither a list nor null"
    ~path:[ Wire_field "task"; Wire_field "goals" ]
    ~reason:Expected_array
    (replace_once
       ~old:{|"goals":[{"goal":"goal-12","shown":"Review: the probe is green"}]|}
       ~by:{|"goals":"goal-12"|} task_text);
  let woken_text = golden_of (opened ~stimuli:woken ()) in
  expect_rejected "an Opened without its stimuli" ~path:[]
    ~reason:(Field_set_mismatch { missing = [ "stimuli" ]; unexpected = [] })
    (replace_once ~old:{|"stimuli":[],|} ~by:"" task_text);
  expect_rejected "an unknown kind of stimulus"
    ~path:[ Wire_field "stimuli"; Wire_index 0; Wire_field "kind" ]
    ~reason:(Unknown_token "woke")
    (replace_once ~old:{|"kind":"bootstrap"|} ~by:{|"kind":"woke"|} woken_text);
  expect_rejected "a stimulus with another kind's fields"
    ~path:[ Wire_field "stimuli"; Wire_index 1 ]
    ~reason:(Field_set_mismatch { missing = []; unexpected = [ "from"; "request" ] })
    (replace_once ~old:{|"kind":"workspace_message"|} ~by:{|"kind":"bootstrap"|} woken_text);
  expect_rejected "a Board comment without its id"
    ~path:[ Wire_field "stimuli"; Wire_index 0 ]
    ~reason:(Field_set_mismatch { missing = [ "comment" ]; unexpected = [] })
    (replace_once ~old:{|{"kind":"bootstrap"}|}
       ~by:{|{"kind":"board","post":"p","author":"a","event":"comment_added"}|} woken_text);
  expect_rejected "a turn offset below zero" ~path:[ Wire_field "turn" ] ~reason:Negative
    (replace_once ~old:{|"turn":512|} ~by:{|"turn":-1|} closed_text);
  expect_rejected "a field given twice" ~path:[] ~reason:(Duplicate_field "at")
    (replace_once ~old:{|"at":100.0|} ~by:{|"at":100.0,"at":100.0|} started_text);
  expect_rejected "a task kind with another kind's fields" ~path:[ Wire_field "task" ]
    ~reason:(Field_set_mismatch { missing = []; unexpected = [ "goals"; "task" ] })
    (replace_once ~old:{|"kind":"task"|} ~by:{|"kind":"no_task"|}
       (List.assoc
          (opened
             ~task:
               (Log.Task
                  { task
                  ; goals = Some [ { goal = "goal-12"; shown = "Review: the probe is green" } ]
                  })
             ())
          golden))
;;

(* RFC §5.3, the table of three rows. *)
let test_boundary () =
  let closed_messages (mark : Log.mark) = mark.closed_messages in
  (match Log.boundary started with
   | Starts_at mark -> check int "the first unit starts at the log's mark" 4 (closed_messages mark)
   | Ends_unit _ | Moves_nothing -> fail "Log_started is not a unit");
  (match Log.boundary (opened ()) with
   | Moves_nothing -> ()
   | Starts_at _ | Ends_unit _ -> fail "Opened moves the point");
  (match Log.boundary (closed 512) with
   | Ends_unit { through; next } ->
     check (pair int int) "Closed: through after, next from after" (9, 9)
       (closed_messages through, closed_messages next)
   | Starts_at _ | Moves_nothing -> fail "Closed is a unit");
  match Log.boundary (reset ()) with
  | Ends_unit { through; next } ->
    check (pair int int) "Reset: through before, next from after" (9, 0)
      (closed_messages through, closed_messages next);
    check string "the next unit is on the new trace" "trace-2" next.trace
  | Starts_at _ | Moves_nothing -> fail "Reset is a unit"
;;

let position_text : Log.position -> string = function
  | Nothing_written -> "nothing written"
  | Between_turns -> "between turns"
  | Turn_open { opened; reset_since } ->
    Printf.sprintf "turn open at %d%s" opened (if reset_since then " after a reset" else "")
;;

let order_error_text : Log.order_error -> string = function
  | Not_started -> "not started"
  | Started_twice -> "started twice"
  | Opened_while_open { opened } -> Printf.sprintf "opened while %d is open" opened
  | Closed_without_open -> "closed without open"
  | Closed_another_turn { opened; closed } ->
    Printf.sprintf "closed %d while %d is open" closed opened
  | Own_after_reset { opened } -> Printf.sprintf "turn %d names its own after a reset" opened
;;

(* Lines at offsets 0, 100, 200, ... *)
let walk lines =
  let rec go position offset = function
    | [] -> Ok position
    | line :: rest ->
      (match Log.step position ~offset line with
       | Ok position -> go position (offset + 100) rest
       | Error error -> Error error)
  in
  match go Log.Nothing_written 0 lines with
  | Ok position -> position_text position
  | Error error -> order_error_text error
;;

let test_order () =
  check string "an empty file" "nothing written" (walk []);
  check string "a started log" "between turns" (walk [ started ]);
  check string "a whole turn with resets on both sides and inside" "between turns"
    (walk [ started; reset (); opened (); reset (); reset (); closed ~own:[] 200; reset () ]);
  check string "a file that ends in a running turn" "turn open at 300"
    (walk [ started; opened (); closed 100; opened () ]);
  check string "a reset inside the running turn is remembered" "turn open at 300 after a reset"
    (walk [ started; opened (); closed 100; opened (); reset () ]);
  check string "a reset before the turn does not count against it" "between turns"
    (walk [ started; reset (); opened (); closed 200 ]);
  check string "after a reset the turn has nothing of its own"
    "turn 100 names its own after a reset"
    (walk [ started; opened (); reset (); closed 100 ]);
  check string "a line before the log started" "not started" (walk [ opened () ]);
  check string "a reset before the log started" "not started" (walk [ reset () ]);
  check string "a second start" "started twice" (walk [ started; started ]);
  check string "a second start inside a turn" "started twice" (walk [ started; opened (); started ]);
  check string "two opened lines together" "opened while 100 is open"
    (walk [ started; opened (); opened () ]);
  check string "a close with nothing open" "closed without open" (walk [ started; closed 100 ]);
  check string "a close that names another turn" "closed 512 while 100 is open"
    (walk [ started; opened (); closed 512 ])
;;

let test_log_id () =
  let accepted text = Option.is_some (Log.Log_id.of_string text) in
  check bool "32 lowercase hexadecimal characters" true (accepted (String.make 32 '0'));
  check bool "uppercase" false (accepted (String.make 32 'A'));
  check bool "short" false (accepted (String.make 31 'a'));
  check bool "a whole digest" false (accepted (String.make 64 'a'))
;;

let () =
  run "keeper_turn_log"
    [ ( "codec"
      , [ test_case "round trip of every line" `Quick test_round_trip
        ; test_case "the wire shape as text" `Quick test_golden
        ; test_case "every stimulus as text" `Quick test_every_stimulus
        ; test_case "rejections" `Quick test_rejections
        ; test_case "log id" `Quick test_log_id
        ] )
    ; "units", [ test_case "where a line ends a unit" `Quick test_boundary ]
    ; "order", [ test_case "the one accepted order" `Quick test_order ]
    ]
;;
