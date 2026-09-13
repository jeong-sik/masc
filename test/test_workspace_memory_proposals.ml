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
  let sources = field "sources" input |> Yojson.Safe.Util.to_list in
  let original = List.hd sources in
  let missing_fact = match original with
    | `Assoc fields -> `Assoc (List.remove_assoc "fact" fields)
    | _ -> Alcotest.fail "source fixture object" in
  List.iter (fun invalid_source ->
    let invalid = replace "sources" (`List (invalid_source :: List.tl sources)) input in
    ignore (Api.post ~base_path (Yojson.Safe.to_string invalid) |> expect `Bad_request))
    [missing_fact; replace "fact" `Null original;
     replace "evidence_path" `Null original; `Null; `String "not an object"];
  List.iter (fun invalid ->
    ignore (Api.post ~base_path (Yojson.Safe.to_string invalid) |> expect `Bad_request))
    [`Null; `List []; replace "proposal" `Null input;
     replace "snapshots" (`List [obj ["snapshot_id", str "writer"]]) input];
  let listing = Api.get ~base_path ~id:None |> expect `OK in
  json_equal "invalid input never creates proposal" (`List []) (field "proposals" listing)
let test_corruption () =
  let base_path = Filename.temp_dir "workspace-proposals-corrupt" "" in
  ignore (Api.get ~base_path ~id:(Some hash) |> expect `Not_found);
  let saved = Api.post ~base_path (Yojson.Safe.to_string (fixture ())) |> expect `OK in
  let id = get_id saved in
  let path = Filename.concat base_path (Common.masc_dirname ^ "/workspace-memory/proposals/" ^ id ^ ".json") in
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
let test_unavailable_gap () =
  let base_path = Filename.temp_dir "workspace-proposals-gap" "" in
  let input = fixture () in
  let gap observation = obj ["keeper_id", str "writer"; "store", str "source_bound";
    "observation", observation] in
  let without_detail = replace "gaps"
    (`List [gap (obj ["status", str "unavailable"])]) input in
  ignore (Api.post ~base_path (Yojson.Safe.to_string without_detail) |> expect `Bad_request);
  let with_detail = replace "gaps" (`List [gap (obj ["status", str "unavailable";
    "detail", str "Cannot read current snapshot: permission denied"])]) input in
  let saved = Api.post ~base_path (Yojson.Safe.to_string with_detail) |> expect `OK in
  let fetched = Api.get ~base_path ~id:(Some (get_id saved)) |> expect `OK in
  json_equal "unavailable diagnostic survives round-trip" (canonical with_detail) (field "proposal" fetched)
module Publication = Masc.Workspace_memory_publication
let require_publication = function Ok value -> value | Error detail -> Alcotest.fail detail
let publication_path base_path = Filename.concat base_path
  (Common.masc_dirname ^ "/workspace-memory/publication.json")
let write_bytes path bytes =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel bytes)
let published base_path = match Publication.observe ~base_path with
  | Publication.Available descriptor -> descriptor
  | Missing -> Alcotest.fail "missing publication"
  | Unavailable detail -> Alcotest.fail detail
let unavailable base_path = match Publication.observe ~base_path with
  | Publication.Unavailable _ -> ()
  | Missing | Available _ -> Alcotest.fail "expected unavailable publication"
let test_publication_discovery () =
  Prompt_registry.set_markdown_dir "../config/prompts";
  let base_path = Filename.temp_dir "workspace-publication" "" in
  let first = Api.post ~base_path (Yojson.Safe.to_string (fixture ())) |> expect `OK |> get_id in
  Alcotest.(check bool) "saving alone does not publish" true
    (Publication.observe ~base_path = Publication.Missing);
  Publication.publish ~base_path ~proposal_id:first |> require_publication;
  let descriptor = published base_path in
  Alcotest.(check string) "discovery retains exact immutable id" first descriptor.proposal_id;
  let unrelated = Filename.concat base_path
    (Common.masc_dirname ^ "/workspace-memory/proposals/" ^ String.make 64 'f' ^ ".json") in
  write_bytes unrelated "{invalid historical archive";
  Alcotest.(check string) "discovery never scans other historical proposals" first
    (published base_path).proposal_id;
  let full = Api.get ~base_path ~id:(Some first) |> expect `OK in
  json_equal "discovered ID resolves all original attribution" (canonical (fixture ())) (field "proposal" full);
  let text = Masc.Keeper_unified_prompt.format_workspace_memory_observation (Publication.observe ~base_path)
    |> Option.get in
  let contains needle = String.split_on_char '\n' text |> List.exists (fun line ->
    let n = String.length needle in
    let rec at i = i + n <= String.length line &&
      (String.sub line i n = needle || at (i+1)) in at 0) in
  List.iter (fun needle -> Alcotest.(check bool) needle true (contains needle))
    [first; "model_proposed"; "not_performed"; "not_checked_against_current_memory"; "keeper_workspace_memory_read"];
  List.iter (fun needle -> Alcotest.(check bool) "source/model content is not injected" false (contains needle))
    ["Owners disagree on PDF pages"; "PDF has ten pages"; "writer:measurement"];
  let second_input = fixture () |> replace "context_sha256" (str (String.make 64 'b')) in
  let second = Api.post ~base_path (Yojson.Safe.to_string second_input) |> expect `OK |> get_id in
  Publication.publish ~base_path ~proposal_id:second |> require_publication;
  Alcotest.(check string) "new publication replaces descriptor, preserves archive" second (published base_path).proposal_id;
  ignore (Api.get ~base_path ~id:(Some first) |> expect `OK);
  Alcotest.(check bool) "failed publish does not replace last successful publication" true
    (Result.is_error (Publication.publish ~base_path ~proposal_id:(String.make 64 'c')));
  Alcotest.(check string) "previous published id remains exact" second (published base_path).proposal_id

let test_publication_integrity () =
  let base_path = Filename.temp_dir "workspace-publication-corrupt" "" in
  let id = Api.post ~base_path (Yojson.Safe.to_string (fixture ())) |> expect `OK |> get_id in
  Publication.publish ~base_path ~proposal_id:id |> require_publication;
  let path = publication_path base_path in
  let good = Yojson.Safe.from_file path in
  write_bytes path (Yojson.Safe.to_string (replace "context_sha256" (str (String.make 64 'b')) good));
  unavailable base_path;
  Alcotest.(check bool) "invalid latest is not resurrected from successful history" true
    (Result.is_error (Publication.publish ~base_path ~proposal_id:id));
  write_bytes path "{invalid";
  unavailable base_path;
  let hidden = Masc.Keeper_unified_prompt.format_workspace_memory_observation (Publication.observe ~base_path) in
  Alcotest.(check bool) "unavailable has explicit nonempty observation" true (Option.is_some hidden);
  write_bytes path (Yojson.Safe.to_string good);
  let source = Filename.concat base_path (Common.masc_dirname ^ "/workspace-memory/proposals/" ^ id ^ ".json") in
  write_bytes source "{corrupt published content";
  unavailable base_path;
  Sys.remove source;
  unavailable base_path;
  let missing_base = Filename.temp_dir "workspace-publication-dangling" "" in
  Unix.symlink (Filename.concat missing_base "absent-target")
    (Filename.concat missing_base Common.masc_dirname);
  unavailable missing_base

let () = Alcotest.run "workspace memory proposals" ["behavior", [
  Alcotest.test_case "publication discovers one verified archive without injecting claims" `Quick test_publication_discovery;
  Alcotest.test_case "corrupt latest publication never falls back or resurrects" `Quick test_publication_integrity;
  Alcotest.test_case "submit, restart read, attribution and idempotence" `Quick test_persist;
  Alcotest.test_case "malformed references refused before persistence" `Quick test_invalid;
  Alcotest.test_case "missing and corruption remain distinct" `Quick test_corruption;
  Alcotest.test_case "unique evidence bindings and zero-fact retractions" `Quick test_evidence_bindings;
  Alcotest.test_case "real saved local curator proposal" `Quick test_real_curator;
  Alcotest.test_case "unavailable gap requires preserved detail" `Quick test_unavailable_gap]]
