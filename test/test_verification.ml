(** Tests for Verification module *)

(* Mirage_crypto_rng is consumed by V.generate_id (#7544). *)
let () = Mirage_crypto_rng_unix.use_default ()

module V = Masc_mcp.Verification
module P = Masc_mcp.Prometheus
module CU = Coord_utils

let persistence_surface = "verification"

let persistence_counter reason =
  P.metric_value_or_zero P.metric_persistence_read_drops
    ~labels:[("surface", persistence_surface); ("reason", reason)] ()

(* Initialize mirage-crypto-rng once (needed by Verification.generate_id). *)
let () = Mirage_crypto_rng_unix.use_default ()

let active_verifications_dir base_path =
  Filename.concat (CU.masc_dir_from_base_path ~base_path) "verifications"

let legacy_verifications_dir base_path =
  Filename.concat base_path "verifications"

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

(** Use a temporary directory for each test *)
let with_temp_dir f =
  let dir = Filename.temp_dir "masc_verify_test" "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

(* --- Criterion tests --- *)

let test_criterion_roundtrip () =
  let criteria = [
    V.Schema_match (`Assoc [("type", `String "string")]);
    V.Contains "hello";
    V.Not_contains "error";
    V.Custom "output should be helpful";
  ] in
  List.iter (fun c ->
    let json = V.criterion_to_yojson c in
    match V.criterion_of_yojson json with
    | Ok result ->
        Alcotest.(check bool) "criterion roundtrip" true
          (V.equal_criterion c result)
    | Error e -> Alcotest.fail e
  ) criteria

let test_criterion_of_yojson_errors () =
  let bad_cases = [
    (`String "not an object", "not object");
    (`Assoc [], "missing type");
    (`Assoc [("type", `String "banana")], "unknown type");
    (`Assoc [("type", `String "contains")], "contains missing value");
  ] in
  List.iter (fun (json, label) ->
    match V.criterion_of_yojson json with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (Printf.sprintf "%s should fail" label)
  ) bad_cases

(* --- Verdict tests --- *)

let test_verdict_roundtrip () =
  let verdicts = [V.Pass; V.Fail "bad output"; V.Partial (0.75, "mostly ok")] in
  List.iter (fun v ->
    let json = V.verdict_to_yojson v in
    match V.verdict_of_yojson json with
    | Ok result ->
        Alcotest.(check bool) "verdict roundtrip" true
          (V.equal_verdict v result)
    | Error e -> Alcotest.fail e
  ) verdicts

(* --- Evaluation tests --- *)

let test_evaluate_contains () =
  let output = `String "hello world" in
  Alcotest.(check bool) "contains match" true
    (V.evaluate_criterion output (V.Contains "hello") = V.Pass);
  Alcotest.(check bool) "contains no match" true
    (match V.evaluate_criterion output (V.Contains "xyz") with
     | V.Fail _ -> true | _ -> false)

let test_evaluate_not_contains () =
  let output = `String "hello world" in
  Alcotest.(check bool) "not_contains pass" true
    (V.evaluate_criterion output (V.Not_contains "xyz") = V.Pass);
  Alcotest.(check bool) "not_contains fail" true
    (match V.evaluate_criterion output (V.Not_contains "hello") with
     | V.Fail _ -> true | _ -> false)

let test_evaluate_literal_and_empty_needles () =
  let output = `String "literal .* needle" in
  Alcotest.(check bool) "contains treats regex metacharacters literally" true
    (V.evaluate_criterion output (V.Contains ".*") = V.Pass);
  Alcotest.(check bool) "contains empty needle stays fail" true
    (match V.evaluate_criterion output (V.Contains "") with
     | V.Fail _ -> true | _ -> false);
  Alcotest.(check bool) "not_contains empty needle stays pass" true
    (V.evaluate_criterion output (V.Not_contains "") = V.Pass)

let test_evaluate_schema_match () =
  let output = `Assoc [("key", `String "value")] in
  Alcotest.(check bool) "schema non-null pass" true
    (V.evaluate_criterion output (V.Schema_match (`Assoc [])) = V.Pass);
  Alcotest.(check bool) "schema null fail" true
    (match V.evaluate_criterion `Null (V.Schema_match (`Assoc [])) with
     | V.Fail _ -> true | _ -> false)

let test_evaluate_custom () =
  let output = `String "test" in
  Alcotest.(check bool) "custom returns partial" true
    (match V.evaluate_criterion output (V.Custom "check quality") with
     | V.Partial _ -> true | _ -> false)

let test_evaluate_all_pass () =
  let output = `String "hello world foo" in
  let criteria = [V.Contains "hello"; V.Not_contains "error"] in
  Alcotest.(check bool) "all pass" true
    (V.evaluate_all output criteria = V.Pass)

let test_evaluate_all_fail () =
  let output = `String "hello world" in
  let criteria = [V.Contains "hello"; V.Contains "missing"] in
  Alcotest.(check bool) "one fail = overall fail" true
    (match V.evaluate_all output criteria with
     | V.Fail _ -> true | _ -> false)

let test_evaluate_empty_criteria () =
  Alcotest.(check bool) "empty criteria = pass" true
    (V.evaluate_all `Null [] = V.Pass)

(* --- Cross-agent enforcement --- *)

let test_cross_agent_same () =
  match V.validate_cross_agent ~worker:"claude" ~verifier:"claude" with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "same agent should be rejected"

let test_cross_agent_different () =
  match V.validate_cross_agent ~worker:"claude" ~verifier:"codex" with
  | Ok () -> ()
  | Error e -> Alcotest.fail e

(* --- Storage tests --- *)

let test_create_and_load () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"task-1"
        ~output:(`String "result") ~criteria:[V.Contains "result"]
        ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        Alcotest.(check bool) "persisted under .masc/verifications" true
          (Sys.file_exists
             (Filename.concat (active_verifications_dir base_path)
                (req.id ^ ".json")));
        match V.load_request base_path req.id with
        | Error e -> Alcotest.fail e
        | Ok loaded ->
            Alcotest.(check string) "id matches" req.id loaded.id;
            Alcotest.(check string) "task_id" "task-1" loaded.task_id;
            Alcotest.(check string) "worker" "claude" loaded.worker)

let test_list_requests () =
  with_temp_dir (fun base_path ->
    let _ = V.create_request ~base_path ~task_id:"t1"
        ~output:`Null ~criteria:[] ~worker:"a" () in
    let _ = V.create_request ~base_path ~task_id:"t2"
        ~output:`Null ~criteria:[] ~worker:"b" () in
    let reqs = V.list_requests base_path in
    Alcotest.(check int) "two requests" 2 (List.length reqs))

let test_list_requests_missing_dir_stays_quiet () =
  with_temp_dir (fun base_path ->
    let before =
      persistence_counter Safe_ops.persistence_read_drop_reason_list_dir_error
    in
    let reqs = V.list_requests base_path in
    Alcotest.(check int) "no requests" 0 (List.length reqs);
    Alcotest.(check (float 0.1)) "missing dir does not increment metric"
      before
      (persistence_counter Safe_ops.persistence_read_drop_reason_list_dir_error))

let test_list_requests_skips_bad_entries_with_metric () =
  with_temp_dir (fun base_path ->
    let _ = V.create_request ~base_path ~task_id:"t1"
        ~output:`Null ~criteria:[] ~worker:"a" () in
    let dir = active_verifications_dir base_path in
    Fs_compat.save_file (Filename.concat dir "broken.json") "{not-json";
    let before =
      persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
    in
    let reqs = V.list_requests base_path in
    Alcotest.(check int) "only valid request returned" 1 (List.length reqs);
    Alcotest.(check (float 0.1)) "broken file increments metric" 1.0
      (persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
       -. before))

let test_list_requests_ignores_legacy_root_entries () =
  with_temp_dir (fun base_path ->
    let _ = V.create_request ~base_path ~task_id:"t1"
        ~output:`Null ~criteria:[] ~worker:"a" () in
    let legacy_dir = legacy_verifications_dir base_path in
    Fs_compat.mkdir_p legacy_dir;
    Fs_compat.save_file (Filename.concat legacy_dir "broken.json") "{not-json";
    Fs_compat.save_file (Filename.concat legacy_dir "vrf-foreign.json")
      {|{"id":"vrf-foreign","task_id":"t-foreign","evaluator":"oracle","overall_verdict":"approve"}|};
    let before =
      persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
    in
    let reqs = V.list_requests base_path in
    Alcotest.(check int) "legacy root ignored" 1 (List.length reqs);
    Alcotest.(check (float 0.1)) "legacy root does not increment metric"
      before
      (persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error))

let test_assign_verifier () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1"
        ~output:`Null ~criteria:[] ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        match V.assign_verifier ~base_path ~req_id:req.id ~verifier:"codex" with
        | Error e -> Alcotest.fail e
        | Ok updated ->
            Alcotest.(check bool) "assigned" true
              (match updated.status with V.Assigned "codex" -> true | _ -> false))

let test_assign_verifier_cross_agent_fail () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1"
        ~output:`Null ~criteria:[] ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        match V.assign_verifier ~base_path ~req_id:req.id ~verifier:"claude" with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "cross-agent violation should fail")

let test_submit_verdict () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1"
        ~output:(`String "good") ~criteria:[] ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        match V.submit_verdict ~base_path ~req_id:req.id ~verifier:"codex"
            ~verdict:V.Pass with
        | Error e -> Alcotest.fail e
        | Ok updated ->
            Alcotest.(check bool) "completed" true
              (match updated.status with V.Completed V.Pass -> true | _ -> false);
            (* verifier must be persisted so the dashboard projection never
               emits "approved with null approved_by" for completed rows. *)
            Alcotest.(check (option string)) "verifier recorded"
              (Some "codex") updated.verifier)

let test_submit_verdict_overwrites_unassigned_verifier () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1"
        ~output:(`String "good") ~criteria:[] ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        Alcotest.(check (option string)) "starts unassigned" None req.verifier;
        match V.submit_verdict ~base_path ~req_id:req.id
            ~verifier:"operator:dashboard" ~verdict:V.Pass with
        | Error e -> Alcotest.fail e
        | Ok updated ->
            Alcotest.(check (option string)) "verifier persisted"
              (Some "operator:dashboard") updated.verifier)

let test_auto_verify () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1"
        ~output:(`String "hello world")
        ~criteria:[V.Contains "hello"; V.Not_contains "error"]
        ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        match V.auto_verify ~base_path ~req_id:req.id with
        | Error e -> Alcotest.fail e
        | Ok updated ->
            Alcotest.(check bool) "auto-verified pass" true
              (match updated.status with V.Completed V.Pass -> true | _ -> false);
            (* auto_verify records an "auto" sentinel so the dashboard can
               distinguish rule-based passes from peer-agent verdicts. *)
            Alcotest.(check (option string)) "auto sentinel recorded"
              (Some "auto") updated.verifier)

let test_auto_verify_with_custom_fails () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1"
        ~output:(`String "test")
        ~criteria:[V.Custom "check quality"]
        ~worker:"claude" () with
    | Error e -> Alcotest.fail e
    | Ok req ->
        match V.auto_verify ~base_path ~req_id:req.id with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "auto-verify with custom should fail")

(* --- ID generation property test (#7544) --- *)

module StringSet = Set.Make (String)

let test_generate_id_prefix () =
  let id = V.generate_id () in
  Alcotest.(check bool) "vrf- prefix" true
    (String.length id > 4 && String.sub id 0 4 = "vrf-")

let test_generate_id_no_collisions () =
  (* 10000 consecutive ids must be unique — the old Hashtbl.hash-based
     generator collided within the same millisecond. *)
  let n = 10_000 in
  let seen = ref StringSet.empty in
  for _ = 1 to n do
    let id = V.generate_id () in
    seen := StringSet.add id !seen
  done;
  Alcotest.(check int) "all 10k ids unique" n (StringSet.cardinal !seen)

let test_pending_for_agent () =
  with_temp_dir (fun base_path ->
    let _ = V.create_request ~base_path ~task_id:"t1"
        ~output:`Null ~criteria:[] ~worker:"claude" () in
    let _ = V.create_request ~base_path ~task_id:"t2"
        ~output:`Null ~criteria:[] ~worker:"codex" ~verifier:"gemini" () in
    (* codex should see t1 (not own work), not t2 (assigned to gemini) *)
    let pending = V.pending_for_agent ~base_path ~agent:"codex" in
    Alcotest.(check int) "codex sees 1 pending" 1 (List.length pending);
    (* claude should not see t1 (own work) *)
    let pending_claude = V.pending_for_agent ~base_path ~agent:"claude" in
    Alcotest.(check int) "claude sees 0 (own work filtered)" 0 (List.length pending_claude))

(* --- Attribution conversion tests --- *)

module A = Masc_mcp.Attribution

let test_origin_det_for_rule_based () =
  let cs = [ V.Contains "x"; V.Not_contains "y"; V.Schema_match (`Assoc []) ] in
  Alcotest.(check bool) "Det" true (V.origin_of_criteria cs = A.Det)

let test_origin_nondet_for_custom () =
  let cs = [ V.Contains "x"; V.Custom "is it good?" ] in
  Alcotest.(check bool) "NonDet" true (V.origin_of_criteria cs = A.NonDet)

let test_verdict_pass_to_attribution () =
  let attr = V.to_attribution ~origin:Det ~evidence:`Null V.Pass in
  Alcotest.(check string) "gate" "verification" attr.gate;
  Alcotest.(check bool) "outcome=Passed" true
    (match attr.outcome with A.Passed -> true | _ -> false)

let test_verdict_fail_to_attribution () =
  let attr =
    V.to_attribution ~origin:Det ~evidence:`Null
      (V.Fail "output does not match schema")
  in
  match attr.outcome with
  | A.Policy_failed { reason } ->
    Alcotest.(check string) "reason" "output does not match schema" reason
  | _ -> Alcotest.fail "expected Policy_failed"

let test_verdict_partial_to_attribution () =
  let attr =
    V.to_attribution ~origin:NonDet ~evidence:`Null
      (V.Partial (0.75, "partial match"))
  in
  match attr.outcome with
  | A.Partial_pass { score; rationale } ->
    Alcotest.(check (float 0.0001)) "score" 0.75 score;
    Alcotest.(check string) "rationale" "partial match" rationale
  | _ -> Alcotest.fail "expected Partial_pass"

let test_attribution_of_request_none_for_pending () =
  with_temp_dir (fun base_path ->
    match V.create_request ~base_path ~task_id:"t1" ~output:`Null
            ~criteria:[ V.Contains "x" ] ~worker:"w" () with
    | Error e -> Alcotest.fail ("create failed: " ^ e)
    | Ok req ->
      Alcotest.(check bool) "None for Pending" true
        (V.attribution_of_request req = None))

let test_attribution_of_request_derives_origin () =
  with_temp_dir (fun base_path ->
    (* Build a request with a Custom criterion and a Completed Pass verdict. *)
    match V.create_request ~base_path ~task_id:"t2" ~output:`Null
            ~criteria:[ V.Contains "hello"; V.Custom "must be kind" ]
            ~worker:"claude" ~verifier:"codex" () with
    | Error e -> Alcotest.fail ("create failed: " ^ e)
    | Ok req ->
      let completed = { req with status = V.Completed V.Pass } in
      match V.attribution_of_request completed with
      | Some attr ->
        Alcotest.(check bool) "origin=NonDet (Custom present)" true
          (attr.A.origin = A.NonDet)
      | None -> Alcotest.fail "expected Some attribution")

let () =
  Alcotest.run "Verification" [
    "criterion", [
      Alcotest.test_case "roundtrip" `Quick test_criterion_roundtrip;
      Alcotest.test_case "of_yojson errors" `Quick test_criterion_of_yojson_errors;
    ];
    "verdict", [
      Alcotest.test_case "roundtrip" `Quick test_verdict_roundtrip;
    ];
    "evaluation", [
      Alcotest.test_case "contains" `Quick test_evaluate_contains;
      Alcotest.test_case "not_contains" `Quick test_evaluate_not_contains;
      Alcotest.test_case "literal and empty needles" `Quick
        test_evaluate_literal_and_empty_needles;
      Alcotest.test_case "schema_match" `Quick test_evaluate_schema_match;
      Alcotest.test_case "custom" `Quick test_evaluate_custom;
      Alcotest.test_case "all pass" `Quick test_evaluate_all_pass;
      Alcotest.test_case "all fail" `Quick test_evaluate_all_fail;
      Alcotest.test_case "empty criteria" `Quick test_evaluate_empty_criteria;
    ];
    "cross_agent", [
      Alcotest.test_case "same agent rejected" `Quick test_cross_agent_same;
      Alcotest.test_case "different agents ok" `Quick test_cross_agent_different;
    ];
    "id_generation", [
      Alcotest.test_case "vrf- prefix" `Quick test_generate_id_prefix;
      Alcotest.test_case "10k ids collision-free" `Quick test_generate_id_no_collisions;
    ];
    "storage", [
      Alcotest.test_case "create and load" `Quick test_create_and_load;
      Alcotest.test_case "list requests" `Quick test_list_requests;
      Alcotest.test_case "list requests missing dir stays quiet" `Quick
        test_list_requests_missing_dir_stays_quiet;
      Alcotest.test_case "list requests skips bad entries with metric" `Quick
        test_list_requests_skips_bad_entries_with_metric;
      Alcotest.test_case "list requests ignores legacy root entries" `Quick
        test_list_requests_ignores_legacy_root_entries;
      Alcotest.test_case "assign verifier" `Quick test_assign_verifier;
      Alcotest.test_case "cross-agent assign fail" `Quick test_assign_verifier_cross_agent_fail;
      Alcotest.test_case "submit verdict" `Quick test_submit_verdict;
      Alcotest.test_case "submit verdict persists verifier" `Quick
        test_submit_verdict_overwrites_unassigned_verifier;
      Alcotest.test_case "auto verify" `Quick test_auto_verify;
      Alcotest.test_case "auto verify custom fails" `Quick test_auto_verify_with_custom_fails;
      Alcotest.test_case "pending for agent" `Quick test_pending_for_agent;
    ];
    "attribution", [
      Alcotest.test_case "origin=Det for rule-based criteria" `Quick
        test_origin_det_for_rule_based;
      Alcotest.test_case "origin=NonDet when Custom present" `Quick
        test_origin_nondet_for_custom;
      Alcotest.test_case "Pass → Attribution.Passed" `Quick
        test_verdict_pass_to_attribution;
      Alcotest.test_case "Fail → Attribution.Policy_failed" `Quick
        test_verdict_fail_to_attribution;
      Alcotest.test_case "Partial → Attribution.Partial_pass" `Quick
        test_verdict_partial_to_attribution;
      Alcotest.test_case "attribution_of_request None for Pending" `Quick
        test_attribution_of_request_none_for_pending;
      Alcotest.test_case "attribution_of_request derives origin" `Quick
        test_attribution_of_request_derives_origin;
    ];
  ]
