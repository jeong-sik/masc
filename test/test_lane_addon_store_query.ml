open Alcotest
open Masc
module Store = Lane_addon_store
module Types = Lane_addon_types
let unwrap = function Ok value -> value | Error message -> fail message
let rec remove path =
  if Sys.is_directory path then (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
  else Sys.remove path
let with_store f =
  let root = Filename.temp_dir "lane-query-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root (Store.create ~root))
let instance_id = "test-instance"
let row seq payload : Types.row = {
  id = Printf.sprintf "%s/%d/row" instance_id seq;
  lane_id = instance_id ^ "/source"; kind = Types.Event; title = "retained observation";
  observed_at = float_of_int seq; subject_id = "existing-target";
  clock = None; actor = None; fields = ["payload", `String payload];
  evidence = []; related_ids = [];
}
let append store seq payload =
  unwrap (Store.append_observation store ~instance_id ~seq ~sources:(`List [])
    { rows = [row seq payload]; coverage = [] })
let query store ~expected_seq ~max_bytes ?since ?until () =
  unwrap (Store.query_observations store ~instance_id ~expected_seq ~max_bytes ~since ~until ~lane_id:None)
let complete output = List.for_all (fun (coverage : Types.coverage) -> coverage.complete) output.Types.coverage
let binding max_bytes = `Assoc ["package", `Assoc ["resources", `Assoc ["max_reply_bytes", `Int max_bytes]]]
let record root seq = Filename.concat root (Printf.sprintf "observations/%s/%020d.json" (Store.digest instance_id) seq)
let write path text = let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel text)

let bounded_history () = with_store (fun _root store ->
  for seq = 1 to 24 do append store seq (String.make 1000 'x') done;
  let max_bytes = 4096 in
  let output = query store ~expected_seq:24 ~max_bytes () in
  check bool "some history fits" true (output.rows <> []);
  check bool "large history is explicitly partial" false (complete output);
  check bool "encoded response fits its declared bound" true
    (String.length (Yojson.Safe.to_string (Types.output_to_json output)) <= max_bytes);
  let late = query store ~expected_seq:24 ~max_bytes ~since:24. () in
  check int "window selection does not retain earlier bodies" 1 (List.length late.rows);
  check bool "complete filtered scan" true (complete late))
let missing_record () = with_store (fun root store ->
  append store 1 "one"; append store 2 "two"; append store 3 "three";
  Sys.remove (record root 2);
  let output = query store ~expected_seq:3 ~max_bytes:4096 () in
  check int "readable records retained" 2 (List.length output.rows);
  check bool "missing interval is not complete" false (complete output);
  Sys.remove (record root 3);
  Sys.remove (record root 1);
  let empty = query store ~expected_seq:3 ~max_bytes:4096 () in
  check bool "persisted highwater exposes missing entire history" false (complete empty))
let coverage_without_rows () = with_store (fun _root store ->
  let source : Types.coverage = { source_id = "msx"; incarnation = "unobserved";
    cursor = None; complete = false; detail = Some "machine unavailable" } in
  unwrap (Store.append_observation store ~instance_id ~seq:1 ~sources:(`List [])
    { rows = []; coverage = [source] });
  let output = query store ~expected_seq:1 ~max_bytes:4096 () in
  check int "unavailable source has no fabricated rows" 0 (List.length output.rows);
  check bool "empty output does not erase missing source coverage" false (complete output);
  check bool "source's reason remains in the query" true
    (List.exists (fun (coverage : Types.coverage) -> coverage = source) output.coverage))
let targeted_evidence () = with_store (fun root store ->
  append store 1 "unrelated"; append store 2 "selected";
  write (record root 1) "{broken unrelated observation";
  let frozen = Store.freeze store ~instance_id ~binding:(binding 4096)
    ~row_ids:[(row 2 "").id] in
  check bool "selected evidence does not scan corrupt unrelated history" true (Result.is_ok frozen);
  check bool "different instance rejected" true
    (Result.is_error (Store.freeze store ~instance_id ~binding:(binding 4096) ~row_ids:["other/2/row"]));
  check bool "evidence envelope enforced" true
    (Result.is_error (Store.freeze store ~instance_id ~binding:(binding 64) ~row_ids:[(row 2 "").id])))
let separate_source_and_output_envelopes () = with_store (fun root store ->
  let max_bytes = 4096 in
  let sources = `List [`String (String.make 3000 's')] in
  let output : Types.output = { rows = [row 1 (String.make 3000 'o')]; coverage = [] } in
  unwrap (Store.append_observation store ~instance_id ~seq:1 ~sources output);
  let original = In_channel.with_open_bin (record root 1) In_channel.input_all in
  check bool "valid record exceeds one component envelope" true (String.length original > max_bytes);
  let queried = query store ~expected_seq:1 ~max_bytes () in
  check int "both bounded components remain queryable" 1 (List.length queried.rows);
  let frozen = unwrap (Store.freeze store ~instance_id ~binding:(binding max_bytes) ~row_ids:[(row 1 "").id]) in
  let open Yojson.Safe.Util in
  let bundle_path = frozen |> member "evidence" |> member "path" |> to_string in
  let bundle = In_channel.with_open_bin bundle_path In_channel.input_all |> Yojson.Safe.from_string in
  let retained = bundle |> member "observations" |> to_list |> List.hd in
  Sys.remove (record root 1);
  let retained_bytes = In_channel.with_open_bin (retained |> member "path" |> to_string) In_channel.input_all in
  check string "exact record bytes survive original history deletion" original retained_bytes;
  check string "retained record digest matches" (Store.digest original) (retained |> member "sha256" |> to_string))

let artifact_of_json json = match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref reference -> reference
  | _ -> fail "expected a normalized artifact reference"
let read_as_keeper ~base_path (reference : Tool_output.artifact_ref) =
  let _, page = Keeper_artifact_read.handle_with_page ~base_path
    ~args:(`Assoc ["sha256", `String reference.sha256]) in
  match page with
  | None -> fail "Keeper could not read published evidence"
  | Some page ->
      check bool "fixture fits one reader page" true page.eof;
      check bool "fixture preserves UTF-8 bytes" true (page.encoding = Keeper_artifact_read.Utf_8);
      check string "reader content keeps its SHA-256" reference.sha256 (Store.digest page.content);
      page.content
let retained_json (reference : Types.evidence) = `Assoc [
  "uri", `String reference.uri;
  "sha256", Option.fold ~none:`Null ~some:(fun value -> `String value) reference.sha256]
let published_evidence_is_readable_by_keeper () = with_store (fun root store ->
  let open Yojson.Safe.Util in
  let external_bytes = "external reference must not become an artifact" in
  let external_path = Filename.concat root "unselected-file" in
  write external_path external_bytes;
  (* The copied source body is opaque even when its JSON contains another
     apparent reference. Only the record's retained references are followed. *)
  let source_bytes = " \n{\"uri\":\"lane-evidence:" ^ String.make 64 'a'
    ^ "\",\"sha256\":\"" ^ String.make 64 'a' ^ "\",\"value\": 17}\n" in
  let source = unwrap (Store.write_blob store source_bytes) in
  let sources = `List [`Assoc ["snapshot_evidence", retained_json source;
    "external", `Assoc ["uri", `String ("file://" ^ external_path);
      "path", `String external_path; "sha256", `String (Store.digest external_bytes)]]] in
  unwrap (Store.append_observation store ~instance_id ~seq:1 ~sources
    { rows = [row 1 "separate assertion"]; coverage = [] });
  let record_bytes = In_channel.with_open_bin (record root 1) In_channel.input_all in
  let frozen = unwrap (Store.freeze store ~instance_id ~binding:(binding 4096) ~row_ids:[(row 1 "").id]) in
  let bundle_bytes = frozen |> member "evidence" |> member "path" |> to_string
    |> fun path -> In_channel.with_open_bin path In_channel.input_all in
  let published = unwrap (Store.publish_for_keeper ~base_path:root store frozen) in
  let root_reference = artifact_of_json (published |> member "keeper_artifact") in
  let prompt = published |> member "message" |> to_string in
  check string "delivery contains exactly the retention marker"
    (Tool_output.encode_for_agent_core (Tool_output.Stored root_reference)) prompt;
  (match Tool_output.decode_from_agent_core prompt with
   | Tool_output.Decoded reference -> check string "retention recognizes root" root_reference.sha256 reference.sha256
   | _ -> fail "delivered prompt is not a retention root");
  check string "typed manifest enables child retention" Tool_output.artifact_manifest_mime root_reference.mime;
  remove (Filename.concat root "evidence");
  remove (Filename.concat root "observations");
  let manifest = read_as_keeper ~base_path:root root_reference |> Yojson.Safe.from_string in
  (match Tool_output.artifact_manifest_of_json manifest with
   | Tool_output.Decoded_artifact_manifest { structured_content; artifact_refs; _ } ->
       check int "manifest retains bundle, record, and original source" 3 (List.length artifact_refs);
       let original_bundle = artifact_of_json (structured_content |> member "bundle") in
       check string "original bundle is readable after Lane files disappear" bundle_bytes
         (read_as_keeper ~base_path:root original_bundle);
       List.iter (fun original ->
         let reference = List.find (fun (reference : Tool_output.artifact_ref) ->
           reference.sha256 = Store.digest original) artifact_refs in
         check string "selected raw bytes cross the Keeper boundary unchanged" original
           (read_as_keeper ~base_path:root reference)) [record_bytes; source_bytes]
   | _ -> fail "invalid published artifact manifest");
  check bool "external URI was never imported" false
    (List.mem (Store.digest external_bytes) (Tool_blob_store.list_all (Tool_blob_store.create ~base_path:root))))
let corrupted_source_is_not_delivered () = with_store (fun root store ->
  let source = unwrap (Store.write_blob store "original source bytes") in
  unwrap (Store.append_observation store ~instance_id ~seq:1
    ~sources:(`List [retained_json source]) { rows = [row 1 "assertion"]; coverage = [] });
  let frozen = unwrap (Store.freeze store ~instance_id ~binding:(binding 4096) ~row_ids:[(row 1 "").id]) in
  let hash = Option.get source.sha256 in
  write (Filename.concat root ("evidence/" ^ hash ^ ".json")) "changed bytes";
  check bool "corrupt raw source prevents publication" true
    (Result.is_error (Store.publish_for_keeper ~base_path:root store frozen)))
let () = run "bounded Lane history" ["queries", [
  test_case "history growth and explicit window" `Quick bounded_history;
  test_case "missing persisted intervals" `Quick missing_record;
  test_case "source absence survives a query with no rows" `Quick coverage_without_rows;
  test_case "targeted bounded evidence" `Quick targeted_evidence;
  test_case "separate ingress and egress envelopes remain preservable" `Quick separate_source_and_output_envelopes;
  test_case "selected evidence crosses the existing Keeper artifact boundary" `Quick published_evidence_is_readable_by_keeper;
  test_case "changed source bytes prevent publication" `Quick corrupted_source_is_not_delivered]]
