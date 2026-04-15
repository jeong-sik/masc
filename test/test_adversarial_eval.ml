(** test_adversarial_eval.ml — Tests for fresh-context adversarial evaluator.
    Includes red-line enforcement tests per RFC #3475. *)

open Masc_mcp

(* --- Red line enforcement tests --- *)

let test_classify_readme () =
  Alcotest.(check bool) "README.md is banned" true
    (Option.is_some (Adversarial_eval.classify_path "README.md"));
  Alcotest.(check bool) "readme.txt is banned" true
    (Option.is_some (Adversarial_eval.classify_path "readme.txt"))

let test_classify_design_doc () =
  Alcotest.(check bool) "DESIGN.md is banned" true
    (Option.is_some (Adversarial_eval.classify_path "DESIGN.md"));
  Alcotest.(check bool) "architecture.md is banned" true
    (Option.is_some (Adversarial_eval.classify_path "architecture.md"));
  Alcotest.(check bool) "ADR-001.md is banned" true
    (Option.is_some (Adversarial_eval.classify_path "ADR-001.md"));
  Alcotest.(check bool) "docs/design/... is banned" true
    (Option.is_some
       (Adversarial_eval.classify_path
          "docs/design/contract-driven-agent-loop-rfc.md"));
  Alcotest.(check bool) "docs/spec/... is banned" true
    (Option.is_some
       (Adversarial_eval.classify_path "docs/spec/13-oas-integration.md"));
  Alcotest.(check bool) "rfc doc outside docs/ is banned" true
    (Option.is_some
       (Adversarial_eval.classify_path "tmp/contract-driven-agent-loop-rfc.md"));
  Alcotest.(check bool) "architecture doc outside docs/ is banned" true
    (Option.is_some
       (Adversarial_eval.classify_path "notes/system-architecture.md"))

let test_classify_history () =
  Alcotest.(check bool) "governance_v2.json is banned" true
    (Option.is_some (Adversarial_eval.classify_path "governance_v2.json"));
  Alcotest.(check bool) "session_log.jsonl is banned" true
    (Option.is_some (Adversarial_eval.classify_path "session_log.jsonl"));
  Alcotest.(check bool) "retrospective.json is banned" true
    (Option.is_some (Adversarial_eval.classify_path "retrospective.json"));
  Alcotest.(check bool) "room-task-history path is banned" true
    (Option.is_some
       (Adversarial_eval.classify_path "memory/room-task-history.jsonl"))

let test_classify_allowed () =
  Alcotest.(check bool) "module.ml is allowed" true
    (Option.is_none (Adversarial_eval.classify_path "module.ml"));
  Alcotest.(check bool) "module.mli is allowed" true
    (Option.is_none (Adversarial_eval.classify_path "module.mli"));
  Alcotest.(check bool) "test_foo.ml is allowed" true
    (Option.is_none (Adversarial_eval.classify_path "test_foo.ml"));
  Alcotest.(check bool) "spec_decoder.ml is allowed" true
    (Option.is_none (Adversarial_eval.classify_path "lib/spec_decoder.ml"));
  Alcotest.(check bool) "governance source file is allowed" true
    (Option.is_none (Adversarial_eval.classify_path "lib/governance_pipeline.ml"));
  Alcotest.(check bool) "room history source file is allowed" true
    (Option.is_none (Adversarial_eval.classify_path "lib/room_history_parser.ml"))

let test_validate_clean_inputs () =
  let inputs =
    Adversarial_eval.[
      Diff "--- a/lib/foo.ml\n+++ b/lib/foo.ml\n@@ ...\n+let x = 1";
      Changed_file { path = "lib/foo.ml"; content = "let x = 1" };
      Type_signature { module_name = "Foo"; signature = "val x : int" };
      Interface_contract { path = "lib/foo.mli"; content = "val x : int" };
    ]
  in
  match Adversarial_eval.validate_inputs inputs with
  | Ok _ -> ()
  | Error (path, _) -> Alcotest.fail (Printf.sprintf "unexpected rejection: %s" path)

let test_validate_rejects_readme () =
  let inputs =
    Adversarial_eval.[
      Changed_file { path = "README.md"; content = "# Project" };
    ]
  in
  match Adversarial_eval.validate_inputs inputs with
  | Error (_, Adversarial_eval.Readme) -> ()
  | Error (_, _) -> Alcotest.fail "wrong rejection kind"
  | Ok _ -> Alcotest.fail "should reject README"

let test_validate_rejects_design_doc () =
  let inputs =
    Adversarial_eval.[
      Interface_contract
        {
          path = "docs/design/contract-driven-agent-loop-rfc.md";
          content = "...";
        };
    ]
  in
  match Adversarial_eval.validate_inputs inputs with
  | Error (_, Adversarial_eval.Design_doc) -> ()
  | Error (_, _) -> Alcotest.fail "wrong rejection kind"
  | Ok _ -> Alcotest.fail "should reject design doc"

let test_validate_rejects_room_history_path () =
  let inputs =
    Adversarial_eval.[
      Changed_file
        { path = "memory/room-task-history.jsonl"; content = "{}\n" };
    ]
  in
  match Adversarial_eval.validate_inputs inputs with
  | Error (_, Adversarial_eval.Coord_history) -> ()
  | Error (_, _) -> Alcotest.fail "wrong rejection kind"
  | Ok _ -> Alcotest.fail "should reject room history"

(* --- Structural check tests --- *)

let test_large_diff_warning () =
  let big_diff = String.concat "\n" (List.init 600 (fun i -> Printf.sprintf "+line %d" i)) in
  let ctx =
    Adversarial_eval.create_context ~session_id:"test"
      ~inputs:[ Diff big_diff ]
  in
  let result = Adversarial_eval.evaluate ctx in
  Alcotest.(check bool) "has scope warning" true
    (List.exists
       (fun (f : Adversarial_eval.advisory_finding) ->
         String.equal f.category "scope")
       result.findings)

let test_small_diff_no_warning () =
  let small_diff = "+let x = 1\n+let y = 2" in
  let ctx =
    Adversarial_eval.create_context ~session_id:"test"
      ~inputs:[ Diff small_diff ]
  in
  let result = Adversarial_eval.evaluate ctx in
  Alcotest.(check bool) "no scope warning" false
    (List.exists
       (fun (f : Adversarial_eval.advisory_finding) ->
         String.equal f.category "scope")
       result.findings)

let test_unsafe_pattern_detection () =
  let ctx =
    Adversarial_eval.create_context ~session_id:"test"
      ~inputs:[
        Changed_file {
          path = "lib/hack.ml";
          content = "let x = Obj.magic 42\nlet y = ignore (dangerous_call ())";
        };
      ]
  in
  let result = Adversarial_eval.evaluate ctx in
  let safety_findings =
    List.filter
      (fun (f : Adversarial_eval.advisory_finding) ->
        String.equal f.category "safety")
      result.findings
  in
  Alcotest.(check bool) "found unsafe patterns" true (List.length safety_findings >= 2)

let test_missing_test_warning () =
  let ctx =
    Adversarial_eval.create_context ~session_id:"test"
      ~inputs:[
        Changed_file { path = "lib/new_module.ml"; content = "let f () = ()" };
      ]
  in
  let result = Adversarial_eval.evaluate ctx in
  Alcotest.(check bool) "has testing warning" true
    (List.exists
       (fun (f : Adversarial_eval.advisory_finding) ->
         String.equal f.category "testing")
       result.findings)

let test_with_test_file_no_warning () =
  let ctx =
    Adversarial_eval.create_context ~session_id:"test"
      ~inputs:[
        Changed_file { path = "lib/module.ml"; content = "let f () = ()" };
        Changed_file { path = "test/test_module.ml"; content = "let () = ()" };
      ]
  in
  let result = Adversarial_eval.evaluate ctx in
  Alcotest.(check bool) "no testing warning" false
    (List.exists
       (fun (f : Adversarial_eval.advisory_finding) ->
         String.equal f.category "testing")
       result.findings)

(* --- Advisory flag test --- *)

let test_always_advisory () =
  let ctx =
    Adversarial_eval.create_context ~session_id:"test" ~inputs:[]
  in
  let result = Adversarial_eval.evaluate ctx in
  Alcotest.(check bool) "is advisory" true result.is_advisory

(* --- JSON serialization --- *)

let test_result_to_yojson () =
  let ctx =
    Adversarial_eval.create_context ~session_id:"test"
      ~inputs:[ Diff "+line 1" ]
  in
  let result = Adversarial_eval.evaluate ctx in
  let json = Adversarial_eval.result_to_yojson result in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "is_advisory in json" true
    (json |> member "is_advisory" |> to_bool);
  Alcotest.(check int) "input_count" 1
    (json |> member "input_count" |> to_int)

(* --- Test suite --- *)

let () =
  Alcotest.run "adversarial_eval"
    [
      ( "red_line",
        [
          Alcotest.test_case "classify readme" `Quick test_classify_readme;
          Alcotest.test_case "classify design doc" `Quick test_classify_design_doc;
          Alcotest.test_case "classify history" `Quick test_classify_history;
          Alcotest.test_case "classify allowed" `Quick test_classify_allowed;
          Alcotest.test_case "validate clean" `Quick test_validate_clean_inputs;
          Alcotest.test_case "reject readme" `Quick test_validate_rejects_readme;
          Alcotest.test_case "reject design doc" `Quick test_validate_rejects_design_doc;
          Alcotest.test_case "reject room history path" `Quick
            test_validate_rejects_room_history_path;
        ] );
      ( "structural_checks",
        [
          Alcotest.test_case "large diff" `Quick test_large_diff_warning;
          Alcotest.test_case "small diff" `Quick test_small_diff_no_warning;
          Alcotest.test_case "unsafe patterns" `Quick test_unsafe_pattern_detection;
          Alcotest.test_case "missing tests" `Quick test_missing_test_warning;
          Alcotest.test_case "with test file" `Quick test_with_test_file_no_warning;
        ] );
      ( "advisory",
        [
          Alcotest.test_case "always advisory" `Quick test_always_advisory;
        ] );
      ( "serialization",
        [
          Alcotest.test_case "result to json" `Quick test_result_to_yojson;
        ] );
    ]
