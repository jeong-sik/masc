(** test_artifact_store.ml — Tests for MASC CDAL artifact store. *)

open Masc_mcp

let test_dir = ref ""

let setup () =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-artifact-test-%d" (Unix.getpid ())) in
  test_dir := dir;
  let config : Artifact_store.config = { base_dir = dir } in
  Artifact_store.init config;
  config

let cleanup () =
  if !test_dir <> "" && Sys.file_exists !test_dir then
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote !test_dir)))

let make_metadata ?(artifact_id = "test-001") ?(kind = Artifact_store.Evaluator_result)
    ?(producer = "test-agent") () : Artifact_store.artifact_metadata =
  {
    artifact_id;
    kind;
    producer;
    schema_version = "1.0.0";
    created_at_iso = "2026-03-29T00:00:00Z";
    owner = "tester";
    session_id = "sess-001";
  }

(* --- Kind conversion tests --- *)

let test_kind_roundtrip () =
  let kinds =
    Artifact_store.[
      Evaluator_result; Intervention_summary;
      Acceptance_verdict; Evidence_bundle;
    ]
  in
  List.iter
    (fun kind ->
      let str = Artifact_store.kind_to_string kind in
      match Artifact_store.kind_of_string str with
      | Ok k ->
          Alcotest.(check string) "roundtrip"
            (Artifact_store.kind_to_string kind)
            (Artifact_store.kind_to_string k)
      | Error e -> Alcotest.fail e)
    kinds

let test_kind_invalid () =
  match Artifact_store.kind_of_string "nonexistent" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "should fail on invalid kind"

(* --- Write + Read tests --- *)

let test_write_read () =
  let config = setup () in
  let metadata = make_metadata () in
  let payload = `Assoc [ ("score", `Float 0.95); ("passed", `Bool true) ] in
  Artifact_store.write config ~metadata ~payload;
  match Artifact_store.read config ~kind:Artifact_store.Evaluator_result ~artifact_id:"test-001" with
  | Ok (meta, pay) ->
      Alcotest.(check string) "artifact_id" "test-001" meta.artifact_id;
      Alcotest.(check string) "producer" "test-agent" meta.producer;
      let score =
        pay |> Yojson.Safe.Util.member "score" |> Yojson.Safe.Util.to_float
      in
      Alcotest.(check (float 0.01)) "score" 0.95 score;
      cleanup ()
  | Error e ->
      cleanup ();
      Alcotest.fail e

let test_read_not_found () =
  let config = setup () in
  (match Artifact_store.read config ~kind:Artifact_store.Evaluator_result ~artifact_id:"nonexistent" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "should fail on missing artifact");
  cleanup ()

(* --- List artifacts test --- *)

let test_list_artifacts () =
  let config = setup () in
  let m1 = make_metadata ~artifact_id:"eval-001" () in
  let m2 = make_metadata ~artifact_id:"eval-002" () in
  Artifact_store.write config ~metadata:m1 ~payload:(`Assoc []);
  Artifact_store.write config ~metadata:m2 ~payload:(`Assoc []);
  let listed = Artifact_store.list_artifacts config ~kind:Artifact_store.Evaluator_result in
  Alcotest.(check int) "2 artifacts" 2 (List.length listed);
  cleanup ()

(* --- Make ref test --- *)

let test_make_ref () =
  let ref_uri =
    Artifact_store.make_ref ~session_id:"sess-001"
      ~kind:Artifact_store.Evaluator_result ~artifact_id:"eval-001"
  in
  Alcotest.(check string) "uri format"
    "masc-artifact://sess-001/evaluator_result/eval-001" ref_uri

(* --- Metadata serialization test --- *)

let test_metadata_roundtrip () =
  let metadata = make_metadata () in
  let json = Artifact_store.metadata_to_yojson metadata in
  match Artifact_store.metadata_of_yojson json with
  | Ok m ->
      Alcotest.(check string) "id" metadata.artifact_id m.artifact_id;
      Alcotest.(check string) "producer" metadata.producer m.producer;
      Alcotest.(check string) "schema" metadata.schema_version m.schema_version
  | Error e -> Alcotest.fail e

(* --- Multiple kinds test --- *)

let test_multiple_kinds () =
  let config = setup () in
  let m_eval = make_metadata ~artifact_id:"eval-1" ~kind:Artifact_store.Evaluator_result () in
  let m_verdict = make_metadata ~artifact_id:"verdict-1" ~kind:Artifact_store.Acceptance_verdict () in
  Artifact_store.write config ~metadata:m_eval ~payload:(`Assoc [ ("type", `String "eval") ]);
  Artifact_store.write config ~metadata:m_verdict ~payload:(`Assoc [ ("type", `String "verdict") ]);
  let evals = Artifact_store.list_artifacts config ~kind:Artifact_store.Evaluator_result in
  let verdicts = Artifact_store.list_artifacts config ~kind:Artifact_store.Acceptance_verdict in
  Alcotest.(check int) "1 eval" 1 (List.length evals);
  Alcotest.(check int) "1 verdict" 1 (List.length verdicts);
  cleanup ()

(* --- Test suite --- *)

let () =
  Alcotest.run "artifact_store"
    [
      ( "kind",
        [
          Alcotest.test_case "roundtrip" `Quick test_kind_roundtrip;
          Alcotest.test_case "invalid" `Quick test_kind_invalid;
        ] );
      ( "store",
        [
          Alcotest.test_case "write and read" `Quick test_write_read;
          Alcotest.test_case "read not found" `Quick test_read_not_found;
          Alcotest.test_case "list artifacts" `Quick test_list_artifacts;
          Alcotest.test_case "multiple kinds" `Quick test_multiple_kinds;
        ] );
      ( "ref",
        [
          Alcotest.test_case "make ref" `Quick test_make_ref;
        ] );
      ( "metadata",
        [
          Alcotest.test_case "roundtrip" `Quick test_metadata_roundtrip;
        ] );
    ]
