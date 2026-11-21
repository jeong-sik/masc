(* The lines of a Keeper's commit log (RFC librarian-call-only-proposes
   §8.1): every constructor is read back as it was written, the shape of a
   line is pinned as text, and a line that is not exactly its fields is
   refused with the path of what is wrong. *)

open Alcotest
module Log = Masc.Librarian_log
module Codec = Masc.Librarian_log_codec
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Answer = Masc.Librarian_answer
module Unit = Masc.Librarian_unit
module Turn_log = Masc.Keeper_turn_log
module Types = Masc.Keeper_memory_os_types

let ok_or_fail label = function
  | Ok value -> value
  | Error detail -> failf "%s: %s" label detail
;;

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let digest fill =
  ok_or_fail "digest" (Agent_core.Checkpoint_objects.digest_of_hex (String.make 64 fill))
;;

let covered : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 4
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 120
  ; external_rows = 2
  }
;;

let covered_text =
  {|{"trace":"trace-1","closed_messages":4,"session":"","history_bytes":0,"internal_bytes":0,"chat_bytes":120,"external_rows":2}|}
;;

let authored : Types.origin = { kind = Types.Authored; trace_id = "turn" }

let observed claim : Types.fact =
  { claim
  ; category = Types.Constraint
  ; first_seen = 100.0
  ; last_seen = 100.0
  ; origin = authored
  ; basis = Types.Observed Types.Transcript
  }
;;

let id = Types.memory_id
let port = observed "the port is 8935"
let owner = observed "the owner is the release team"

let rests =
  ok_or_fail "derived"
    (Types.derived ~claim:"requests go to 8935" ~category:Types.Lesson ~now:100.0
       ~origin:authored
       ~derivations:[ { rule_id = "rule"; premise_ids = [ id port ] } ])
;;

let started =
  Log.Started
    { at = 100.0
    ; turn_log
    ; snapshot = digest 'a'
    ; revision = 3
    ; turn_log_offset = 0
    ; covered
    }
;;

let committed
      ?(cause = Log.Adopt { by = "operator-1"; observed = digest 'b' })
      ?(effects = Effects.empty)
      ?(covers_through = Log.Through { line = 256; within = Item { store = Agent_core; at = 3 } })
      ?(working_state = Some "checking the port")
      ()
  =
  Log.Committed
    { seq = 2
    ; at = 200.0
    ; basis = digest 'a'
    ; after = digest 'b'
    ; revision = 4
    ; cause
    ; effects
    ; turn_log
    ; turn_log_offset = 512
    ; covers_through
    ; covered
    ; working_state
    }
;;

let direct ?(by = Effects.Keeper) write = Log.Direct { by; trace = "turn"; write }
let transcript = Types.Observed Types.Transcript

let stated : Answer.new_fact =
  { claim = "the probe runs every minute"
  ; category = Types.Fact
  ; observation = Types.Transcript
  ; from_units = [ "u1" ]
  }
;;

let every_removal : Effects.removal list =
  [ Dropped { reason = "no longer true" }
  ; Merged_into (id owner)
  ; Revised_into (id owner)
  ; Superseded_by (id owner)
  ; Retracted { by = Keeper; reason = "the port moved" }
  ; Retracted { by = Operator "operator-1"; reason = "wrong" }
  ; Support_lost { missing = [ id port; id owner ] }
  ]
;;

let every_why : Effects.why_not list =
  [ Unknown_ref
  ; Ref_used_twice
  ; Source_outside_question
  ; Removed_during_flight { seq = 7 }
  ; Not_valid_alone
  ; Not_valid_in_room
  ; Successor_unsupported
  ]
;;

let full_effects : Effects.t =
  { added = [ owner; rests ]
  ; touched = [ id port ]
  ; removed = List.map (fun removal -> port, removal) every_removal
  ; not_applied =
      List.mapi
        (fun number why -> number, why, if number mod 2 = 0 then Some stated else None)
        every_why
  ; sources = [ id owner, [ 0; 256 ]; id rests, [] ]
  }
;;

let question =
  match
    Masc.Librarian_question_id.of_halves ~front:(String.make 32 'c') ~back:(String.make 32 'd')
  with
  | Some question -> question
  | None -> fail "the test question halves are not 32 hexadecimal characters"
;;

let every_part : Unit.missing_part list =
  [ Bundle { bundle = digest 'c'; skip = 0; take = 2 }
  ; History_bytes { from = 0; until = 10 }
  ; Internal_bytes { from = 10; until = 20 }
  ; Chat_bytes { from = 0; until = 64 }
  ; External_rows { from = 1; until = 3 }
  ; Undecodable_history_line { offset = 10 }
  ; Undecodable_internal_line { offset = 20 }
  ; Undecodable_external_row { row = 3 }
  ]
;;

let missing : Unit.missing_at list = [ { line = 120; parts = every_part } ]

let read ?(shown = Log.With_memory) ?(missing = missing) () =
  Log.Read { question; shown; slot = "claude_code.fast"; trace = "trace-2"; missing }
;;

(* Where an unannounced reset left the stores. *)
let reset_after : Turn_log.mark = { covered with trace = "trace-2"; closed_messages = 0 }

let reset_after_text =
  {|{"trace":"trace-2","closed_messages":0,"session":"","history_bytes":0,"internal_bytes":0,"chat_bytes":120,"external_rows":2}|}
;;

let make_room = Log.Make_room { question; slot = "claude_code.fast"; trace = "trace-2" }
let content_missing = Log.Skip { hole = Content_missing missing }
let unknown_span = Log.Skip { hole = Unknown_span { before = covered; after = reset_after } }
let item_exceeds_window = Log.Skip { hole = Item_exceeds_window missing }

let other_log =
  match Turn_log.Log_id.of_string (String.make 32 'b') with
  | Some id -> id
  | None -> fail "the other log id is not 32 hexadecimal characters"
;;

let turn_log_replaced = Log.Skip { hole = Turn_log_replaced { from = turn_log; to_ = other_log } }
let position_lost = Log.Skip { hole = Position_lost { offset = 4096; length = 512 } }
let line_unreadable = Log.Skip { hole = Line_unreadable { offset = 240; sha = digest 'e' } }
let operator_skipped = Log.Skip { hole = Operator_skipped { by = "operator-1"; missing } }

let every_line =
  [ started
  ; committed ()
  ; committed ~covers_through:Log.Before_first ~working_state:None ()
  ; committed ~covers_through:(Log.Through { line = 0; within = Whole }) ()
  ; committed ~working_state:(Some "") ()
  ; committed ~effects:full_effects ()
  ; committed
      ~cause:
        (direct
           (Direct.Remember
              { claim = port.claim; category = Types.Constraint; basis = transcript }))
      ()
  ; committed
      ~cause:
        (direct ~by:(Effects.Operator "operator-1")
           (Direct.Supersede
              { old = id port
              ; claim = rests.claim
              ; category = Types.Lesson
              ; basis = rests.basis
              }))
      ()
  ; committed
      ~cause:(direct (Direct.Retract { id = id port; reason = "the port moved" }))
      ()
  ; committed ~cause:(read ()) ()
  ; committed ~cause:(read ~shown:(Item_alone Untouched) ~missing:[] ()) ()
  ; committed ~cause:(read ~shown:(Item_alone Not_valid_alone) ()) ()
  ; committed ~cause:make_room ~effects:full_effects ()
  ; committed ~cause:content_missing ()
  ; committed ~cause:unknown_span ()
  ; committed ~cause:item_exceeds_window ()
  ; committed ~cause:turn_log_replaced ~covers_through:Log.Before_first ()
  ; committed ~cause:position_lost ~covers_through:Log.Before_first ()
  ; committed ~cause:line_unreadable ()
  ; committed ~cause:operator_skipped ()
  ]
;;

let text line = Yojson.Safe.to_string (Codec.to_json line)

let decoded label json_text =
  match Codec.of_json (Yojson.Safe.from_string json_text) with
  | Ok line -> line
  | Error error -> failf "%s: %s" label (Types.wire_error_to_string error)
;;

let test_round_trip () =
  List.iteri
    (fun index line ->
       let label = Printf.sprintf "line %d" index in
       let written = text line in
       check bool (label ^ " is one line") false (String.contains written '\n');
       let read = decoded label written in
       check bool (label ^ " reads back as the same value") true (read = line);
       check string (label ^ " writes the same text again") written (text read))
    every_line
;;

let started_text =
  Printf.sprintf
    {|{"line":"started","at":100.0,"turn_log":"%s","snapshot":"%s","revision":3,"turn_log_offset":0,"covered":%s}|}
    (String.make 32 'a') (String.make 64 'a') covered_text
;;

let committed_text =
  Printf.sprintf
    {|{"line":"committed","seq":2,"at":200.0,"basis":"%s","after":"%s","revision":4,"cause":{"kind":"adopt","by":"operator-1","observed":"%s"},"effects":{"added":[],"touched":[],"removed":[],"not_applied":[],"sources":[]},"turn_log":"%s","turn_log_offset":512,"covers_through":{"kind":"through","line":256,"within":{"kind":"item","store":"agent_core","at":3}},"covered":%s,"working_state":"checking the port"}|}
    (String.make 64 'a') (String.make 64 'b') (String.make 64 'b') (String.make 32 'a')
    covered_text
;;

let member name json = Yojson.Safe.Util.member name json
let part names line = List.fold_left (fun json name -> member name json) (Codec.to_json line) names
let part_text names line = Yojson.Safe.to_string (part names line)

(* A renamed field or token fails here. *)
let test_pinned_text () =
  check string "started" started_text (text started);
  check string "committed" committed_text (text (committed ()));
  check string "nothing read yet" {|{"kind":"before_first"}|}
    (part_text [ "covers_through" ] (committed ~covers_through:Log.Before_first ()));
  check string "a whole unit" {|{"kind":"through","line":0,"within":{"kind":"whole"}}|}
    (part_text [ "covers_through" ]
       (committed ~covers_through:(Log.Through { line = 0; within = Whole }) ()));
  check string "no working state" "null"
    (part_text [ "working_state" ] (committed ~working_state:None ()));
  check string "a retraction by the keeper"
    (Printf.sprintf
       {|{"kind":"direct","by":{"kind":"keeper"},"trace":"turn","write":{"kind":"retract","id":"%s","reason":"the port moved"}}|}
       (id port))
    (part_text [ "cause" ]
       (committed
          ~cause:(direct (Direct.Retract { id = id port; reason = "the port moved" }))
          ()));
  check string "a write by an operator" {|{"kind":"operator","name":"operator-1"}|}
    (part_text [ "cause"; "by" ]
       (committed
          ~cause:
            (direct ~by:(Effects.Operator "operator-1")
               (Direct.Retract { id = id port; reason = "wrong" }))
          ()));
  let write_kind write =
    part_text [ "cause"; "write"; "kind" ] (committed ~cause:(direct write) ())
  in
  check string "remember" {|"remember"|}
    (write_kind
       (Direct.Remember { claim = port.claim; category = Types.Constraint; basis = transcript }));
  check string "supersede" {|"supersede"|}
    (write_kind
       (Direct.Supersede
          { old = id port; claim = owner.claim; category = Types.Constraint; basis = transcript }));
  let effects = part [ "effects" ] (committed ~effects:full_effects ()) in
  check (list string) "the removals"
    [ {|{"kind":"dropped","reason":"no longer true"}|}
    ; Printf.sprintf {|{"kind":"merged_into","into":"%s"}|} (id owner)
    ; Printf.sprintf {|{"kind":"revised_into","into":"%s"}|} (id owner)
    ; Printf.sprintf {|{"kind":"superseded_by","by":"%s"}|} (id owner)
    ; {|{"kind":"retracted","by":{"kind":"keeper"},"reason":"the port moved"}|}
    ; {|{"kind":"retracted","by":{"kind":"operator","name":"operator-1"},"reason":"wrong"}|}
    ; Printf.sprintf {|{"kind":"support_lost","missing":["%s","%s"]}|} (id port) (id owner)
    ]
    (List.map
       (fun removed -> Yojson.Safe.to_string (member "removal" removed))
       (Yojson.Safe.Util.to_list (member "removed" effects)));
  check (list string) "why an op was left out"
    [ {|{"kind":"unknown_ref"}|}
    ; {|{"kind":"ref_used_twice"}|}
    ; {|{"kind":"source_outside_question"}|}
    ; {|{"kind":"removed_during_flight","seq":7}|}
    ; {|{"kind":"not_valid_alone"}|}
    ; {|{"kind":"not_valid_in_room"}|}
    ; {|{"kind":"successor_unsupported"}|}
    ]
    (List.map
       (fun left_out -> Yojson.Safe.to_string (member "why" left_out))
       (Yojson.Safe.Util.to_list (member "not_applied" effects)));
  check (list string) "the op number and the claim it carried"
    [ {|0|}; {|"the probe runs every minute"|}; {|1|}; {|null|} ]
    (List.concat_map
       (fun left_out ->
          [ Yojson.Safe.to_string (member "op" left_out)
          ; (match member "stated" left_out with
             | `Null -> "null"
             | stated -> Yojson.Safe.to_string (member "claim" stated))
          ])
       (List.filteri
          (fun index (_ : Yojson.Safe.t) -> index < 2)
          (Yojson.Safe.Util.to_list (member "not_applied" effects))));
  check string "where a fact was read"
    (Printf.sprintf {|[{"fact":"%s","lines":[0,256]},{"fact":"%s","lines":[]}]|} (id owner)
       (id rests))
    (Yojson.Safe.to_string (member "sources" effects));
  check string "the touched facts"
    (Printf.sprintf {|["%s"]|} (id port))
    (Yojson.Safe.to_string (member "touched" effects));
  check string "an answer"
    (Printf.sprintf
       {|{"kind":"read","question":{"front":"%s","back":"%s"},"shown":{"kind":"memory"},"slot":"claude_code.fast","trace":"trace-2","missing":[]}|}
       (String.make 32 'c') (String.make 32 'd'))
    (part_text [ "cause" ] (committed ~cause:(read ~missing:[] ()) ()));
  check string "a question of the item alone, whose answer kept the working state"
    {|{"kind":"item_alone","working_state":"untouched"}|}
    (part_text [ "cause"; "shown" ] (committed ~cause:(read ~shown:(Item_alone Untouched) ()) ()));
  check string "a question of the item alone, whose answer tried to replace it"
    {|{"kind":"item_alone","working_state":"not_valid_alone"}|}
    (part_text [ "cause"; "shown" ]
       (committed ~cause:(read ~shown:(Item_alone Not_valid_alone) ()) ()));
  check string "an answer to the question that makes room"
    (Printf.sprintf
       {|{"kind":"make_room","question":{"front":"%s","back":"%s"},"slot":"claude_code.fast","trace":"trace-2"}|}
       (String.make 32 'c') (String.make 32 'd'))
    (part_text [ "cause" ] (committed ~cause:make_room ()));
  check string "every part a unit can miss"
    (Printf.sprintf
       {|[{"line":120,"parts":[{"kind":"bundle","slice":{"bundle":"%s","skip":0,"take":2}},{"kind":"history_bytes","from":0,"until":10},{"kind":"internal_bytes","from":10,"until":20},{"kind":"chat_bytes","from":0,"until":64},{"kind":"external_rows","from":1,"until":3},{"kind":"undecodable_history_line","offset":10},{"kind":"undecodable_internal_line","offset":20},{"kind":"undecodable_external_row","row":3}]}]|}
       (String.make 64 'c'))
    (part_text [ "cause"; "missing" ] (committed ~cause:(read ()) ()));
  check string "a skip past content that is not there"
    {|{"kind":"skip","hole":{"kind":"content_missing","missing":[{"line":120,"parts":[{"kind":"chat_bytes","from":0,"until":64}]}]}}|}
    (part_text [ "cause" ]
       (committed
          ~cause:
            (Log.Skip
               { hole = Content_missing [ { line = 120; parts = [ Chat_bytes { from = 0; until = 64 } ] } ] })
          ()));
  check string "a skip past a span no unit holds"
    (Printf.sprintf {|{"kind":"skip","hole":{"kind":"unknown_span","before":%s,"after":%s}}|}
       covered_text reset_after_text)
    (part_text [ "cause" ] (committed ~cause:unknown_span ()));
  check string "a skip past an item no slot takes even alone"
    {|{"kind":"skip","hole":{"kind":"item_exceeds_window","missing":[{"line":120,"parts":[{"kind":"chat_bytes","from":0,"until":64}]}]}}|}
    (part_text [ "cause" ]
       (committed
          ~cause:
            (Log.Skip
               { hole =
                   Item_exceeds_window
                     [ { line = 120; parts = [ Chat_bytes { from = 0; until = 64 } ] } ]
               })
          ()));
  check string "an operator's restart on another turn log"
    (Printf.sprintf {|{"kind":"skip","hole":{"kind":"turn_log_replaced","from":"%s","to":"%s"}}|}
       (String.make 32 'a') (String.make 32 'b'))
    (part_text [ "cause" ] (committed ~cause:turn_log_replaced ()));
  check string "an operator's restart at an offset the file does not hold"
    {|{"kind":"skip","hole":{"kind":"position_lost","offset":4096,"length":512}}|}
    (part_text [ "cause" ] (committed ~cause:position_lost ()));
  check string "an operator's skip of a line that does not read"
    (Printf.sprintf {|{"kind":"skip","hole":{"kind":"line_unreadable","offset":240,"sha":"%s"}}|}
       (String.make 64 'e'))
    (part_text [ "cause" ] (committed ~cause:line_unreadable ()));
  check string "an operator's skip of the head item"
    {|{"kind":"skip","hole":{"kind":"operator_skipped","by":"operator-1","missing":[{"line":120,"parts":[{"kind":"chat_bytes","from":0,"until":64}]}]}}|}
    (part_text [ "cause" ]
       (committed
          ~cause:
            (Log.Skip
               { hole =
                   Operator_skipped
                     { by = "operator-1"
                     ; missing = [ { line = 120; parts = [ Chat_bytes { from = 0; until = 64 } ] } ]
                     }
               })
          ()))
;;

let replace_once ~old ~by source =
  let replaced = String_util.replace_substring ~needle:old ~by source in
  if String.equal replaced source then failf "the line does not hold %s" old else replaced
;;

let expect_rejected label ~path ~reason json_text =
  match Codec.of_json (Yojson.Safe.from_string json_text) with
  | Ok (_ : Log.line) -> failf "%s: accepted" label
  | Error error ->
    check string label
      (Types.wire_error_to_string { path; reason })
      (Types.wire_error_to_string error)
;;

let test_rejections () =
  let full = text (committed ~effects:full_effects ()) in
  let retract =
    text
      (committed
         ~cause:(direct (Direct.Retract { id = id port; reason = "the port moved" }))
         ())
  in
  expect_rejected "not an object" ~path:[] ~reason:Expected_object "[]";
  expect_rejected "an unknown line" ~path:[ Wire_field "line" ] ~reason:(Unknown_token "ended")
    (replace_once ~old:{|"started"|} ~by:{|"ended"|} started_text);
  expect_rejected "an extra field" ~path:[]
    ~reason:(Field_set_mismatch { missing = []; unexpected = [ "note" ] })
    (replace_once ~old:{|{"line"|} ~by:{|{"note":"x","line"|} started_text);
  expect_rejected "a commit without its working state" ~path:[]
    ~reason:(Field_set_mismatch { missing = [ "working_state" ]; unexpected = [] })
    (replace_once ~old:{|,"working_state":"checking the port"|} ~by:"" committed_text);
  expect_rejected "a turn log id that is not 32 hexadecimal characters"
    ~path:[ Wire_field "turn_log" ] ~reason:(Unknown_token "abc")
    (replace_once ~old:(Printf.sprintf {|"turn_log":"%s"|} (String.make 32 'a'))
       ~by:{|"turn_log":"abc"|} started_text);
  expect_rejected "a snapshot that is not a digest" ~path:[ Wire_field "snapshot" ]
    ~reason:(Unknown_token "abc")
    (replace_once ~old:(Printf.sprintf {|"snapshot":"%s"|} (String.make 64 'a'))
       ~by:{|"snapshot":"abc"|} started_text);
  (* The JSON reader takes these two words as numbers. *)
  expect_rejected "a started line whose time is not a number" ~path:[ Wire_field "at" ]
    ~reason:Not_finite
    (replace_once ~old:{|"at":100.0|} ~by:{|"at":NaN|} started_text);
  expect_rejected "a commit whose time is not finite" ~path:[ Wire_field "at" ]
    ~reason:Not_finite
    (replace_once ~old:{|"at":200.0|} ~by:{|"at":Infinity|} committed_text);
  expect_rejected "a negative sequence number" ~path:[ Wire_field "seq" ] ~reason:Negative
    (replace_once ~old:{|"seq":2|} ~by:{|"seq":-1|} committed_text);
  expect_rejected "a negative offset" ~path:[ Wire_field "turn_log_offset" ] ~reason:Negative
    (replace_once ~old:{|"turn_log_offset":512|} ~by:{|"turn_log_offset":-1|} committed_text);
  expect_rejected "a mark without a store" ~path:[ Wire_field "covered" ]
    ~reason:(Field_set_mismatch { missing = [ "external_rows" ]; unexpected = [] })
    (replace_once ~old:{|,"external_rows":2|} ~by:"" started_text);
  expect_rejected "an unknown cause"
    ~path:[ Wire_field "cause"; Wire_field "kind" ]
    ~reason:(Unknown_token "guess")
    (replace_once ~old:{|"kind":"adopt"|} ~by:{|"kind":"guess"|} committed_text);
  expect_rejected "an adoption with a field of another cause" ~path:[ Wire_field "cause" ]
    ~reason:(Field_set_mismatch { missing = []; unexpected = [ "write" ] })
    (replace_once ~old:{|"kind":"adopt",|} ~by:{|"kind":"adopt","write":null,|} committed_text);
  expect_rejected "an item before the first"
    ~path:[ Wire_field "covers_through"; Wire_field "within"; Wire_field "at" ]
    ~reason:Negative
    (replace_once ~old:{|"at":3|} ~by:{|"at":-1|} committed_text);
  expect_rejected "a working state that is not text" ~path:[ Wire_field "working_state" ]
    ~reason:Expected_string
    (replace_once ~old:{|"working_state":"checking the port"|} ~by:{|"working_state":7|}
       committed_text);
  expect_rejected "a passed line without the hash of its bytes"
    ~path:[ Wire_field "cause"; Wire_field "hole" ]
    ~reason:(Field_set_mismatch { missing = [ "sha" ]; unexpected = [] })
    (replace_once ~old:(Printf.sprintf {|,"sha":"%s"|} (String.make 64 'e')) ~by:""
       (text (committed ~cause:line_unreadable ())));
  expect_rejected "a retraction of something that is not a Memory id"
    ~path:[ Wire_field "cause"; Wire_field "write"; Wire_field "id" ]
    ~reason:(Not_a_memory_id "m3")
    (replace_once ~old:(Printf.sprintf {|"id":"%s"|} (id port)) ~by:{|"id":"m3"|} retract);
  expect_rejected "an unknown writer"
    ~path:[ Wire_field "cause"; Wire_field "by"; Wire_field "kind" ]
    ~reason:(Unknown_token "librarian")
    (replace_once ~old:{|"by":{"kind":"keeper"},"trace"|}
       ~by:{|"by":{"kind":"librarian"},"trace"|} retract);
  expect_rejected "a direct write without its trace" ~path:[ Wire_field "cause" ]
    ~reason:(Field_set_mismatch { missing = [ "trace" ]; unexpected = [] })
    (replace_once ~old:{|"trace":"turn",|} ~by:"" retract);
  expect_rejected "a touched fact that is not a Memory id"
    ~path:[ Wire_field "effects"; Wire_field "touched"; Wire_index 0 ]
    ~reason:(Not_a_memory_id "m1")
    (replace_once ~old:(Printf.sprintf {|"touched":["%s"]|} (id port))
       ~by:{|"touched":["m1"]|} full);
  expect_rejected "an unknown removal"
    ~path:
      [ Wire_field "effects"
      ; Wire_field "removed"
      ; Wire_index 0
      ; Wire_field "removal"
      ; Wire_field "kind"
      ]
    ~reason:(Unknown_token "forgotten")
    (replace_once ~old:{|"kind":"dropped"|} ~by:{|"kind":"forgotten"|} full);
  expect_rejected "a reason an op was left out that carries what it does not have"
    ~path:[ Wire_field "effects"; Wire_field "not_applied"; Wire_index 0; Wire_field "why" ]
    ~reason:(Field_set_mismatch { missing = []; unexpected = [ "seq" ] })
    (replace_once ~old:{|{"kind":"unknown_ref"}|} ~by:{|{"kind":"unknown_ref","seq":1}|} full);
  expect_rejected "a unit line before the file starts"
    ~path:
      [ Wire_field "effects"
      ; Wire_field "sources"
      ; Wire_index 0
      ; Wire_field "lines"
      ; Wire_index 1
      ]
    ~reason:Negative
    (replace_once ~old:{|"lines":[0,256]|} ~by:{|"lines":[0,-1]|} full)
;;

let () =
  run "librarian_log"
    [ ( "codec"
      , [ test_case "every line reads back" `Quick test_round_trip
        ; test_case "the shape as text" `Quick test_pinned_text
        ; test_case "what is refused" `Quick test_rejections
        ] )
    ]
;;
