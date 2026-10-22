open Masc
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module Request = Workspace_memory_request
module Ledger = Workspace_memory_ledger
module Briefing = Workspace_memory_briefing
let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let owned value = get (Result.map_error Owner.error_to_string value)
let requested value = get (Result.map_error Request.error_to_string value)
let some = function Some value -> value | None -> Alcotest.fail "missing retained work"
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let member = Yojson.Safe.Util.member
let replace key value = function
  | `Assoc fields -> `Assoc (List.map (fun (name, old) -> name, if name = key then value else old) fields)
  | _ -> Alcotest.fail "expected object"
let with_store f =
  let parent = Filename.temp_dir "curator-capture" "" in
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove parent) (fun () ->
    let root = Filename.concat parent "store" in f root (Store.create ~root))
let retain ?(installation_id = "original-installation") ?(package_id = "curator")
    ?(tool = "classify") ~request_id ~request store =
  Owner.retain ~store ~scope:"workspace-curator" ~request_id ~installation_id ~package_id ~tool ~request
let load store request_id = Owner.load ~store ~scope:"workspace-curator" ~request_id
let render input = Ok ("Original captured prompt:\n" ^ Yojson.Safe.to_string input)
let fact ?path keeper claim : Ledger.pending_fact =
  let claim_sha256 = Digestif.SHA256.(digest_string claim |> to_hex) in
  let fact = match path with
    | None -> Ledger.Ordinary {keeper_id=keeper;claim_sha256}
    | Some path -> Ledger.Source_bound {keeper_id=keeper;path;claim_sha256} in
  {fact;claim}

let test_classification_reopens_exact_batches_and_applies_only_selected () = with_store (fun root store ->
  let a = fact ~path:"notes/a.md" "writer" "Original source evidence" in
  let b = fact ~path:"notes/b.md" "writer" a.claim in
  let c = fact "writer" "Other pending evidence" in
  let neighbor = fact "reviewer" a.claim in
  let full = some (requested (Request.prepare ~neighbor_limit:1 ~render ~ledger:Ledger.empty
      ~current:[a;b;c;neighbor] ~pending:[a;b;c] ~frame:max_int ~measure:(fun _ -> Ok 0))) in
  let narrowed = some (requested (Request.narrow ~render ~ledger:Ledger.empty full)) in
  List.iter (fun (request_id, original) ->
    let request = `Assoc ["ledger", Ledger.to_json Ledger.empty; "batch", Request.batch_to_json original] in
    owned (retain ~request_id ~request store);
    let retained = some (owned (load (Store.create ~root) request_id)) in
    let ledger = get (Ledger.of_json (member "ledger" retained.request)) in
    let restored = requested (Request.batch_of_json ~ledger (member "batch" retained.request)) in
    Alcotest.check json "original rows, neighbors, suffix, prompt and index observations"
      (Request.batch_to_json original) (Request.batch_to_json restored))
    ["classification-full",full; "classification-child",narrowed];
  let retained = some (owned (load (Store.create ~root) "classification-child")) in
  let restored = requested (Request.batch_of_json ~ledger:Ledger.empty (member "batch" retained.request)) in
  let local = match Request.selected_ids restored with
    | [(id, _)] -> id | [] | _ :: _ :: _ -> Alcotest.fail "one narrowed selection" in
  let answer = `Assoc ["decisions", `List [`Assoc ["fact_id", `String local;
    "kind", `String "create_claim"; "value", `String "A captured interpretation"]]] in
  let decisions = get (Workspace_memory_decision.decode ~batch:restored answer) in
  let applied = get (Result.map_error Ledger.apply_error_to_string
      (Ledger.apply Ledger.empty ~selected:restored.selected decisions)) in
  Alcotest.(check bool) "the oldest source-bound fact is the narrowed selection" true
    (restored.selected = [a]);
  Alcotest.(check bool) "only the original selected source was disposed" true
    (List.map fst (Ledger.dispositions applied) = [a.fact]))

let test_pending_and_neighbor_boundaries_are_strict () =
  let a = fact "writer" "Shared original evidence" and b = fact "other" "Shared original evidence" in
  let full = some (requested (Request.prepare ~neighbor_limit:1 ~render ~ledger:Ledger.empty
      ~current:[a;b] ~pending:[a] ~frame:max_int ~measure:(fun _ -> Ok 0))) in
  let snapshot = Request.batch_to_json full in
  let refused ?(ledger = Ledger.empty) raw =
    match Request.batch_of_json ~ledger raw with
    | Error (Request.Invalid_batch _) -> ()
    | Error (Request.Invalid_limit | Request.Render_failed _ | Request.Index_unavailable _
           | Request.Measure_failed _ | Request.Exceeds_frame _)
    | Ok _ -> Alcotest.fail "invalid snapshot restored" in
  let input = member "input" snapshot in
  let rows field = match member field input with `List rows -> rows | _ -> Alcotest.fail "input table" in
  let with_rows field rows = replace "input" (replace field (`List rows) input) snapshot in
  refused (with_rows "facts" (List.map (fun fact ->
    if member "id" fact = `String "f1" then replace "claim" (`String "Changed evidence") fact else fact)
    (rows "facts")));
  let disposed = get (Result.map_error Ledger.apply_error_to_string
      (Ledger.apply Ledger.empty ~selected:[a] [{Ledger.fact=a.fact;decision=Ledger.Exclude "already handled"}])) in
  refused ~ledger:disposed snapshot;
  refused (with_rows "new_facts" (List.map (fun row ->
    replace "neighbors" (`List [`String "f1"]) row) (rows "new_facts")));
  let unknown = match snapshot with
    | `Assoc fields -> `Assoc (("schema", `String "duplicate") :: fields)
    | _ -> Alcotest.fail "snapshot object" in
  refused unknown

let test_briefing_reopens_original_chunk_without_early_publication () = with_store (fun root store ->
  let source id : Briefing.source = {id;kind=Briefing.Claim;text="Complete evidence " ^ id} in
  let contract = Briefing.contract ~template:"captured-briefing-template" in
  let prepare sources state = match get (Briefing.prepare ~sources ~contract ~render state) with
    | Briefing.Prepared value -> value
    | Briefing.Unchanged | Briefing.Cleanup _ -> Alcotest.fail "expected briefing work" in
  let prior = source "prior" in
  let published = get (Briefing.accept (prepare [prior] Briefing.empty) ~text:"Old complete publication") in
  let sources = [prior;source "a";source "b";source "c"] in
  let original = some (get (Briefing.narrow ~render (prepare sources published))) in
  let request = Briefing.batch_to_json original in
  owned (retain ~tool:"briefing" ~request_id:"briefing-chunk" ~request store);
  let retained = some (owned (load (Store.create ~root) "briefing-chunk")) in
  let restored = get (Briefing.batch_of_json retained.request) in
  Alcotest.check json "whole original pass and exact chunk survive reopening" request (Briefing.batch_to_json restored);
  let refused raw = match Briefing.batch_of_json raw with
    | Error _ -> () | Ok _ -> Alcotest.fail "changed original pass restored" in
  refused (replace "remaining" (`List []) request);
  refused (replace "input" (replace "previous_summary" (`String "Forged prior summary") (Briefing.input restored)) request);
  (match member "remaining" request with
   | `List rows -> refused (replace "remaining" (`List (List.rev rows)) request)
   | _ -> Alcotest.fail "remaining sources");
  let partial = get (Briefing.accept restored ~text:"Partial evidence summary") in
  (match Briefing.observe ~sources ~contract partial with
   | Briefing.Stale summary -> Alcotest.(check string) "partial does not replace publication" "Old complete publication" summary.text
   | Briefing.Current _ | Briefing.Missing -> Alcotest.fail "original publication lost or published early");
  let next = prepare sources partial in
  let done_ = get (Briefing.accept next ~text:"All original evidence summarized") in
  match Briefing.observe ~sources ~contract done_ with
  | Briefing.Current summary -> Alcotest.(check string) "remaining evidence completes original pass" "All original evidence summarized" summary.text
  | Briefing.Stale _ | Briefing.Missing -> Alcotest.fail "original pass did not finish")

let test_original_destination_and_canonical_input_stay_immutable () = with_store (fun root store ->
  let request = `Assoc ["z", `List [`String "all input"]; "a", `Int 1] in
  owned (retain ~request_id:"same" ~request store);
  let equivalent = `Assoc ["a", `Float 1.; "z", `List [`String "all input"]] in
  owned (retain ~request_id:"same" ~request:equivalent (Store.create ~root));
  let conflicts = [
    (fun () -> retain ~installation_id:"replacement" ~request_id:"same" ~request store);
    (fun () -> retain ~package_id:"replacement" ~request_id:"same" ~request store);
    (fun () -> retain ~tool:"different" ~request_id:"same" ~request store);
    (fun () -> retain ~request_id:"same" ~request:(`Assoc ["changed",`Bool true]) store)] in
  (* Each attempted replacement must leave the original A binding intact. *)
  List.iter (fun change ->
    match change () with
    | Error Owner.Binding_conflict -> ()
    | Error (Owner.Store_unavailable _ | Owner.Invalid_identity _ | Owner.Invalid_request _) | Ok () ->
      Alcotest.fail "original destination or input changed") conflicts;
  owned (retain ~request_id:"same" ~request store);
  let restored = some (owned (load (Store.create ~root) "same")) in
  Alcotest.(check string) "original installation survives A-B-A" "original-installation" restored.installation_id;
  Alcotest.check json "complete canonical input survives" (get (Lane_addon_action.canonical request)) restored.request)

let test_bad_records_and_failed_publication_never_become_absence () = with_store (fun root store ->
  Out_channel.with_open_bin root (fun oc -> output_string oc "storage is a file");
  let request = `Assoc ["evidence", `String "complete"] in
  (match retain ~request_id:"original" ~request store with
   | Error (Owner.Store_unavailable _) -> ()
   | Error (Owner.Binding_conflict | Owner.Invalid_identity _ | Owner.Invalid_request _) | Ok () ->
     Alcotest.fail "unavailable store accepted capture");
  Sys.remove root;
  owned (retain ~request_id:"original" ~request store);
  let original = some (get (Store.load_tool_request_owner store ~scope:"workspace-curator" ~request_id:"original")) in
  let malformed = [replace "request_digest" (`String "wrong") original;
    replace "request" (`Assoc ["evidence", `String "tampered"]) original;
    replace "scope" (`String "other-workspace") original;
    replace "request_id" (`String "other-request") original;
    replace "schema" (`String "unknown") original;
    (match original with `Assoc fields -> `Assoc (("tool",`String "duplicate") :: fields)
     | _ -> Alcotest.fail "stored object")] in
  List.iter (fun bad ->
    get (Store.save_tool_request_owner store ~scope:"workspace-curator" ~request_id:"original" bad);
    (match load (Store.create ~root) "original" with
     | Error (Owner.Store_unavailable _) -> ()
     | Error (Owner.Binding_conflict | Owner.Invalid_identity _ | Owner.Invalid_request _) | Ok _ ->
       Alcotest.fail "damaged original record became absent or valid");
    (match retain ~request_id:"original" ~request store with
     | Error (Owner.Store_unavailable _) -> ()
     | Error (Owner.Binding_conflict | Owner.Invalid_identity _ | Owner.Invalid_request _) | Ok () ->
       Alcotest.fail "damaged fence was replaced");
    Alcotest.check json "failed retain preserves damaged evidence" bad
      (some (get (Store.load_tool_request_owner store ~scope:"workspace-curator" ~request_id:"original")))) malformed;
  List.iter (fun request ->
    (match retain ~request_id:"invalid" ~request store with
     | Error (Owner.Invalid_request _) -> ()
     | Error (Owner.Binding_conflict | Owner.Store_unavailable _ | Owner.Invalid_identity _) | Ok () ->
       Alcotest.fail "invalid JSON captured");
    Alcotest.(check bool) "invalid JSON did not publish a fence" true (owned (load store "invalid") = None))
    [`Assoc ["same",`Int 1; "same",`Int 2]; `Float Float.nan])

let () = Alcotest.run "Workspace Curator retained requests" ["capture", [
  Alcotest.test_case "classification restores exact whole rows and selected effect" `Quick test_classification_reopens_exact_batches_and_applies_only_selected;
  Alcotest.test_case "pending and neighbor owner boundaries" `Quick test_pending_and_neighbor_boundaries_are_strict;
  Alcotest.test_case "briefing resumes original chunk before publication" `Quick test_briefing_reopens_original_chunk_without_early_publication;
  Alcotest.test_case "original destination and canonical input" `Quick test_original_destination_and_canonical_input_stay_immutable;
  Alcotest.test_case "damaged fence and publication failure" `Quick test_bad_records_and_failed_publication_never_become_absence]]
