(* The absorb gate of a librarian pass (RFC-librarian-absorb-gate): the cut
   into statements, and which absorptions the gate lets through. The model is
   a table here; the entry point installs the client. *)

module Gate = Masc.Keeper_librarian_absorb_gate
module T = Masc.Typesafeai_types
module Types = Masc.Keeper_memory_os_types

let fact claim : Types.fact =
  Types.observed
    ~claim
    ~category:Types.Fact
    ~now:(Time_compat.now ())
    ~origin:{ kind = Types.Authored; trace_id = "" }
;;

let id = Types.memory_id

(* --- Statements: the same cut as the Python scorer of issue #37079. The
   expected lists were produced by that scorer (jev_coverage.statements) on
   these inputs, not by the function under test. --- *)

let test_statements_match_the_scorer () =
  Alcotest.(check (list string))
    "markup dropped; sentence ends, semicolon and em dash cut; short pieces carried"
    [ "배포는 매주 화요일 09:00 에 돈다."
    ; "다섯 분쯤 걸린다; 실패하면 rollback.sh 를 돌린다"
    ; "운영자에게 알린다. 한 줄 더: 이 규칙은 2026-09-01 부터다."
    ]
    (Gate.statements
       "배포는 **매주 화요일** 09:00 에 돈다. 다섯 분쯤 걸린다; 실패하면 `rollback.sh` 를 \
        돌린다 — 운영자에게 알린다.\n한 줄 더: 이 규칙은 2026-09-01 부터다.");
  Alcotest.(check (list string))
    "pieces under the minimum join until one is long enough; a short tail joins the last"
    [ "Short. Also short! Third one is long enough to stand alone as a statement? Yes it is." ]
    (Gate.statements
       "Short. Also short! Third one is long enough to stand alone as a statement? Yes it \
        is.");
  let sentence i = Printf.sprintf "문장 %d 은 충분히 길게 써서 스무 자를 넘긴다." i in
  let long =
    "다.다.다.\n\n" ^ String.concat " " (List.init 24 (fun i -> sentence (i + 1)))
  in
  Alcotest.(check (list string))
    "다. cuts without whitespace; more than the maximum is sampled evenly, not cut at the head"
    ([ "다. 다. 다. " ^ sentence 1 ]
     @ List.map sentence [ 2; 4; 5; 7; 8; 10; 11; 13; 14; 16; 17; 19; 20; 22; 23 ])
    (Gate.statements long);
  Alcotest.(check int) "at most the maximum" Gate.max_statements_per_memory
    (List.length (Gate.statements long));
  Alcotest.(check (list string)) "an empty memory has no statements" [] (Gate.statements "")
;;

(* --- Judgment --- *)

(* An evaluator that answers each statement from [noul_of], and counts the
   requests and the statements it was asked. *)
let table ~noul_of =
  let requests = ref 0 in
  let asked = ref [] in
  let evaluate ~state:_ ~questions =
    incr requests;
    let answers =
      List.map
        (fun (qid, question) ->
           match question with
           | T.Noul { T.instructions; _ } ->
             let statement =
               let prefix = "Statement:\n" in
               let at =
                 let rec find i =
                   if i + String.length prefix > String.length instructions
                   then failwith "no statement in the question"
                   else if String.sub instructions i (String.length prefix) = prefix
                   then i + String.length prefix
                   else find (i + 1)
                 in
                 find 0
               in
               String.sub instructions at (String.length instructions - at)
             in
             asked := statement :: !asked;
             qid, T.Noul_answer { T.noul = noul_of statement }
           | T.Choice _ | T.Score _ -> failwith "the gate asks noul questions only")
        questions
    in
    Ok { T.model = "jev-test"; answers; usage = None }
  in
  evaluate, requests, asked
;;

let sources = [ "the alpha service deploys every tuesday at nine in the morning";
                "the beta service ships on fridays and pages the operator on failure" ]
let merged = fact "alpha deploys tuesdays at nine; beta ships fridays and pages the operator"

let absorbed_into claim facts : Types.absorbed_statement list =
  List.map (fun (source : Types.fact) -> { Types.absorbed = id source; into = id claim }) facts
;;

let judged = function
  | Gate.Judged judged -> judged
  | Gate.Open reason -> Alcotest.fail ("gate open: " ^ reason)
;;

let test_every_statement_conveyed_absorbs_as_answered () =
  let facts = List.map fact sources in
  let absorbed = absorbed_into merged facts in
  let evaluate, requests, _ = table ~noul_of:(fun _ -> 0.9) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  Alcotest.(check int) "both absorptions go through" 2 (List.length j.absorbed);
  Alcotest.(check int) "none kept current" 0 (List.length j.left);
  Alcotest.(check int) "both counted as conveyed" 2 (List.length j.conveyed);
  Alcotest.(check int) "one request for the one absorbing claim" 1 !requests;
  Alcotest.(check int) "the same is reported" 1 j.requests
;;

let test_a_statement_not_conveyed_keeps_its_memory_current () =
  let facts = List.map fact sources in
  let absorbed = absorbed_into merged facts in
  let contains haystack needle =
    let n = String.length needle in
    let rec at i =
      i + n <= String.length haystack
      && (String.sub haystack i n = needle || at (i + 1))
    in
    at 0
  in
  let evaluate, _, _ =
    table ~noul_of:(fun statement ->
      (* The claim says nothing about paging the operator. *)
      if contains statement "pages the operator" then 0.2 else 0.95)
  in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  Alcotest.(check (list string))
    "only the alpha memory is absorbed"
    [ id (List.nth facts 0) ]
    (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) j.absorbed);
  (match j.left with
   | [ verdict ] ->
     Alcotest.(check string) "the beta memory stays current" (id (List.nth facts 1)) verdict.memory_id;
     Alcotest.(check string) "named with the claim it did not go into" (id merged) verdict.into;
     Alcotest.(check bool) "with at least one statement not conveyed" true (verdict.not_conveyed >= 1)
   | _ -> Alcotest.fail "expected one memory kept current")
;;

let test_the_boundary_is_inclusive () =
  let facts = [ fact (List.hd sources) ] in
  let absorbed = absorbed_into merged facts in
  let evaluate, _, _ = table ~noul_of:(fun _ -> Gate.conveyed_boundary) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  Alcotest.(check int) "exactly the boundary is conveyed" 1 (List.length j.absorbed)
;;

let test_the_model_not_answering_leaves_the_answer_as_it_came () =
  let facts = List.map fact sources in
  let absorbed = absorbed_into merged facts in
  let evaluate ~state:_ ~questions:_ = Error "HTTP 529" in
  (match Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed with
   | Gate.Open reason -> Alcotest.(check string) "the reason is carried" "HTTP 529" reason
   | Gate.Judged _ -> Alcotest.fail "expected the gate to stay open");
  let missing ~state:_ ~questions:_ = Ok { T.model = "jev-test"; answers = []; usage = None } in
  match Gate.judge ~evaluate:missing ~facts ~new_claims:[ merged ] ~absorbed with
  | Gate.Open _ -> ()
  | Gate.Judged _ -> Alcotest.fail "an answer without the questions is not a judgment"
;;

let test_an_absorption_the_pass_cannot_place_goes_through_unjudged () =
  let facts = [ fact (List.hd sources) ] in
  let stranger = fact "a memory the pass did not carry" in
  let absorbed = absorbed_into merged (facts @ [ stranger ]) in
  let evaluate, _, asked = table ~noul_of:(fun _ -> 0.0) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  Alcotest.(check (list string))
    "the stranger goes through, the judged memory is kept current"
    [ id stranger ]
    (List.map (fun (s : Types.absorbed_statement) -> s.absorbed) j.absorbed);
  Alcotest.(check int) "reported as unjudged" 1 (List.length j.unjudged);
  Alcotest.(check bool) "the stranger's text was never asked about" true
    (not (List.exists (fun s -> s = "a memory the pass did not carry") !asked))
;;

let test_statements_are_asked_in_bounded_requests () =
  let many =
    fact
      (String.concat " "
         (List.init 40 (fun i ->
            Printf.sprintf "statement number %d is long enough to stand on its own here." i)))
  in
  let facts = List.init 5 (fun i -> fact (Printf.sprintf "%s copy %d" many.Types.claim i)) in
  let absorbed = absorbed_into merged facts in
  let evaluate, requests, asked = table ~noul_of:(fun _ -> 1.0) in
  let j = judged (Gate.judge ~evaluate ~facts ~new_claims:[ merged ] ~absorbed) in
  let statements = List.length !asked in
  Alcotest.(check int) "every memory's statements were asked"
    (5 * Gate.max_statements_per_memory) statements;
  Alcotest.(check int) "in requests of at most the bound"
    ((statements + Gate.questions_per_request - 1) / Gate.questions_per_request)
    !requests;
  Alcotest.(check int) "all absorbed" 5 (List.length j.absorbed)
;;

let () =
  Alcotest.run
    "keeper_librarian_absorb_gate"
    [ ( "statements"
      , [ Alcotest.test_case "the cut matches the scorer" `Quick test_statements_match_the_scorer ] )
    ; ( "judgment"
      , [ Alcotest.test_case "every statement conveyed absorbs as answered" `Quick
            test_every_statement_conveyed_absorbs_as_answered
        ; Alcotest.test_case "a statement not conveyed keeps its memory current" `Quick
            test_a_statement_not_conveyed_keeps_its_memory_current
        ; Alcotest.test_case "the boundary is inclusive" `Quick test_the_boundary_is_inclusive
        ; Alcotest.test_case "the model not answering leaves the answer as it came" `Quick
            test_the_model_not_answering_leaves_the_answer_as_it_came
        ; Alcotest.test_case "an absorption the pass cannot place goes through unjudged" `Quick
            test_an_absorption_the_pass_cannot_place_goes_through_unjudged
        ; Alcotest.test_case "statements are asked in bounded requests" `Quick
            test_statements_are_asked_in_bounded_requests
        ] )
    ]
;;
