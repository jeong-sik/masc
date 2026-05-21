(** E2E roundtrip test for Autoresearch_knowledge: record + search. *)

open Alcotest
open Masc_mcp

let has_prefix ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter
        (fun child -> remove_tree (Filename.concat path child))
        (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path

let cleanup_temp_base dir =
  let basename = Filename.basename dir in
  let temp_dir = Filename.get_temp_dir_name () in
  if Filename.dirname dir = temp_dir
     && has_prefix ~prefix:"autoresearch-knowledge-" basename then
    try remove_tree dir with _ -> ()

let with_temp_base prefix f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (prefix ^ "-" ^ Autoresearch_knowledge.generate_finding_id ())
  in
  Fs_compat.mkdir_p dir;
  Fun.protect ~finally:(fun () -> cleanup_temp_base dir) (fun () -> f dir)

let make_finding ?(id = Autoresearch_knowledge.generate_finding_id ())
    ?(goal = "Understand attention window effect on BPB")
    ?(hypothesis = "Full attention (L) produces lower BPB than sliding window (SSSL)")
    ?(evidence = "MPS baseline L pattern: val_bpb=1.698")
    ?(conclusion = "Window pattern effect needs same-hardware comparison.")
    ?(tags = ["attention"; "window-pattern"; "e2e-test"]) () =
  let f : Autoresearch_knowledge.finding = {
    id;
    loop_id = "test-loop-e2e";
    keeper_name = "test-researcher";
    goal;
    hypothesis;
    evidence;
    conclusion;
    confidence = Autoresearch_knowledge.Medium;
    tags;
    related_findings = [];
    cycle_range = Some (1, 87);
    timestamp = Unix.gettimeofday ();
  } in
  f

let test_record_and_search () =
  with_temp_base "autoresearch-knowledge-roundtrip" @@ fun base_path ->
  let f = make_finding () in
  let result =
    Autoresearch_knowledge.record_finding ~base_path ~finding:f
  in
  let ok = Yojson.Safe.Util.(member "ok" result |> to_bool_option)
           |> Option.value ~default:false in
  check bool "record ok" true ok;
  let found =
    Autoresearch_knowledge.search_findings ~base_path ~query:"attention" ()
  in
  check bool "found at least 1" true (List.length found >= 1);
  let has_ours = List.exists (fun (r : Autoresearch_knowledge.finding) ->
    r.id = f.id) found in
  check bool "found our finding" true has_ours

let test_search_no_match () =
  with_temp_base "autoresearch-knowledge-empty" @@ fun base_path ->
  let found =
    Autoresearch_knowledge.search_findings ~base_path
      ~query:"xyzzy_nonexistent_42" ()
  in
  check int "no results" 0 (List.length found)

let test_base_path_isolation () =
  with_temp_base "autoresearch-knowledge-a" @@ fun base_a ->
  with_temp_base "autoresearch-knowledge-b" @@ fun base_b ->
  let f =
    make_finding
      ~goal:"Isolate autoresearch finding storage"
      ~hypothesis:"base path A should not leak into base path B"
      ~evidence:"unique-token-base-path-isolation"
      ~conclusion:"base path scoped storage works"
      ~tags:["isolation"; "base-path"] ()
  in
  ignore (Autoresearch_knowledge.record_finding ~base_path:base_a ~finding:f);
  let in_a =
    Autoresearch_knowledge.search_findings ~base_path:base_a
      ~query:"unique-token-base-path-isolation" ()
  in
  let in_b =
    Autoresearch_knowledge.search_findings ~base_path:base_b
      ~query:"unique-token-base-path-isolation" ()
  in
  check bool "base A finds record" true
    (List.exists
       (fun (r : Autoresearch_knowledge.finding) -> r.id = f.id)
       in_a);
  check int "base B stays isolated" 0 (List.length in_b)

let test_search_limit_returns_recent_matches () =
  with_temp_base "autoresearch-knowledge-limit" @@ fun base_path ->
  let unique = "limit-token-autoresearch-findings" in
  let record id =
    ignore
      (Autoresearch_knowledge.record_finding ~base_path
         ~finding:(make_finding ~id ~evidence:unique ()))
  in
  record "fn-limit-1";
  record "fn-limit-2";
  record "fn-limit-3";
  let ids =
    Autoresearch_knowledge.search_findings ~base_path ~query:unique ~limit:2 ()
    |> List.map (fun (finding : Autoresearch_knowledge.finding) -> finding.id)
  in
  check (list string) "most recent limited matches"
    ["fn-limit-3"; "fn-limit-2"] ids

let test_lineage_contract_normalizes_finding_tags () =
  check (list string) "cycle participants"
    [
      Autoresearch_lineage.lesson_reviewer_actor_name;
      Autoresearch_lineage.cycle_runner_actor_name;
    ]
    Autoresearch_lineage.cycle_failure_participants;
  check (list string) "lineage tags"
    [ Autoresearch_lineage.domain_tag; "main.txt"; "diff-guard" ]
    (Autoresearch_lineage.finding_tags ~target_file:" main.txt "
       ~extra:[ "diff-guard"; ""; "autoresearch"; "main.txt"; "diff-guard" ])

let test_finding_serde_roundtrip () =
  let f : Autoresearch_knowledge.finding = {
    id = "fn-test-serde";
    loop_id = "loop-42";
    keeper_name = "serde-tester";
    goal = "Test serialization";
    hypothesis = "JSON roundtrip preserves all fields";
    evidence = "Encode then decode";
    conclusion = "All fields match";
    confidence = Autoresearch_knowledge.High;
    tags = ["serde"; "test"];
    related_findings = ["fn-other"];
    cycle_range = Some (10, 20);
    timestamp = 1234567890.0;
  } in
  let json = Autoresearch_knowledge.finding_to_yojson f in
  match Autoresearch_knowledge.finding_of_yojson json with
  | Error e -> fail ("deserialize failed: " ^ e)
  | Ok f2 ->
    check string "id" f.id f2.id;
    check string "goal" f.goal f2.goal;
    check string "confidence" "high"
      (Autoresearch_knowledge.confidence_to_string f2.confidence);
    check int "tags count" 2 (List.length f2.tags)

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "Autoresearch_knowledge" [
    "record_search", [
      test_case "record and search roundtrip" `Quick test_record_and_search;
      test_case "search no match" `Quick test_search_no_match;
      test_case "base path isolation" `Quick test_base_path_isolation;
      test_case "search limit returns recent matches" `Quick
        test_search_limit_returns_recent_matches;
    ];
    "lineage", [
      test_case "lineage contract normalizes finding tags" `Quick
        test_lineage_contract_normalizes_finding_tags;
    ];
    "serialization", [
      test_case "finding JSON roundtrip" `Quick test_finding_serde_roundtrip;
    ];
  ]
