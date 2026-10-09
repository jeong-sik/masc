module Ledger = Masc.Workspace_memory_ledger
module View = Masc.Workspace_memory_ledger_view

let require = function Ok value -> value | Error detail -> Alcotest.fail detail

let ledger claims =
  let selected : Ledger.pending_fact list = List.map (fun claim ->
    { Ledger.fact = Ledger.Ordinary { keeper_id = "writer";
        claim_sha256 = Digestif.SHA256.(digest_string claim |> to_hex) }; claim }) claims in
  let assignments : Ledger.assignment list = List.map (fun (row : Ledger.pending_fact) ->
    { Ledger.fact = row.fact; decision = Ledger.Create_claim row.claim }) selected in
  match Ledger.apply Ledger.empty ~selected assignments with
  | Ok value -> value
  | Error error -> Alcotest.fail (Ledger.apply_error_to_string error)

let with_base f =
  let base_path = Filename.temp_dir "workspace-ledger-view-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () -> f base_path)

let check_summary label expected response =
  let open Yojson.Safe.Util in
  let expected_sha256 = Digestif.SHA256.(digest_string
    (Yojson.Safe.to_string (Ledger.to_json expected)) |> to_hex) in
  Alcotest.(check string) (label ^ " binds its exact content") expected_sha256
    (response |> member "ledger_sha256" |> to_string);
  Alcotest.(check int) (label ^ " counts that same content")
    (List.length (Ledger.dispositions expected))
    (response |> member "classified_count" |> to_int);
  Alcotest.(check (list string)) (label ^ " exposes that snapshot's claims")
    (List.map snd (Ledger.claims expected))
    (response |> member "claims" |> to_list
     |> List.map (fun row -> row |> member "text" |> to_string));
  Alcotest.(check int) (label ^ " groups each member exactly once")
    (List.length (Ledger.dispositions expected))
    (response |> member "claims" |> to_list
     |> List.fold_left (fun count row -> count + (row |> member "members" |> to_list |> List.length)) 0)

let test_atomic_replacement_never_mixes_summary_versions () = with_base (fun base_path ->
  let before = ledger ["Original observation"] in
  let after = ledger ["Replacement observation"; "Another new observation"] in
  Ledger.save ~base_path before |> require;
  View.summary ~base_path |> require |> check_summary "initial summary" before;
  let loads = ref 0 in
  (* The callback runs only after the real descriptor read. This is the
     deterministic interleaving of a concurrent atomic save and the second
     read, without sleeps or a probabilistic scheduling assertion. *)
  let replace_then_load ~base_path =
    incr loads;
    Ledger.save ~base_path after |> require;
    Ledger.load ~base_path in
  (match View.For_testing.summary_with_load ~load:replace_then_load ~base_path with
   | Error detail -> Alcotest.(check string) "concurrent replacement is explicit"
       "workspace ledger changed during the read" detail
   | Ok _ -> Alcotest.fail "summary mixed the old descriptor with replacement contents");
  Alcotest.(check int) "no hidden retry of the changing ledger" 1 !loads;
  (* The reader reports its failure; it must not roll back the writer. An
     ordinary later read can coherently observe the newly committed ledger. *)
  View.summary ~base_path |> require |> check_summary "later summary" after)

let test_summary_does_not_hide_missing_or_corrupt_ledger () = with_base (fun base_path ->
  let missing = View.summary ~base_path |> require in
  Alcotest.(check string) "missing is explicit" "missing"
    Yojson.Safe.Util.(missing |> member "status" |> to_string);
  Ledger.save ~base_path (ledger ["Retained observation"]) |> require;
  Fs_compat.save_file (Filename.concat (Ledger.directory ~base_path) "ledger.json") "{broken";
  match View.summary ~base_path with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a corrupt ledger became a successful empty summary")

let test_deferred_inventory_and_selected_search () = with_base (fun base_path ->
  let database = ledger ["Orchid release freezes require owner approval.";
                         "Walrus tournament standings changed."] in
  Ledger.save ~base_path database |> require;
  let open Yojson.Safe.Util in
  let inventory = View.inventory ~base_path |> require in
  Alcotest.(check int) "inventory counts retained claims" 2
    (inventory |> member "claim_count" |> to_int);
  Alcotest.(check bool) "inventory has no claim bodies" true
    (inventory |> member "claims" = `Null);
  let results = View.search ~base_path ~query:"Orchid" ~limit:5 |> require in
  let matches = results |> member "matches" |> to_list in
  Alcotest.(check int) "unrelated context stays deferred" 1 (List.length matches);
  let selected = List.hd matches in
  Alcotest.(check string) "relevant claim retrieved intact"
    "Orchid release freezes require owner approval."
    (selected |> member "text" |> to_string);
  let selected_id = selected |> member "id" |> to_string in
  Alcotest.(check bool) "the ID resolves in this exact ledger" true
    (List.mem_assoc selected_id (Ledger.claims database));
  Alcotest.(check string) "search identifies its source snapshot"
    (inventory |> member "ledger_sha256" |> to_string)
    (results |> member "ledger_sha256" |> to_string);
  let absent = View.search ~base_path ~query:"Cobalt" ~limit:5 |> require in
  Alcotest.(check int) "no match does not enumerate memory" 0
    (absent |> member "matches" |> to_list |> List.length);
  View.summary ~base_path |> require |> check_summary "explicit full index" database)

let test_short_queries_remain_retrievable () = with_base (fun base_path ->
  Ledger.save ~base_path (ledger ["배포 전에 승인을 확인한다."; "CI requires the current head.";
                                 "Unrelated orchard observations."]) |> require;
  List.iter (fun query ->
    let result = View.search ~base_path ~query ~limit:5 |> require in
    Alcotest.(check int) (query ^ " is searchable despite trigram length") 1
      Yojson.Safe.Util.(result |> member "matches" |> to_list |> List.length)) ["배포"; "CI"])

let test_index_failure_preserves_matching_without_filler () = with_base (fun base_path ->
  let literal = ["CI deploy requires approval."; "CI deploy happened yesterday."] in
  let all_terms = ["deploy waits for CI approval."; "CI checks gate the deploy."] in
  let database = ledger (literal @ all_terms @
    ["CI unrelated checks."; "Unrelated orchard observations."]) in
  Ledger.save ~base_path database |> require;
  let stored = List.map snd (Ledger.claims database) in
  let expected = List.filter (fun text -> List.mem text literal) stored
    @ List.filter (fun text -> List.mem text all_terms) stored in
  let attempts = ref 0 in
  let rank ~query:_ texts =
    incr attempts;
    Alcotest.(check (list string)) "the failing index receives the actual ledger order"
      stored texts;
    Error (Masc.Keeper_memory_search_index.Index_unavailable "fixture: FTS5 unavailable") in
  let open Yojson.Safe.Util in
  let search query limit =
    View.For_testing.search_with_rank ~rank ~base_path ~query ~limit |> require in
  let texts result = result |> member "matches" |> to_list
    |> List.map (fun row -> row |> member "text" |> to_string) in
  let result = search "CI deploy" 10 in
  Alcotest.(check (list string)) "literal then all-term matches retain store order"
    expected (texts result);
  Alcotest.(check int) "partial and unrelated matches do not fill the result" 4
    (result |> member "total_matches" |> to_int);
  let limited = search "CI deploy" 3 in
  Alcotest.(check (list string)) "the caller limit applies after fallback selection"
    (List.take 3 expected) (texts limited);
  Alcotest.(check int) "total matches remains independent of the result limit" 4
    (limited |> member "total_matches" |> to_int);
  let absent = search "Cobalt" 10 in
  Alcotest.(check (list string)) "index failure with no lexical matches returns no filler"
    [] (texts absent);
  Alcotest.(check int) "each search exercised actual index failure" 3 !attempts;
  Fs_compat.save_file (Filename.concat (Ledger.directory ~base_path) "ledger.json") "{broken";
  (match View.For_testing.search_with_rank ~rank ~base_path ~query:"CI deploy" ~limit:10 with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "index fallback hid a corrupt authoritative ledger");
  Alcotest.(check int) "corrupt ledger fails before index dispatch" 3 !attempts)

let test_resolved_snapshot_serves_many_ids_without_rereading () = with_base (fun base_path ->
  let database = ledger (List.init 200 (fun i -> Printf.sprintf "Observation %d" i)) in
  Ledger.save ~base_path database |> require;
  let snapshot = View.resolve_snapshot ~base_path |> require in
  (* Make any hidden disk re-read fail. The caller can still inspect the exact
     snapshot it judged, but a fresh publication check must observe corruption. *)
  Fs_compat.save_file (Filename.concat (Ledger.directory ~base_path) "ledger.json") "{broken";
  List.iter (fun (id,text) ->
    let detail = View.detail_in_snapshot snapshot ~id |> require in
    Alcotest.(check string) "snapshot keeps the selected claim bound to its ID" text
      Yojson.Safe.Util.(detail |> member "text" |> to_string)) (Ledger.claims database);
  match View.resolve_snapshot ~base_path with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "fresh source resolution hid authoritative corruption")

let () = Alcotest.run "workspace memory ledger view"
  [ "summary consistency",
    [ Alcotest.test_case "atomic replacement never mixes versions" `Quick
        test_atomic_replacement_never_mixes_summary_versions;
      Alcotest.test_case "missing and corrupt remain distinct" `Quick
        test_summary_does_not_hide_missing_or_corrupt_ledger;
      Alcotest.test_case "inventory defers bodies and search selects context" `Quick
        test_deferred_inventory_and_selected_search;
      Alcotest.test_case "short Korean and ASCII queries remain retrievable" `Quick
        test_short_queries_remain_retrievable;
      Alcotest.test_case "index failure preserves matches without filler" `Quick
        test_index_failure_preserves_matching_without_filler;
      Alcotest.test_case "200 IDs reuse one immutable resolution" `Quick
        test_resolved_snapshot_serves_many_ids_without_rereading ] ]
