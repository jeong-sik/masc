module Store = Masc.Workspace_memory_proposal
module Api = Server_workspace_memory_proposals
let hash = String.make 64 'a'
let obj xs = `Assoc xs
let str s = `String s
let field k = Yojson.Safe.Util.member k
let fixture () =
  let snapshot owner = obj ["snapshot_id", str owner; "keeper_id", str owner;
    "store", str "ordinary"; "snapshot_sha256", str hash;
    "metadata", obj ["revision", `Int 1; "saved_at", str "2026-09-10";
      "change", obj ["removed", `List [str "Earlier unsupported claim"]]]] in
  let source owner claim = obj ["source_id", str owner; "snapshot_id", str owner;
    "keeper_id", str owner; "store", str "ordinary"; "snapshot_sha256", str hash;
    "revision", `Int 1; "fact_index", `Int 0;
    "fact", obj ["claim", str claim; "evidence", str (owner ^ ":measurement")]] in
  obj ["status", str "model_proposed"; "context_sha256", str hash;
    "snapshots", `List [snapshot "writer"; snapshot "reviewer"];
    "sources", `List [source "writer" "PDF has ten pages"; source "reviewer" "PDF has twelve pages"];
    "gaps", `List [obj ["keeper_id", str "writer"; "store", str "source_bound";
      "observation", obj ["status", str "missing"]]];
    "proposal", obj ["shared_claims", `List [];
      "conflicts", `List [obj ["description", str "Owners disagree on PDF pages";
        "source_ids", `List [str "writer"; str "reviewer"]]];
      "excluded", `List []]]
let expect status (actual,json) =
  Alcotest.(check bool) "HTTP status" true (status = actual); json
let json_equal message a b =
  Alcotest.(check bool) message true (Yojson.Safe.equal a b)
let get_id json = field "id" json |> Yojson.Safe.Util.to_string
let canonical json = match Store.decode json with Ok t -> Store.to_json t | Error e -> Alcotest.fail e
let test_persist () =
  let base_path = Filename.temp_dir "workspace-proposals" "" in
  let input = fixture () in
  let first = Api.post ~base_path (Yojson.Safe.to_string input) |> expect `OK in
  let id = get_id first in
  let again = Api.post ~base_path (Yojson.Safe.pretty_to_string input) |> expect `OK in
  Alcotest.(check string) "same content is idempotent" id (get_id again);
  let fetched = Api.get ~base_path ~id:(Some id) |> expect `OK in
  json_equal "all attribution, gaps and snapshot metadata survive" (canonical input) (field "proposal" fetched);
  let listing = Api.get ~base_path ~id:None |> expect `OK in
  Alcotest.(check int) "one immutable proposal" 1 (field "proposals" listing |> Yojson.Safe.Util.to_list |> List.length);
  Alcotest.(check string) "never promoted" "model_proposed" (field "status" (field "proposal" fetched) |> Yojson.Safe.Util.to_string)
let replace k v = function `Assoc xs -> `Assoc ((k,v) :: List.remove_assoc k xs) | _ -> Alcotest.fail "fixture object"
let test_invalid () =
  let base_path = Filename.temp_dir "workspace-proposals-invalid" "" in
  let input = fixture () in
  let proposal = field "proposal" input in
  let bad = replace "conflicts" (`List [obj ["description", str "Unattributed";
    "source_ids", `List [str "unknown"]]]) proposal in
  ignore (Api.post ~base_path (Yojson.Safe.to_string (replace "proposal" bad input)) |> expect `Bad_request);
  let overlap = replace "excluded" (`List [obj ["source_id", str "writer"; "reason", str "unused"]]) proposal in
  ignore (Api.post ~base_path (Yojson.Safe.to_string (replace "proposal" overlap input)) |> expect `Bad_request);
  let listing = Api.get ~base_path ~id:None |> expect `OK in
  json_equal "invalid input never creates proposal" (`List []) (field "proposals" listing)
let test_corruption () =
  let base_path = Filename.temp_dir "workspace-proposals-corrupt" "" in
  ignore (Api.get ~base_path ~id:(Some hash) |> expect `Not_found);
  let saved = Api.post ~base_path (Yojson.Safe.to_string (fixture ())) |> expect `OK in
  let id = get_id saved in
  let path = Filename.concat base_path (Masc.Common.masc_dirname ^ "/workspace-memory/proposals/" ^ id ^ ".json") in
  let ch = open_out_bin path in output_string ch "{broken"; close_out ch;
  ignore (Api.get ~base_path ~id:(Some id) |> expect `Service_unavailable);
  ignore (Api.get ~base_path ~id:None |> expect `Service_unavailable);
  ignore (Api.post ~base_path (Yojson.Safe.to_string (fixture ())) |> expect `Service_unavailable);
  ignore (Api.get ~base_path ~id:(Some "../elsewhere") |> expect `Bad_request)
let test_evidence_bindings () =
  let base_path = Filename.temp_dir "workspace-proposals-bindings" "" in
  let input = fixture () in
  let sources = field "sources" input |> Yojson.Safe.Util.to_list in
  let original = List.hd sources in
  let duplicate = original |> replace "source_id" (str "contradiction")
    |> replace "fact" (obj ["claim", str "PDF has a million pages"]) in
  let proposal = field "proposal" input |> replace "excluded"
    (`List [obj ["source_id", str "contradiction"; "reason", str "contradicts writer"]]) in
  let bad = input |> replace "sources" (`List (duplicate :: sources)) |> replace "proposal" proposal in
  ignore (Api.post ~base_path (Yojson.Safe.to_string bad) |> expect `Bad_request);
  let snapshot = obj ["snapshot_id", str "retraction"; "keeper_id", str "analyst";
    "store", str "source_bound"; "snapshot_sha256", str hash;
    "metadata", obj ["revision", `Int 2;
      "change", obj ["removed", `List [str "Retracted measurement"]];
      "invalidations", `List [obj ["reason", str "source file changed"]]]] in
  let evidence source_id path = obj ["source_id", str source_id;
    "snapshot_id", str "retraction"; "evidence_path", `List path] in
  let change = evidence "change" [str "change"] in
  let invalidation = evidence "invalidation" [str "invalidations"; `Int 0] in
  let retraction = input |> replace "snapshots" (`List [snapshot])
    |> replace "sources" (`List [change; invalidation])
    |> replace "proposal" (obj ["shared_claims", `List [obj [
      "claim", str "Analyst withdrew the measurement after its source changed";
      "source_ids", `List [str "change"; str "invalidation"]]];
      "conflicts", `List []; "excluded", `List []]) in
  let saved = Api.post ~base_path (Yojson.Safe.to_string retraction) |> expect `OK in
  let fetched = Api.get ~base_path ~id:(Some (get_id saved)) |> expect `OK in
  json_equal "zero-current-fact retractions preserve evidence" (canonical retraction) (field "proposal" fetched);
  List.iter (fun evidence ->
    let duplicate = replace "source_id" (str "duplicate") evidence in
    let proposal = field "proposal" retraction |> replace "excluded"
      (`List [obj ["source_id", str "duplicate"; "reason", str "duplicate"]]) in
    let bad = retraction |> replace "sources" (`List [change; invalidation; duplicate])
      |> replace "proposal" proposal in
    ignore (Api.post ~base_path (Yojson.Safe.to_string bad) |> expect `Bad_request))
    [change; invalidation]
let test_real_curator () =
  let base_path = Filename.temp_dir "workspace-proposals-real" "" in
  (* Actual saved output of the local Qwen3.8-27B run, not a model-shaped mock. *)
  let input = Yojson.Safe.from_file
    "../docs/evidence/2026-09-10-workspace-memory-curator/qwen38-27b/proposal.json" in
  let saved = Api.post ~base_path (Yojson.Safe.to_string input) |> expect `OK in
  let fetched = Api.get ~base_path ~id:(Some (get_id saved)) |> expect `OK in
  json_equal "recorded model output survives server round-trip" (canonical input) (field "proposal" fetched)
let () = Alcotest.run "workspace memory proposals" ["behavior", [
  Alcotest.test_case "submit, restart read, attribution and idempotence" `Quick test_persist;
  Alcotest.test_case "malformed references refused before persistence" `Quick test_invalid;
  Alcotest.test_case "missing and corruption remain distinct" `Quick test_corruption;
  Alcotest.test_case "unique evidence bindings and zero-fact retractions" `Quick test_evidence_bindings;
  Alcotest.test_case "real saved local curator proposal" `Quick test_real_curator]]
