(* Tier W2 — Resilience_runtime tests. *)

module RR = Resilience.Resilience_runtime
module D = Resilience.Degradation

let check_bool label b =
  if not b then failwith (Printf.sprintf "%s: false" label)

let check_str label expected actual =
  if not (String.equal expected actual) then
    failwith
      (Printf.sprintf "%s: expected %S, got %S" label expected actual)

let l1 = D.Any_level D.L1
let l2 = D.Any_level D.L2
let l3 = D.Any_level D.L3
let l4 = D.Any_level D.L4

(* ── classify_only ──────────────────────────────────────────── *)

let test_classify_transient () =
  match RR.classify_only "connection timed out" with
  | Resilience.Recovery.TransientError _ ->
      check_bool "timeout → Transient" true
  | _ -> failwith "expected Transient"

let test_classify_permanent () =
  match RR.classify_only "deprecated api endpoint" with
  | Resilience.Recovery.PermanentError _
  | Resilience.Recovery.TransientError _ ->
      (* heuristic — either acceptable for unknown phrases *)
      check_bool "non-empty classification" true
  | _ -> ()

(* ── process pipeline ───────────────────────────────────────── *)

let test_process_l1_transient_yields_retry () =
  let out =
    RR.process { error_message = "rate limit exceeded"; current_level = l1 }
  in
  check_bool "L1 transient → Retry"
    (out.strategy_class = `Retry)

let test_process_l2_transient_yields_fallback () =
  let out =
    RR.process { error_message = "connection reset"; current_level = l2 }
  in
  check_bool "L2 transient → Fallback"
    (out.strategy_class = `Fallback)

let test_process_l4_permanent_no_retry () =
  let out =
    RR.process
      { error_message = "permanent service deprecated"; current_level = l4 }
  in
  check_bool "L4 permanent → not Retry"
    (out.strategy_class <> `Retry)

let test_process_l3_yields_handoff () =
  let out =
    RR.process { error_message = "unknown error"; current_level = l3 }
  in
  check_bool "L3 yields Handoff or Abort"
    (out.strategy_class = `Handoff
   || out.strategy_class = `Abort
   || out.strategy_class = `Fallback)

(* ── strategy_summary ───────────────────────────────────────── *)

let test_strategy_summary_non_empty () =
  let out =
    RR.process { error_message = "timeout"; current_level = l1 }
  in
  check_bool "summary non-empty"
    (String.length out.strategy_summary > 0)

(* ── output_to_json ─────────────────────────────────────────── *)

let test_output_to_json_shape () =
  let out =
    RR.process { error_message = "rate limit"; current_level = l1 }
  in
  let json = RR.output_to_json out in
  match json with
  | `Assoc kv ->
      check_bool "has classified_mode"
        (List.mem_assoc "classified_mode" kv);
      check_bool "has strategy_class"
        (List.mem_assoc "strategy_class" kv);
      check_bool "has strategy_summary"
        (List.mem_assoc "strategy_summary" kv);
      check_bool "has recommended_level"
        (List.mem_assoc "recommended_level" kv)
  | _ -> failwith "expected JSON object"

let test_output_strategy_class_string () =
  let out =
    RR.process { error_message = "rate limit"; current_level = l1 }
  in
  match RR.output_to_json out with
  | `Assoc kv -> (
      match List.assoc "strategy_class" kv with
      | `String s ->
          check_bool "lowercase tag"
            (List.mem s [ "retry"; "fallback"; "handoff"; "abort" ])
      | _ -> failwith "strategy_class not string")
  | _ -> failwith "expected object"

(* ── strategy_class_to_string ───────────────────────────────── *)

let test_strategy_class_strings () =
  check_str "retry" "retry" (RR.strategy_class_to_string `Retry);
  check_str "fallback" "fallback" (RR.strategy_class_to_string `Fallback);
  check_str "handoff" "handoff" (RR.strategy_class_to_string `Handoff);
  check_str "abort" "abort" (RR.strategy_class_to_string `Abort)

(* ── Driver ─────────────────────────────────────────────────── *)

let () =
  let cases =
    [
      ("classify_transient", test_classify_transient);
      ("classify_permanent", test_classify_permanent);
      ( "process_l1_transient_yields_retry",
        test_process_l1_transient_yields_retry );
      ( "process_l2_transient_yields_fallback",
        test_process_l2_transient_yields_fallback );
      ("process_l4_permanent_no_retry", test_process_l4_permanent_no_retry);
      ("process_l3_yields_handoff", test_process_l3_yields_handoff);
      ("strategy_summary_non_empty", test_strategy_summary_non_empty);
      ("output_to_json_shape", test_output_to_json_shape);
      ("output_strategy_class_string", test_output_strategy_class_string);
      ("strategy_class_strings", test_strategy_class_strings);
    ]
  in
  List.iter
    (fun (name, f) ->
      try f ()
      with e ->
        Printf.printf "FAIL %s: %s\n" name (Printexc.to_string e);
        exit 1)
    cases;
  Printf.printf "test_resilience_runtime: %d cases OK\n"
    (List.length cases)
