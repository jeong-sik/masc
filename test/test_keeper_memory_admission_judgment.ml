open Alcotest
module Judgment = Masc.Keeper_memory_admission_judgment
module Queue = Masc.Keeper_memory_admission_queue
module Types = Masc.Keeper_memory_os_types

let require = function Ok value -> value | Error detail -> fail detail
let fact claim : Types.fact =
  {claim; category=Types.Fact; first_seen=100.; last_seen=100.;
   origin={kind=Types.Authored; trace_id="candidate-fixture"};
   basis=Types.Observed Types.Transcript}

let with_batch f =
  let keepers_dir = Filename.temp_dir "admission-judgment-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree keepers_dir) (fun () ->
    List.iter (fun (request_id,claim) ->
      ignore (Queue.append ~keepers_dir ~keeper_id:"keeper" ~request_id (fact claim) |> require))
      ["one","Alpha failed on Monday."; "two","Alpha failed again on Monday.";
       "three","A transient debug print."; "four","Beta needs separate deployment credentials."];
    let batch = match Queue.read_pending ~keepers_dir ~keeper_id:"keeper" |> require with
      | Some batch -> batch | None -> fail "fixture candidates missing" in
    f batch)

let alpha = "Alpha deployments require operator approval."
let beta = "Beta deployments use separate credentials."
let memory = `Assoc ["new_claims",`List []; "dropped",`List [];
  "working_state",`Null; "working_contexts",`List []]
let row request_id outcome memory_claim = `Assoc
  ["request_id",`String request_id; "outcome",`String outcome;
   "memory_claim",memory_claim; "reason",`String "Keeper-relevant contextual judgment."]
let rows =
  [row "one" "incorporated" (`String alpha);
   row "two" "already_represented" (`String alpha);
   row "three" "not_durable" `Null;
   row "four" "incorporated" (`String beta)]
let envelope candidates = `Assoc ["memory",memory; "candidates",`List candidates; "change_support",`List []]
let field name value = function
  | `Assoc fields -> `Assoc (List.map (fun (key,prior) -> key, if key=name then value else prior) fields)
  | _ -> fail "fixture expected object"
let add name value = function
  | `Assoc fields -> `Assoc ((name,value)::fields)
  | _ -> fail "fixture expected object"
let refused label = function
  | Error _ -> () | Ok _ -> fail (label ^ " was accepted")

let test_complete_judgment_preserves_memory_and_references () = with_batch (fun batch ->
  let original, judgments, support = Judgment.unwrap ~batch (envelope (List.rev rows)) |> require in
  check bool "original Memory object passes through unchanged" true (original = memory);
  check (list string) "candidate results return in the authoritative input order"
    ["one";"two";"three";"four"]
    (List.map (fun (j : Judgment.judgment) -> j.request_id) judgments);
  (match List.map (fun (j : Judgment.judgment) -> j.outcome) judgments with
   | [Incorporated a; Already_represented b; Not_durable; Incorporated c] ->
     check (list string) "merged and retained destinations are exact references"
       [alpha;alpha;beta] [a;b;c]
   | _ -> fail "wrong typed candidate outcomes");
  Judgment.verify ~facts:[fact alpha;fact beta] judgments |> require;
  check (list string) "all settled requests are eligible for consumption"
    ["one";"two";"three";"four"] (Judgment.settled_requests judgments);
  check (list string) "empty support is preserved" [] support)

let test_candidate_coverage_and_strict_fields () = with_batch (fun batch ->
  List.iter (fun (label,json) ->
    Judgment.unwrap ~batch json |> refused label)
    ["missing candidate", envelope (List.tl rows);
     "duplicate candidate", envelope (List.hd rows :: rows);
     "unknown candidate", envelope (row "outsider" "not_durable" `Null :: List.tl rows);
     "extra wrapper field", add "claims" (`List []) (envelope rows);
     "duplicate wrapper field", add "memory" memory (envelope rows);
     "missing wrapper field", `Assoc ["memory",memory];
     "missing change support", `Assoc ["memory",memory; "candidates",`List rows];
     "nonarray support", field "change_support" `Null (envelope rows);
     "nonstrings in support", field "change_support" (`List [`Int 1]) (envelope rows);
     "nonobject Memory", field "memory" `Null (envelope rows);
     "nonarray candidates", field "candidates" `Null (envelope rows);
     "unknown outcome", envelope (field "outcome" (`String "mergeable") (List.hd rows) :: List.tl rows);
     "extra judgment field", envelope (add "confidence" (`Float 1.) (List.hd rows) :: List.tl rows);
     "duplicate judgment field", envelope (add "request_id" (`String "one") (List.hd rows) :: List.tl rows);
     "blank reason", envelope (field "reason" (`String " \n ") (List.hd rows) :: List.tl rows)])

let test_claim_requirements_and_final_selection () = with_batch (fun batch ->
  List.iter (fun (outcome,claim) ->
    Judgment.unwrap ~batch (envelope (row "one" outcome claim :: List.tl rows))
    |> refused ("invalid memory_claim for " ^ outcome))
    ["incorporated",`Null; "incorporated",`String " ";
     "already_represented",`Null; "already_represented",`String "";
     "not_durable",`String alpha; "deferred",`String alpha];
  let _, judgments, _ = Judgment.unwrap ~batch (envelope rows) |> require in
  Judgment.verify ~facts:[fact alpha] judgments |> refused "absent incorporated destination";
  let _, represented, _ = Judgment.unwrap ~batch
    (envelope (row "one" "not_durable" `Null :: List.tl rows)) |> require in
  Judgment.verify ~facts:[fact beta] represented |> refused "absent already-represented destination";
  Judgment.verify ~facts:[fact (alpha ^ " Different scope."); fact beta] judgments
    |> refused "similar wording is not the exact named final claim")

let test_partial_settlement_and_change_support () = with_batch (fun batch ->
  let response = envelope (List.take 3 rows @ [row "four" "deferred" `Null]) in
  let response = field "change_support" (`List [`String "one"]) response in
  let _, judgments, support = Judgment.unwrap ~batch response |> require in
  check (list string) "declared support survives decoding" ["one"] support;
  Judgment.verify ~facts:[fact alpha] judgments |> require;
  check (list string) "deferred Beta cannot block settled Alpha and transient input"
    ["one";"two";"three"] (Judgment.settled_requests judgments);
  let verify support claims changes = Judgment.verify_support ~new_claims:claims
    ~has_changes:changes ~change_support:support judgments in
  verify ["one"] [fact alpha] true |> require;
  verify ["two"] [] true |> require;
  verify [] [] false |> require;
  List.iter (fun (label,support) -> verify support [fact alpha] true |> refused label)
    ["unknown support",["outside"]; "duplicate support",["one";"one"];
     "deferred support",["four"]; "not-durable support",["three"];
     "mutation without support",[]];
  verify ["two"] [fact alpha] true |> refused "new claim supported only by already-represented outcome";
  verify ["one"] [fact beta] true |> refused "new claim not linked to its incorporated support";
  let all_deferred = List.map (fun id -> row id "deferred" `Null) ["one";"two";"three";"four"] in
  let _, deferred, _ = Judgment.unwrap ~batch (envelope all_deferred) |> require in
  check (list string) "all deferred consumes nothing" [] (Judgment.settled_requests deferred);
  Judgment.verify_support ~new_claims:[] ~has_changes:false ~change_support:[] deferred |> require;
  Judgment.verify_support ~new_claims:[fact alpha] ~has_changes:true ~change_support:[] deferred
    |> refused "all deferred cannot authorize a Memory mutation")

let test_structured_output_schema_accepts_the_envelope () = with_batch (fun batch ->
  let schema = Judgment.output_schema
      ~memory_schema:Masc.Keeper_structured_output_schema.librarian_current_output_schema in
  let accepts args = Result.is_ok (Masc.Tool_input_validation.validate
      ~schema ~name:"explicit_memory_admission" ~args ()) in
  check bool "strict output accepts a complete judgment envelope" true (accepts (envelope rows));
  List.iter (fun (label,args) -> check bool label false (accepts args))
    ["original Memory object alone is not the envelope",memory;
     "unknown outcome is not emitted",envelope (field "outcome" (`String "unknown") (List.hd rows) :: List.tl rows);
     "claim type remains string or null",envelope (field "memory_claim" (`Int 1) (List.hd rows) :: List.tl rows);
     "original Memory schema remains enforced",field "memory" (field "new_claims" (`String "invalid") memory) (envelope rows)];
  (* Tool-input validation checks types/enums recursively, but its
     additionalProperties check only covers the root object. The emitted
     schema still declares strict candidate objects; runtime unwrap is the
     authoritative local exact-field boundary for model responses. *)
  Judgment.unwrap ~batch
    (envelope (add "extra" `Null (List.hd rows) :: List.tl rows))
  |> refused "extra judgment field at the runtime admission boundary")

let () = run "explicit memory admission judgment"
  ["admission boundary",[
    test_case "complete judgments preserve Memory and final references" `Quick
      test_complete_judgment_preserves_memory_and_references;
    test_case "candidate coverage and strict fields" `Quick test_candidate_coverage_and_strict_fields;
    test_case "claim requirements and final destinations" `Quick test_claim_requirements_and_final_selection;
    test_case "partial settlement keeps deferred independent work out of change support" `Quick test_partial_settlement_and_change_support;
    test_case "structured output accepts the wrapped Memory answer" `Quick test_structured_output_schema_accepts_the_envelope]]
