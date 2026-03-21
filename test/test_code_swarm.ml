(** Tests for Code_swarm_plan — worker splitting, verdict mapping, JSON round-trip. *)

module CSP = Masc_mcp.Code_swarm_plan

open Alcotest

(* ================================================================ *)
(* split_into_workers tests                                         *)
(* ================================================================ *)

let test_split_empty () =
  let result = CSP.split_into_workers ~max_workers:3 [] in
  check int "empty input -> 0 workers" 0 (List.length result)

let test_split_single_file () =
  let result = CSP.split_into_workers ~max_workers:3 [("foo.ml", 5)] in
  check int "1 file -> 1 worker" 1 (List.length result);
  let w = List.hd result in
  check int "worker has 5 matches" 5 w.match_count;
  check (list string) "worker has foo.ml" ["foo.ml"] w.files

let test_split_balanced () =
  let files = [("a.ml", 10); ("b.ml", 8); ("c.ml", 6)] in
  let result = CSP.split_into_workers ~max_workers:3 files in
  check int "3 files, 3 workers" 3 (List.length result);
  let total =
    List.fold_left (fun acc (w : CSP.worker_plan) -> acc + w.match_count) 0 result
  in
  check int "total matches preserved" 24 total

let test_split_more_files_than_workers () =
  let files = [("a.ml", 10); ("b.ml", 8); ("c.ml", 6); ("d.ml", 4); ("e.ml", 2); ("f.ml", 1)] in
  let result = CSP.split_into_workers ~max_workers:2 files in
  check int "6 files, 2 workers" 2 (List.length result);
  let total =
    List.fold_left (fun acc (w : CSP.worker_plan) -> acc + w.match_count) 0 result
  in
  check int "total matches preserved" 31 total;
  List.iter
    (fun (w : CSP.worker_plan) ->
      if w.match_count > 20 then
        fail (Printf.sprintf "worker %s has %d matches (unbalanced)" w.worker_id w.match_count))
    result

let test_split_hard_limit () =
  let files = List.init 10 (fun i -> (Printf.sprintf "f%d.ml" i, 1)) in
  let result = CSP.split_into_workers ~max_workers:10 files in
  check int "10 files with max 10 -> 10 workers" 10 (List.length result)

(* ================================================================ *)
(* verdict tests                                                    *)
(* ================================================================ *)

let test_verdict_to_string_pass () =
  check string "PASS" "PASS" (CSP.verdict_to_string CSP.Pass)

let test_verdict_to_string_warn () =
  check string "WARN" "WARN: scope issue"
    (CSP.verdict_to_string (CSP.Warn "scope issue"))

let test_verdict_to_string_fail () =
  check string "FAIL" "FAIL: syntax error"
    (CSP.verdict_to_string (CSP.Fail "syntax error"))

(* ================================================================ *)
(* JSON round-trip tests                                            *)
(* ================================================================ *)

let test_plan_to_json () =
  let plan : CSP.swarm_plan = {
    plan_id = "swarm-12345";
    pattern = "Printf.eprintf";
    file_glob = "*.ml";
    total_matches = 10;
    workers = [
      { worker_id = "worker-0"; files = ["a.ml"; "b.ml"]; match_count = 6;
        worktree_branch = "code-swarm/12345/worker-0" };
      { worker_id = "worker-1"; files = ["c.ml"]; match_count = 4;
        worktree_branch = "code-swarm/12345/worker-1" };
    ];
    team_session_goal = "test goal";
    created_at = 1000.0;
    base_path = "/tmp/test";
  } in
  let json = CSP.plan_to_json plan in
  let open Yojson.Safe.Util in
  check string "plan_id" "swarm-12345" (json |> member "plan_id" |> to_string);
  check int "total_matches" 10 (json |> member "total_matches" |> to_int);
  check int "worker_count" 2 (json |> member "worker_count" |> to_int);
  let workers = json |> member "workers" |> to_list in
  check int "2 workers in JSON" 2 (List.length workers)

let test_verify_result_to_json () =
  let vr : CSP.verify_result = {
    results = [
      { worker_id = "w-0"; files_changed = 3; diff_summary = "+foo";
        verdict = CSP.Pass; issues = [] };
      { worker_id = "w-1"; files_changed = 0; diff_summary = "";
        verdict = CSP.Fail "syntax error"; issues = ["syntax error"] };
    ];
    all_pass = false;
    pass_count = 1;
    fail_count = 1;
  } in
  let json = CSP.verify_result_to_json vr in
  let open Yojson.Safe.Util in
  check bool "all_pass false" false (json |> member "all_pass" |> to_bool);
  check int "pass_count" 1 (json |> member "pass_count" |> to_int);
  check int "fail_count" 1 (json |> member "fail_count" |> to_int)

let test_merge_result_to_json () =
  let mr : CSP.merge_result = {
    merged_branch = "code-swarm/merged";
    files_changed = 5;
    conflicts = ["worker-1"];
    build_ok = true;
    skipped_workers = ["worker-2"];
    pr_url = Some "https://github.com/org/repo/pull/42";
  } in
  let json = CSP.merge_result_to_json mr in
  let open Yojson.Safe.Util in
  check string "merged_branch" "code-swarm/merged"
    (json |> member "merged_branch" |> to_string);
  check int "files_changed" 5 (json |> member "files_changed" |> to_int);
  check bool "build_ok" true (json |> member "build_ok" |> to_bool);
  check string "pr_url" "https://github.com/org/repo/pull/42"
    (json |> member "pr_url" |> to_string)

let test_merge_result_no_pr () =
  let mr : CSP.merge_result = {
    merged_branch = "b"; files_changed = 0; conflicts = [];
    build_ok = false; skipped_workers = []; pr_url = None;
  } in
  let json = CSP.merge_result_to_json mr in
  let pr = Yojson.Safe.Util.member "pr_url" json in
  check bool "pr_url is null" true (pr = `Null)

(* ================================================================ *)
(* Tool schema tests                                                *)
(* ================================================================ *)

let test_schemas_count () =
  let schemas = Masc_mcp.Tool_code_swarm.schemas in
  check int "3 MCP tools" 3 (List.length schemas)

let test_schemas_names () =
  let names =
    List.map (fun (s : Types.tool_schema) -> s.name)
      Masc_mcp.Tool_code_swarm.schemas
  in
  check bool "has plan" true (List.mem "masc_code_swarm_plan" names);
  check bool "has verify" true (List.mem "masc_code_swarm_verify" names);
  check bool "has merge" true (List.mem "masc_code_swarm_merge" names)

let test_schemas_valid_input_schema () =
  List.iter
    (fun (s : Types.tool_schema) ->
      let typ =
        Yojson.Safe.Util.member "type" s.input_schema
        |> Yojson.Safe.Util.to_string
      in
      check string (s.name ^ " input_schema.type") "object" typ)
    Masc_mcp.Tool_code_swarm.schemas

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  run "Code_swarm" [
    "split", [
      test_case "empty" `Quick test_split_empty;
      test_case "single file" `Quick test_split_single_file;
      test_case "balanced" `Quick test_split_balanced;
      test_case "more files than workers" `Quick test_split_more_files_than_workers;
      test_case "hard limit" `Quick test_split_hard_limit;
    ];
    "verdict", [
      test_case "to_string PASS" `Quick test_verdict_to_string_pass;
      test_case "to_string WARN" `Quick test_verdict_to_string_warn;
      test_case "to_string FAIL" `Quick test_verdict_to_string_fail;
    ];
    "json", [
      test_case "plan_to_json" `Quick test_plan_to_json;
      test_case "verify_result_to_json" `Quick test_verify_result_to_json;
      test_case "merge_result_to_json" `Quick test_merge_result_to_json;
      test_case "merge_result no PR" `Quick test_merge_result_no_pr;
    ];
    "schemas", [
      test_case "3 tools" `Quick test_schemas_count;
      test_case "tool names" `Quick test_schemas_names;
      test_case "valid input_schema" `Quick test_schemas_valid_input_schema;
    ];
  ]
