open Alcotest
module Store = Masc.Lane_addon_store
module Sampling = Masc.Lane_addon_sampling
module Types = Masc.Lane_addon_types

let require = function Ok value -> value | Error detail -> fail detail
let max_bytes = 4 * 1024 * 1024
let instance_id = "recovery-budget"

let with_store f =
  let dir = Filename.temp_dir "sampling-receipt-recovery-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir)
    (fun () -> f (Store.create ~root:dir))

let fixture ~outcome_first =
  let answer = String.make (3 * 1024 * 1024) 'x' in
  let rec choose n =
    let request_id = "request-" ^ string_of_int n in
    let request_bytes = Yojson.Safe.to_string (`Assoc ["kind", `String "model_request";
      "instance_id", `String instance_id; "request_id", `String request_id]) in
    let request = Store.blob_reference request_bytes in
    let bytes = Yojson.Safe.to_string (`Assoc ["kind", `String "model_outcome";
      "instance_id", `String instance_id; "request", Types.evidence_to_json request;
      "status", `String "answered"; "response", `Assoc ["role", `String "assistant";
        "model", `String "fixture-model"; "content", `Assoc ["type", `String "text"; "text", `String answer]]]) in
    let outcome = Store.blob_reference bytes in
    if (Stdlib.compare outcome request < 0) = outcome_first
    then request_id, request_bytes, request, bytes, outcome, answer
    else choose (n + 1) in
  choose 1

let output request outcome : Types.output =
  {rows=[{id="answer"; lane_id="result"; kind=Types.Value; title="Answer";
    observed_at=1.; subject_id="answer"; clock=None; actor=None; fields=[];
    evidence=[request;outcome]; related_ids=[]}]; coverage=[]}

let seed store ~outcome_first ~placement =
  let request_id, request_bytes, request, bytes, outcome, answer = fixture ~outcome_first in
  ignore (require (Store.write_blob store request_bytes));
  let journal = `Assoc ["instance_id", `String instance_id; "request_id", `String request_id;
    "state", `String "finished"; "request", Types.evidence_to_json request;
    "outcome", Types.evidence_to_json outcome; "outcome_bytes", `String bytes] in
  require (Store.save_sampling_outcome store ~instance_id ~request_id journal);
  let canonical = Filename.concat (Store.root store) ("evidence/" ^ Store.digest bytes ^ ".json") in
  let existing = match placement with
    | `Missing -> None
    | `Canonical -> ignore (require (Store.write_blob store bytes)); Some canonical
    | `Fallback ->
        Unix.mkdir canonical 0o700;
        ignore (require (Store.write_sampling_blob store bytes));
        Some (Filename.concat (Store.root store) ("sampling-evidence/" ^ Store.digest bytes ^ ".json")) in
  let path = Filename.concat (Store.root store)
    ("sampling-outcomes/" ^ Store.digest instance_id ^ "/" ^ Store.digest request_id ^ ".json") in
  request_id, output request outcome, bytes, answer, path, existing

let test_large_receipt outcome_first placement block_compaction () = with_store @@ fun store ->
  let _, selected, bytes, answer, journal, existing = seed store ~outcome_first ~placement in
  let before = Option.map Unix.stat existing in
  let parent = Filename.dirname journal in
  if block_compaction then Unix.chmod parent 0o500;
  Fun.protect ~finally:(fun () -> if block_compaction then Unix.chmod parent 0o700) (fun () ->
    let query () = require (Sampling.retained_receipts
      ~store:(Store.create ~root:(Store.root store)) ~instance_id ~max_bytes selected) in
    let rows = query () in
    check int "one recovered receipt" 1 (List.length rows);
    check string "complete answer within the 4 MiB query allowance" answer
      Yojson.Safe.Util.(List.hd rows |> member "terminal" |> member "response" |> member "content" |> member "text" |> to_string);
    check bool "repeated read after reopening agrees" true (query () = rows);
    if block_compaction then
      check bool "journal compaction really failed" true
        Yojson.Safe.Util.(Fs_compat.load_file journal |> Yojson.Safe.from_string |> member "outcome_bytes" = `String bytes);
    match existing, before with
    | Some path, Some stat -> check int "intact outcome inode is preserved" stat.Unix.st_ino (Unix.stat path).Unix.st_ino
    | None, None -> ()
    | Some _, None | None, Some _ -> fail "inconsistent fixture")

let test_aggregate_limit_is_not_replenished () = with_store @@ fun store ->
  let _, first, _, _, _, _ = seed store ~outcome_first:false ~placement:`Canonical in
  let _, second, _, _, _, _ = seed store ~outcome_first:true ~placement:`Canonical in
  let selected = {first with rows=first.rows @ second.rows} in
  check bool "two distinct 3 MiB outcomes still exceed 4 MiB" true
    (Result.is_error (Sampling.retained_receipts ~store ~instance_id ~max_bytes selected))

let test_oversized_journal_stays_bounded () = with_store @@ fun store ->
  let request_id, _, _, _, journal, _ = seed store ~outcome_first:false ~placement:`Missing in
  let limit = String.length (Fs_compat.load_file journal) - 1 in
  match Store.load_sampling_request_bounded store ~instance_id ~request_id
    ~budget:(Store.read_budget ~max_bytes:limit) with
  | Error Store.Read_limit_exceeded -> ()
  | Ok _ | Error (Store.Read_failed _) -> fail "oversized journal was not refused"

let test_failed_journal_verification_consumes_read () = with_store @@ fun store ->
  let request_id, _, _, _, journal, _ = seed store ~outcome_first:false ~placement:`Missing in
  let budget = Store.read_budget ~max_bytes:(String.length (Fs_compat.load_file journal)) in
  let fail_sync _ = raise (Unix.Unix_error (Unix.EIO, "fsync", "fixture")) in
  (match Store.For_testing.load_sampling_request_bounded store ~instance_id ~request_id ~budget
     ~sync_file:fail_sync ~sync_parent:Unix.fsync with
   | Error (Store.Read_failed _) -> ()
   | Ok _ | Error Store.Read_limit_exceeded -> fail "durability refusal was lost");
  let small = require (Store.write_blob store "{}") in
  check bool "failed journal read does not replenish allowance" true
    (Store.read_blob_bounded ~budget store small = Error Store.Read_limit_exceeded)

let () =
  let cases = List.concat_map (fun first ->
    List.map (fun (label, placement, blocked) ->
      test_case (Printf.sprintf "outcome_first=%b %s" first label) `Quick
        (test_large_receipt first placement blocked))
      ["missing", `Missing, false; "canonical", `Canonical, false;
       "fallback", `Fallback, false; "compaction failure", `Canonical, true]) [false;true] in
  run "Sampling receipt recovery"
    ["bounded downstream", cases @ [
      test_case "aggregate allowance is preserved" `Quick test_aggregate_limit_is_not_replenished;
      test_case "journal file bound is preserved" `Quick test_oversized_journal_stays_bounded;
      test_case "failed verification consumes read" `Quick test_failed_journal_verification_consumes_read]]
