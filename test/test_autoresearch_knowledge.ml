(** E2E roundtrip test for Autoresearch_knowledge: record + search. *)

open Alcotest
open Masc_mcp

let with_temp_base prefix f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (prefix ^ "-" ^ Autoresearch_knowledge.generate_finding_id ())
  in
  Fs_compat.mkdir_p dir;
  f dir

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
  | Some (false, body) -> fail (name ^ " failed: " ^ body)
  | Some (true, body) -> Yojson.Safe.from_string body

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
    ];
    "serialization", [
      test_case "finding JSON roundtrip" `Quick test_finding_serde_roundtrip;
    ];
  ]
