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

let make_ctx base_path : Tool_autoresearch.context =
  {
    base_path;
    agent_name = Some "test-researcher";
    start_operation = None;
    config = None;
    sw = None;
    clock = None;
  }

let dispatch_json ctx ~name ~args =
  match Tool_autoresearch.dispatch ctx ~name ~args with
  | None -> fail ("dispatch missing for " ^ name)
  | Some result when not result.success -> fail (name ^ " failed: " ^ result.legacy_message)
  | Some result -> Yojson.Safe.from_string result.legacy_message

let dispatch_error label ctx ~name ~args =
  match Tool_autoresearch.dispatch ctx ~name ~args with
  | None -> fail ("dispatch missing for " ^ name)
  | Some result when result.success -> fail (name ^ " unexpectedly succeeded: " ^ result.legacy_message)
  | Some result ->
    let body = result.legacy_message in
    let json = Yojson.Safe.from_string body in
    let error =
      Yojson.Safe.Util.(member "error" json |> to_string_option)
    in
    check bool (label ^ " error field present") true (Option.is_some error);
    json

let valid_record_fields evidence =
  [
    ("goal", `String "Validate autoresearch finding input");
    ("hypothesis", `String "bad inputs should not persist findings");
    ("evidence", `String evidence);
    ("conclusion", `String "validation rejects malformed fields");
  ]

let test_record_and_search_dispatch () =
  with_temp_base "autoresearch-knowledge-dispatch" @@ fun base_path ->
  let ctx = make_ctx base_path in
  let unique = "dispatch-token-autoresearch-findings" in
  let record =
    dispatch_json ctx ~name:"masc_autoresearch_record_finding"
      ~args:
        (`Assoc
           [
             ("goal", `String "Verify exposed autoresearch finding tool");
             ("hypothesis", `String "dispatch can persist findings");
             ("evidence", `String unique);
             ("conclusion", `String "schema and dispatch are wired");
             ("tags", `List [`String "dispatch"; `String "base-path"]);
           ])
  in
  check bool "record dispatch ok" true
    (Yojson.Safe.Util.(member "ok" record |> to_bool));
  let search =
    dispatch_json ctx ~name:"masc_autoresearch_search_findings"
      ~args:(`Assoc [("query", `String unique); ("limit", `Int 5)])
  in
  check int "dispatch search count" 1
    (Yojson.Safe.Util.(member "count" search |> to_int))

let test_record_dispatch_rejects_invalid_input () =
  with_temp_base "autoresearch-knowledge-invalid-record" @@ fun base_path ->
  let ctx = make_ctx base_path in
  let unique = "invalid-record-token-autoresearch-findings" in
  let cases =
    [
      ( "blank required field",
        `Assoc
          [
            ("goal", `String " ");
            ("hypothesis", `String "bad inputs should not persist findings");
            ("evidence", `String unique);
            ("conclusion", `String "validation rejects malformed fields");
          ] );
      ( "invalid confidence",
        `Assoc
          (("confidence", `String "hihg") :: valid_record_fields unique) );
      ( "non-string tag",
        `Assoc
          (("tags", `List [`String "ok"; `Int 1])
           :: valid_record_fields unique) );
      ( "negative cycle_start",
        `Assoc
          (("cycle_start", `Int (-1)) :: valid_record_fields unique) );
      ( "reversed cycle range",
        `Assoc
          (("cycle_start", `Int 3)
           :: ("cycle_end", `Int 1)
           :: valid_record_fields unique) );
    ]
  in
  List.iter
    (fun (label, args) ->
      ignore
        (dispatch_error label ctx ~name:"masc_autoresearch_record_finding"
           ~args))
    cases;
  let search =
    dispatch_json ctx ~name:"masc_autoresearch_search_findings"
      ~args:(`Assoc [("query", `String unique)])
  in
  check int "invalid records were not persisted" 0
    (Yojson.Safe.Util.(member "count" search |> to_int))

let test_search_dispatch_rejects_invalid_input () =
  with_temp_base "autoresearch-knowledge-invalid-search" @@ fun base_path ->
  let ctx = make_ctx base_path in
  let cases =
    [
      ("blank query", `Assoc [("query", `String " ")]);
      ("zero limit", `Assoc [("query", `String "x"); ("limit", `Int 0)]);
      ("negative limit", `Assoc [("query", `String "x"); ("limit", `Int (-1))]);
      ("too large limit", `Assoc [("query", `String "x"); ("limit", `Int 101)]);
      ("non-numeric limit", `Assoc [("query", `String "x"); ("limit", `String "abc")]);
      ("fractional limit", `Assoc [("query", `String "x"); ("limit", `String "1.5")]);
    ]
  in
  List.iter
    (fun (label, args) ->
      ignore
        (dispatch_error label ctx ~name:"masc_autoresearch_search_findings"
           ~args))
    cases

let test_search_dispatch_limit_returns_recent_matches () =
  with_temp_base "autoresearch-knowledge-limit" @@ fun base_path ->
  let ctx = make_ctx base_path in
  let unique = "limit-token-autoresearch-findings" in
  let record id =
    ignore
      (Autoresearch_knowledge.record_finding ~base_path
         ~finding:(make_finding ~id ~evidence:unique ()))
  in
  record "fn-limit-1";
  record "fn-limit-2";
  record "fn-limit-3";
  let search =
    dispatch_json ctx ~name:"masc_autoresearch_search_findings"
      ~args:(`Assoc [("query", `String unique); ("limit", `String "2")])
  in
  let ids =
    Yojson.Safe.Util.(
      member "findings" search |> to_list
      |> List.map (fun json -> member "id" json |> to_string))
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
      test_case "record/search dispatch" `Quick test_record_and_search_dispatch;
      test_case "record dispatch rejects invalid input" `Quick
        test_record_dispatch_rejects_invalid_input;
      test_case "search dispatch rejects invalid input" `Quick
        test_search_dispatch_rejects_invalid_input;
      test_case "search dispatch limit returns recent matches" `Quick
        test_search_dispatch_limit_returns_recent_matches;
    ];
    "lineage", [
      test_case "lineage contract normalizes finding tags" `Quick
        test_lineage_contract_normalizes_finding_tags;
    ];
    "serialization", [
      test_case "finding JSON roundtrip" `Quick test_finding_serde_roundtrip;
    ];
  ]
