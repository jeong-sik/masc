(** Tests for Swiss Verdict JSON serialization (RFC-OAS-002 Phase 2). *)

open Agent_sdk

(* ── Helpers ──────────────────────────────────────────────────── *)

let get_field key json =
  match json with
  | `Assoc fields -> List.assoc key fields
  | _ -> failwith (Printf.sprintf "expected object, got %s" (Yojson.Safe.to_string json))
;;

let get_string key json =
  match get_field key json with
  | `String s -> s
  | j ->
    failwith
      (Printf.sprintf "expected string for %s, got %s" key (Yojson.Safe.to_string j))
;;

let get_bool key json =
  match get_field key json with
  | `Bool b -> b
  | j ->
    failwith (Printf.sprintf "expected bool for %s, got %s" key (Yojson.Safe.to_string j))
;;

let get_int key json =
  match get_field key json with
  | `Int i -> i
  | j ->
    failwith (Printf.sprintf "expected int for %s, got %s" key (Yojson.Safe.to_string j))
;;

let get_float key json =
  match get_field key json with
  | `Float f -> f
  | j ->
    failwith
      (Printf.sprintf "expected float for %s, got %s" key (Yojson.Safe.to_string j))
;;

let get_list key json =
  match get_field key json with
  | `List l -> l
  | j ->
    failwith (Printf.sprintf "expected list for %s, got %s" key (Yojson.Safe.to_string j))
;;

(* ── verdict_to_json ─────────────────────────────────────────── *)

let test_verdict_to_json_passed () =
  let v : Harness.verdict =
    { passed = true; score = Some 0.95; evidence = [ "e1"; "e2" ]; detail = Some "ok" }
  in
  let json = Harness.verdict_to_json v in
  Alcotest.(check bool) "passed" true (get_bool "passed" json);
  Alcotest.(check (float 0.001)) "score" 0.95 (get_float "score" json);
  Alcotest.(check int) "evidence count" 2 (List.length (get_list "evidence" json));
  Alcotest.(check string) "detail" "ok" (get_string "detail" json)
;;

let test_verdict_to_json_null_fields () =
  let v : Harness.verdict =
    { passed = false; score = None; evidence = []; detail = None }
  in
  let json = Harness.verdict_to_json v in
  Alcotest.(check bool) "passed" false (get_bool "passed" json);
  (match get_field "score" json with
   | `Null -> ()
   | _ -> Alcotest.fail "expected null score");
  Alcotest.(check int) "evidence count" 0 (List.length (get_list "evidence" json));
  match get_field "detail" json with
  | `Null -> ()
  | _ -> Alcotest.fail "expected null detail"
;;

(* ── swiss_verdict_to_json ───────────────────────────────────── *)

let test_swiss_verdict_to_json_schema_v1 () =
  let sv : string Harness.swiss_verdict =
    { all_passed = true
    ; layer_results =
        [ { layer_name = "layer_a"; layer_passed = true; layer_evidence = "ok" }
        ; { layer_name = "layer_b"; layer_passed = true; layer_evidence = "good" }
        ]
    ; coverage = 1.0
    }
  in
  let json = Harness.swiss_verdict_to_json sv in
  Alcotest.(check int) "schema_version" 1 (get_int "schema_version" json);
  Alcotest.(check bool) "all_passed" true (get_bool "all_passed" json);
  Alcotest.(check (float 0.001)) "coverage" 1.0 (get_float "coverage" json);
  let layers = get_list "layer_results" json in
  Alcotest.(check int) "layer count" 2 (List.length layers);
  let first = List.hd layers in
  Alcotest.(check string) "layer_name" "layer_a" (get_string "layer_name" first);
  Alcotest.(check bool) "passed" true (get_bool "passed" first);
  let evidence = get_list "evidence" first in
  Alcotest.(check int) "evidence count" 1 (List.length evidence)
;;

let test_swiss_verdict_to_json_partial_pass () =
  let sv : string Harness.swiss_verdict =
    { all_passed = false
    ; layer_results =
        [ { layer_name = "l1"; layer_passed = true; layer_evidence = "pass" }
        ; { layer_name = "l2"; layer_passed = false; layer_evidence = "fail" }
        ]
    ; coverage = 0.5
    }
  in
  let json = Harness.swiss_verdict_to_json sv in
  Alcotest.(check bool) "all_passed" false (get_bool "all_passed" json);
  Alcotest.(check (float 0.001)) "coverage" 0.5 (get_float "coverage" json)
;;

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Swiss Verdict JSON"
    [ ( "verdict_to_json"
      , [ Alcotest.test_case "passed verdict" `Quick test_verdict_to_json_passed
        ; Alcotest.test_case "null fields" `Quick test_verdict_to_json_null_fields
        ] )
    ; ( "swiss_verdict_to_json"
      , [ Alcotest.test_case "schema v1" `Quick test_swiss_verdict_to_json_schema_v1
        ; Alcotest.test_case "partial pass" `Quick test_swiss_verdict_to_json_partial_pass
        ] )
    ]
;;
