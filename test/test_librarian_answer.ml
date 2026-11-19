(* The Librarian answer codec (RFC librarian-call-only-proposes §6.2): the
   wire shape the prompt asks for, and the four reasons a whole answer is
   thrown away. An op that names a fact or a unit the question never showed
   is not one of them, so those answers must decode. *)

open Alcotest
module Answer = Masc.Librarian_answer
module Question_id = Masc.Librarian_question_id
module Types = Masc.Keeper_memory_os_types

let front = "0123456789abcdef0123456789abcdef"
let back = "fedcba9876543210fedcba9876543210"

let asked =
  match Question_id.of_halves ~front ~back with
  | Some id -> id
  | None -> fail "the test question id is not two halves"
;;

let post = "p-0123456789abcdef0123456789abcdef"
let comment = "c-0123456789abcdef0123456789abcdef"

let board ?comment_id () =
  match Types.board_ref_of_ids ~post_id:post ~comment_id with
  | Ok board -> Types.Board board
  | Error error -> fail (Types.wire_error_to_string error)
;;

let new_fact ?(observation = Types.Transcript) ?(from_units = []) claim : Answer.new_fact =
  { claim; category = Types.Fact; observation; from_units }
;;

let every_op : Answer.op list =
  [ Add (new_fact ~from_units:[ "u1"; "u2" ] "the port is 8935")
  ; Add (new_fact ~observation:(board ()) "the board said so")
  ; Add (new_fact ~observation:(board ~comment_id:comment ()) "a comment said so")
  ; Drop { ref_ = "m2"; reason = "the build moved" }
  ; Merge { refs = [ "m1"; "m3" ]; into = new_fact "one sentence for both" }
  ; Revise { ref_ = "m4"; into = new_fact ~from_units:[ "u2" ] "the port is 8936" }
  ; Seen { ref_ = "m5"; from_units = [ "u1"; "u2" ] }
  ]
;;

let json_text answer = Yojson.Safe.to_string (Answer.to_json answer)

let decoded label = function
  | Ok answer -> answer
  | Error rejection -> failf "%s: rejected as %s" label (Answer.rejection_kind rejection)
;;

let test_round_trip () =
  List.iter
    (fun working_state ->
       let answer : Answer.t = { question = asked; ops = every_op; working_state } in
       let text = json_text answer in
       check string "decode (encode a) = a" text
         (json_text (decoded "round trip" (Answer.of_string ~asked text))))
    [ Answer.Keep; Answer.Set "waiting for the reviewer"; Answer.Set "" ]
;;

(* The shape is pinned as text, so a renamed field fails here and not only
   in a round trip that renames both directions together. *)
let golden =
  Printf.sprintf
    {|{"question":"%s","question_end":"%s","working_state":"next: rerun the probe","ops":[
{"op":"add","claim":"the port is 8935","category":"fact","basis":{"kind":"observed"},"from":["u1"]},
{"op":"add","claim":"a comment said so","category":"validated_approach","basis":{"kind":"observed","board":{"post_id":"%s","comment_id":"%s"}},"from":[]},
{"op":"drop","ref":"m2","reason":"the build moved"},
{"op":"merge","refs":["m1","m3"],"claim":"one sentence for both","category":"release_notes","basis":{"kind":"observed"},"from":[]},
{"op":"revise","ref":"m4","claim":"the port is 8936","category":"fact","basis":{"kind":"observed"},"from":["u2"]},
{"op":"seen","ref":"m5","from":["u1"]}]}|}
    front back post comment
;;

let test_golden () =
  let answer = decoded "golden" (Answer.of_string ~asked golden) in
  (match answer.working_state with
   | Set text -> check string "working state" "next: rerun the probe" text
   | Keep -> fail "working state was read as Keep");
  match answer.ops with
  | [ Add first; Add second; Drop dropped; Merge merged; Revise revised; Seen seen ] ->
    check string "add claim" "the port is 8935" first.claim;
    check (list string) "add units" [ "u1" ] first.from_units;
    check bool "add is read from the transcript" true (first.observation = Types.Transcript);
    check string "known category" "validated_approach"
      (Types.category_to_string second.category);
    check bool "board comment" true (second.observation = board ~comment_id:comment ());
    check string "drop ref" "m2" dropped.ref_;
    check string "drop reason" "the build moved" dropped.reason;
    check (list string) "merge refs" [ "m1"; "m3" ] merged.refs;
    check string "newly named category" "release_notes"
      (Types.category_to_string merged.into.category);
    check string "revise ref" "m4" revised.ref_;
    check string "revise claim" "the port is 8936" revised.into.claim;
    check string "seen ref" "m5" seen.ref_;
    check (list string) "seen units" [ "u1" ] seen.from_units
  | ops -> failf "expected six ops in order, got %d" (List.length ops)
;;

let document ?(question = front) ?(question_end = back) ops =
  Printf.sprintf {|{"question":"%s","question_end":"%s","working_state":null,"ops":[%s]}|}
    question question_end ops
;;

let add_with ?(claim = {|"c"|}) ?(category = {|"fact"|}) ?(basis = {|{"kind":"observed"}|})
  ?(from = "[]") ()
  =
  Printf.sprintf {|{"op":"add","claim":%s,"category":%s,"basis":%s,"from":%s}|} claim
    category basis from
;;

let test_names_are_kept_as_written () =
  let answer =
    decoded "unknown names"
      (Answer.of_string ~asked
         (document
            ({|{"op":"drop","ref":"m999","reason":"r"},{"op":"drop","ref":"banana","reason":"r"},|}
             ^ add_with ~from:{|["u404"]|} ())))
  in
  check int "all three ops decode" 3 (List.length answer.ops)
;;

let rejection label text =
  match Answer.of_string ~asked text with
  | Ok (_ : Answer.t) -> failf "%s: accepted" label
  | Error rejection -> rejection
;;

let expect_kind kind label text =
  check string label kind (Answer.rejection_kind (rejection label text))
;;

let expect_schema label ~path ~reason text =
  match rejection label text with
  | Schema_violation error ->
    check string label
      (Types.wire_error_to_string { path; reason })
      (Types.wire_error_to_string error)
  | (Not_json | Echo_mismatch | Empty_or_partial) as other ->
    failf "%s: rejected as %s" label (Answer.rejection_kind other)
;;

let test_whole_answer_rejections () =
  expect_kind "empty_or_partial" "empty text" "";
  expect_kind "empty_or_partial" "blank text" " \n\t ";
  expect_kind "not_json" "cut short" {|{"question":"|};
  expect_kind "not_json" "code fence" ("```json\n" ^ document "" ^ "\n```");
  expect_kind "not_json" "prose after the document" (document "" ^ "\nDone.");
  expect_kind "echo_mismatch" "front half of another question"
    (document ~question:back "");
  expect_kind "echo_mismatch" "back half missing its last character"
    (document ~question_end:(String.sub back 0 31) "");
  (* The echo is read before the ops: an answer to another question is
     reported as that, whatever else is wrong with it. *)
  expect_kind "echo_mismatch" "wrong echo and a malformed op"
    (document ~question:back {|{"op":"explode"}|});
  expect_schema "not an object" ~path:[] ~reason:Expected_object "[]";
  expect_schema "a field is missing" ~path:[]
    ~reason:(Field_set_mismatch { missing = [ "ops" ]; unexpected = [] })
    (Printf.sprintf {|{"question":"%s","question_end":"%s","working_state":null}|} front back);
  expect_schema "an extra field" ~path:[]
    ~reason:(Field_set_mismatch { missing = []; unexpected = [ "notes" ] })
    (Printf.sprintf
       {|{"question":"%s","question_end":"%s","working_state":null,"ops":[],"notes":"x"}|}
       front back);
  expect_schema "echo is not a string" ~path:[ Wire_field "question" ] ~reason:Expected_string
    (Printf.sprintf {|{"question":7,"question_end":"%s","working_state":null,"ops":[]}|} back);
  expect_schema "working state is a number" ~path:[ Wire_field "working_state" ]
    ~reason:Expected_string
    (Printf.sprintf {|{"question":"%s","question_end":"%s","working_state":3,"ops":[]}|} front
       back)
;;

let at_op index path = Types.Wire_field "ops" :: Types.Wire_index index :: path

let test_op_rejections () =
  expect_schema "unknown op" ~path:(at_op 0 [ Wire_field "op" ])
    ~reason:(Unknown_token "explode")
    (document {|{"op":"explode"}|});
  expect_schema "op is not an object" ~path:(at_op 1 []) ~reason:Expected_object
    (document (add_with () ^ {|,"drop m2"|}));
  expect_schema "drop without a reason" ~path:(at_op 0 [])
    ~reason:(Field_set_mismatch { missing = [ "reason" ]; unexpected = [] })
    (document {|{"op":"drop","ref":"m2"}|});
  expect_schema "blank reason" ~path:(at_op 0 [ Wire_field "reason" ]) ~reason:Blank_string
    (document {|{"op":"drop","ref":"m2","reason":"  "}|});
  expect_schema "blank claim" ~path:(at_op 0 [ Wire_field "claim" ]) ~reason:Blank_string
    (document (add_with ~claim:{|""|} ()));
  expect_schema "a reserved category" ~path:(at_op 0 [ Wire_field "category" ])
    ~reason:(Unknown_token "dropped")
    (document (add_with ~category:{|"dropped"|} ()));
  (* Only a Keeper's direct write makes a derived fact. *)
  expect_schema "a derived basis"
    ~path:(at_op 0 [ Wire_field "basis"; Wire_field "kind" ])
    ~reason:(Unknown_token "derived")
    (document
       (add_with
          ~basis:
            (Printf.sprintf
               {|{"kind":"derived","derivations":[{"rule_id":"r","premise_ids":["%s"]}]}|}
               (Types.memory_id_of_claim "premise"))
          ()));
  expect_schema "a unit name that is a number" ~path:(at_op 0 [ Wire_field "from"; Wire_index 1 ])
    ~reason:Expected_string
    (document (add_with ~from:{|["u1",2]|} ()));
  expect_schema "merge of nothing" ~path:(at_op 0 [ Wire_field "refs" ]) ~reason:Empty_list
    (document
       {|{"op":"merge","refs":[],"claim":"c","category":"fact","basis":{"kind":"observed"},"from":[]}|});
  expect_schema "merge names a fact twice" ~path:(at_op 0 [ Wire_field "refs" ])
    ~reason:(Duplicate_entry "m1")
    (document
       {|{"op":"merge","refs":["m1","m2","m1"],"claim":"c","category":"fact","basis":{"kind":"observed"},"from":[]}|});
  (* Seen again says where: a seen that names no unit is the question's own
     Memory read back. *)
  expect_schema "seen of no unit" ~path:(at_op 0 [ Wire_field "from" ]) ~reason:Empty_list
    (document {|{"op":"seen","ref":"m5","from":[]}|});
  expect_schema "seen does not copy the claim" ~path:(at_op 0 [])
    ~reason:(Field_set_mismatch { missing = []; unexpected = [ "claim" ] })
    (document {|{"op":"seen","ref":"m5","from":["u1"],"claim":"the port is 8935"}|});
  expect_schema "revise carries add's fields only" ~path:(at_op 0 [])
    ~reason:(Field_set_mismatch { missing = [ "ref" ]; unexpected = [ "refs" ] })
    (document
       {|{"op":"revise","refs":["m1"],"claim":"c","category":"fact","basis":{"kind":"observed"},"from":[]}|})
;;

let test_question_id_halves () =
  let accepted ~front ~back = Option.is_some (Question_id.of_halves ~front ~back) in
  check bool "two halves" true (accepted ~front ~back);
  check bool "a whole digest is not a half" false (accepted ~front:(front ^ back) ~back);
  check bool "uppercase" false (accepted ~front:(String.uppercase_ascii front) ~back);
  check bool "short" false (accepted ~front ~back:(String.sub back 0 31));
  check bool "not hexadecimal" false (accepted ~front:(String.make 32 'g') ~back)
;;

let () =
  run "librarian_answer"
    [ ( "codec"
      , [ test_case "round trip of every op" `Quick test_round_trip
        ; test_case "the wire shape as text" `Quick test_golden
        ; test_case "names the question never gave still decode" `Quick
            test_names_are_kept_as_written
        ] )
    ; ( "rejections"
      , [ test_case "whole answer" `Quick test_whole_answer_rejections
        ; test_case "one malformed op" `Quick test_op_rejections
        ] )
    ; "question id", [ test_case "halves" `Quick test_question_id_halves ]
    ]
;;
