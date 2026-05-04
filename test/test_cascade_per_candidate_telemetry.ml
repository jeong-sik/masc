(** test_cascade_per_candidate_telemetry — pin the JSON shape contract
    of the per-candidate cascade attempt telemetry payload emitted into
    [system_log_YYYY-MM-DD.jsonl] from
    [Oas_worker_cascade.cascade_attempt_terminal_event_json].

    The shape is the operator-facing contract: when a cascade exhausts
    all 14 candidates and [selected_model: null] lands in the decision
    record, the only way to find out *which* candidate failed *how* is
    to grep these field names in system_log. A silent field rename or
    drop would re-create the original "no idea why cascade exhausted"
    blackbox.

    Tests cover both terminal outcomes:
    - success: [latency_ms] is [Some _], [error] is [None]
    - failure: [error] is [Some _], [latency_ms] may be [Some _] or [None]

    Errors are recorded *verbatim* as [error_message]; classification
    happens externally per project memory rule "no string matching for
    classification" and the spirit of #12817. *)

open Masc_mcp

let assoc_string key json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String s) -> s
      | Some other ->
          Alcotest.failf "field %s expected `String, got %s" key
            (Yojson.Safe.to_string other)
      | None -> Alcotest.failf "field %s missing from %s" key
                  (Yojson.Safe.to_string json))
  | _ -> Alcotest.failf "expected `Assoc, got %s" (Yojson.Safe.to_string json)

let assoc_field key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let test_success_shape () =
  let json =
    Oas_worker_cascade.cascade_attempt_terminal_event_json
      ~model_id:"glm-coding:glm-4.7"
      ~model_label:(Some "glm-coding:glm-4.7") ~latency_ms:(Some 35921)
      ~error:None
  in
  Alcotest.(check string)
    "event tag" "cascade_attempt_terminal" (assoc_string "event" json);
  Alcotest.(check string)
    "model_id" "glm-coding:glm-4.7" (assoc_string "model_id" json);
  Alcotest.(check string) "outcome" "success" (assoc_string "outcome" json);
  (match assoc_field "latency_ms" json with
  | Some (`Int 35921) -> ()
  | other ->
      Alcotest.failf "latency_ms expected `Int 35921, got %s"
        (Yojson.Safe.to_string (Option.value other ~default:`Null)));
  (match assoc_field "error_message" json with
  | Some `Null -> ()
  | other ->
      Alcotest.failf "error_message expected `Null on success, got %s"
        (Yojson.Safe.to_string (Option.value other ~default:`Null)))

let test_failure_shape () =
  let json =
    Oas_worker_cascade.cascade_attempt_terminal_event_json
      ~model_id:"gemini_cli:gemini-2.5-pro" ~model_label:None
      ~latency_ms:(Some 1200)
      ~error:(Some "OAS budget timeout after 600.0s")
  in
  Alcotest.(check string)
    "event tag" "cascade_attempt_terminal" (assoc_string "event" json);
  Alcotest.(check string)
    "model_id" "gemini_cli:gemini-2.5-pro" (assoc_string "model_id" json);
  Alcotest.(check string) "outcome" "failure" (assoc_string "outcome" json);
  (match assoc_field "model_label" json with
  | Some `Null -> ()
  | other ->
      Alcotest.failf "model_label expected `Null when None passed, got %s"
        (Yojson.Safe.to_string (Option.value other ~default:`Null)));
  Alcotest.(check string)
    "error_message recorded verbatim — no classification at this layer"
    "OAS budget timeout after 600.0s"
    (assoc_string "error_message" json)

let test_failure_with_no_latency () =
  (* Provider that never started a request (e.g. CLI exit 1, DNS fail) —
     latency_ms is None, error is Some. Outcome must still be "failure". *)
  let json =
    Oas_worker_cascade.cascade_attempt_terminal_event_json
      ~model_id:"codex_cli:gpt-5.3-codex-spark"
      ~model_label:(Some "codex_cli:gpt-5.3-codex-spark") ~latency_ms:None
      ~error:(Some "rollout thread not found")
  in
  Alcotest.(check string) "outcome" "failure" (assoc_string "outcome" json);
  match assoc_field "latency_ms" json with
  | Some `Null -> ()
  | other ->
      Alcotest.failf "latency_ms expected `Null, got %s"
        (Yojson.Safe.to_string (Option.value other ~default:`Null))

let () =
  Alcotest.run "cascade_per_candidate_telemetry"
    [
      ( "shape",
        [
          Alcotest.test_case "success terminal shape" `Quick test_success_shape;
          Alcotest.test_case "failure terminal shape with latency" `Quick
            test_failure_shape;
          Alcotest.test_case "failure terminal shape no latency" `Quick
            test_failure_with_no_latency;
        ] );
    ]
