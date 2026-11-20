(* The scorer of Librarian answers, pinned by what it says about seven fixed
   answers to one question (RFC librarian-call-only-proposes §20, L1c).

   The seven are the ways a slot has been seen to answer: a sound answer, an
   answer that changes nothing, an answer in a code fence, an answer to
   another question, a merge that loses what it merged, a merge that keeps
   it, and an answer with one op that names a fact it was never shown. None
   of them is about the release owner, so each answer that is read keeps it.

   A change to the scorer changes the table at the end of this file, so it
   shows in review as a change to what a prompt is measured against. *)

open Alcotest
module Question_id = Masc.Librarian_question_id
module Scoring = Masc.Librarian_scoring
module Types = Masc.Keeper_memory_os_types

let front = String.make 32 'a'
let back = String.make 32 'b'

let question =
  match Question_id.of_halves ~front ~back with
  | Some id -> id
  | None -> fail "the test question id is not two halves"
;;

let held claim : Types.fact =
  { claim
  ; category = Types.Fact
  ; first_seen = 100.0
  ; last_seen = 100.0
  ; origin = { kind = Types.Authored; trace_id = "turn" }
  ; basis = Types.Observed Types.Transcript
  }
;;

let port = held "the server listens on port 8080"
let owner = held "the release owner is the platform team"
let probe = held "the probe calls port 8080 every minute"

(* The units said the port moved to 8935. *)
let case : Scoring.case =
  { name = "the port moved"
  ; question
  ; shown =
      Read
        (Range
           { memory =
               [ "m1", Types.memory_id port; "m2", Types.memory_id owner; "m3", Types.memory_id probe ]
           ; units = [ "u1", 10 ]
           })
  ; facts = [ port; owner; probe ]
  ; planted = [ "8935" ]
  ; must_keep =
      [ Types.memory_id port, [ "port" ]; Types.memory_id probe, [ "probe"; "every minute" ] ]
  ; must_remain = [ "platform team" ]
  }
;;

let answer ?(question = front) ops =
  Printf.sprintf {|{"question":"%s","question_end":"%s","working_state":null,"ops":[%s]}|}
    question back (String.concat "," ops)
;;

let stating claim =
  Printf.sprintf {|"claim":"%s","category":"fact","basis":{"kind":"observed"},"from":["u1"]|} claim
;;

let add claim = Printf.sprintf {|{"op":"add",%s}|} (stating claim)
let drop name = Printf.sprintf {|{"op":"drop","ref":"%s","reason":"stale"}|} name
let revise name claim = Printf.sprintf {|{"op":"revise","ref":"%s",%s}|} name (stating claim)

let merge names claim =
  Printf.sprintf {|{"op":"merge","refs":[%s],%s}|}
    (String.concat "," (List.map (Printf.sprintf "%S") names))
    (stating claim)
;;

let sound = answer [ revise "m1" "the server listens on port 8935" ]
let changes_nothing = answer []
let fenced = "```json\n" ^ sound ^ "\n```"
let another_question = answer ~question:back [ revise "m1" "the server listens on port 8935" ]
let lossy_merge = answer [ merge [ "m1"; "m3" ] "the server uses 8935" ]

let keeping_merge =
  answer
    [ merge [ "m1"; "m3" ] "the server listens on port 8935 and the probe calls it every minute" ]
;;

let one_unknown_name = answer [ drop "m9"; add "the port is now 8935" ]

let read label text =
  match Scoring.score case text with
  | Read read -> read
  | Thrown_away rejection ->
    failf "%s: thrown away as %s" label (Masc.Librarian_answer.rejection_kind rejection)
;;

let thrown_away label text =
  match Scoring.score case text with
  | Thrown_away rejection -> Masc.Librarian_answer.rejection_kind rejection
  | Read _ -> failf "%s: read" label
;;

let test_each_answer () =
  let sound = read "sound" sound in
  check bool "a sound answer changes Memory" true sound.changed;
  check int "and Memory holds what the units said" 1 sound.recovered;
  let nothing = read "changes nothing" changes_nothing in
  check bool "an empty answer changes nothing" false nothing.changed;
  check int "and recovers nothing" 0 nothing.recovered;
  check string "a code fence" "not_json" (thrown_away "fenced" fenced);
  check string "another question" "echo_mismatch" (thrown_away "echo" another_question);
  let lossy = read "lossy merge" lossy_merge in
  check (pair int int) "a merge that drops what it merged" (3, 0)
    (lossy.merge_expected, lossy.merge_kept);
  let keeping = read "keeping merge" keeping_merge in
  check (pair int int) "a merge that keeps it" (3, 3) (keeping.merge_expected, keeping.merge_kept);
  let unknown = read "one unknown name" one_unknown_name in
  check int "two ops" 2 unknown.ops;
  check int "one left out" 1 (List.length unknown.not_applied);
  check bool "the other op still changed Memory" true unknown.changed
;;

(* A revise is not a merge: the port number is meant to change, so what a
   revise drops is not counted against it. *)
let test_revise_is_not_scored_as_a_merge () =
  let revised = read "sound" sound in
  check (pair int int) "nothing expected of a revise" (0, 0)
    (revised.merge_expected, revised.merge_kept)
;;

(* Memory holds the port already. The units also said a second thing. Only
   the second is there to be recovered. *)
let test_a_token_memory_already_holds () =
  let known = held "the server listens on port 8935" in
  let case : Scoring.case =
    { name = "the port is known"
    ; question
    ; shown =
        Read
          (Range
             { memory = [ "m1", Types.memory_id known; "m2", Types.memory_id owner ]
             ; units = [ "u1", 10 ]
             })
    ; facts = [ known; owner ]
    ; planted = [ "8935"; "9000" ]
    ; must_keep = []
    ; must_remain = []
    }
  in
  let reading label text =
    match Scoring.score case text with
    | Read reading -> reading
    | Thrown_away rejection ->
      failf "%s: thrown away as %s" label (Masc.Librarian_answer.rejection_kind rejection)
  in
  let nothing = reading "changes nothing" changes_nothing in
  check (pair bool int) "an answer that does nothing recovers nothing" (false, 0)
    (nothing.changed, nothing.recovered);
  let adds_text = answer [ add "the admin port is 9000" ] in
  check int "what Memory did not hold is recovered" 1 (reading "adds" adds_text).recovered;
  let tally =
    Scoring.tally
      (List.map (fun text -> case, Scoring.score case text) [ changes_nothing; adds_text ])
  in
  check (pair int int) "the token Memory held is in neither number" (2, 1)
    (tally.planted, tally.recovered)
;;

(* The Keeper's turn was not shown the deploy rules, and it said it knew
   nothing of them. An answer that revises each rule into that saying leaves
   Memory with none of them. The units planted nothing and the ops are not
   merges, so the other numbers stay at 0: only what must remain shows the
   loss. *)
let test_an_answer_that_forgets_what_the_turn_was_not_shown () =
  let cutoff = held "deploys stop at 15:00 on Friday" in
  let approvals = held "a release needs two approvals" in
  let hotfix = held "a hotfix goes through the on-call lead" in
  let case : Scoring.case =
    { name = "the turn knew nothing"
    ; question
    ; shown =
        Read
          (Range
             { memory =
                 [ "m1", Types.memory_id cutoff
                 ; "m2", Types.memory_id approvals
                 ; "m3", Types.memory_id hotfix
                 ]
             ; units = [ "u1", 10 ]
             })
    ; facts = [ cutoff; approvals; hotfix ]
    ; planted = []
    ; must_keep = []
    ; must_remain = [ "15:00"; "two approvals"; "on-call lead" ]
    }
  in
  let reading label text =
    match Scoring.score case text with
    | Read reading -> reading
    | Thrown_away rejection ->
      failf "%s: thrown away as %s" label (Masc.Librarian_answer.rejection_kind rejection)
  in
  let nothing_known = "the provided context lacks information about the deploy rules" in
  let forgot =
    reading "forgetting"
      (answer [ revise "m1" nothing_known; revise "m2" nothing_known; revise "m3" nothing_known ])
  in
  check bool "the answer changed Memory" true forgot.changed;
  check (pair int int) "nothing to recover, no merge" (0, 0)
    (forgot.recovered, forgot.merge_expected);
  check (pair int int) "three must remain, none does" (3, 0)
    (forgot.remain_expected, forgot.remain_kept);
  let kept = reading "changes nothing" changes_nothing in
  check (pair int int) "an answer that changes nothing keeps all three" (3, 3)
    (kept.remain_expected, kept.remain_kept)
;;

let pinned =
  {|answers 7
thrown away 2
  echo_mismatch 1
  not_json 1
ops 5
ops left out 1
  unknown_ref 1
answers that changed Memory 4
planted 7, in Memory afterwards 4
merged away 6, kept by the merge 3
must remain 5, in Memory afterwards 5
|}
;;

let test_table_is_pinned () =
  let answers =
    [ sound
    ; changes_nothing
    ; fenced
    ; another_question
    ; lossy_merge
    ; keeping_merge
    ; one_unknown_name
    ]
  in
  check string "table" pinned
    (Scoring.tally_to_text
       (Scoring.tally (List.map (fun text -> case, Scoring.score case text) answers)))
;;

let () =
  run "librarian_scoring"
    [ ( "scorer"
      , [ test_case "each kind of answer" `Quick test_each_answer
        ; test_case "a revise is not a merge" `Quick test_revise_is_not_scored_as_a_merge
        ; test_case "a token Memory already holds" `Quick test_a_token_memory_already_holds
        ; test_case "an answer that forgets what the turn was not shown" `Quick
            test_an_answer_that_forgets_what_the_turn_was_not_shown
        ; test_case "the table of seven answers" `Quick test_table_is_pinned
        ] )
    ]
;;
