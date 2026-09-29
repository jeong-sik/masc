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

let () = Alcotest.run "workspace memory ledger view"
  [ "summary consistency",
    [ Alcotest.test_case "atomic replacement never mixes versions" `Quick
        test_atomic_replacement_never_mixes_summary_versions;
      Alcotest.test_case "missing and corrupt remain distinct" `Quick
        test_summary_does_not_hide_missing_or_corrupt_ledger ] ]
