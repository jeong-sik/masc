module Decode = Masc.Tui_decode_workspace_memory
module Ledger = Masc.Workspace_memory_ledger
module View = Masc.Workspace_memory_ledger_view
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types

let require = function
  | Ok v -> v
  | Error err -> Alcotest.fail err
;;

let absence_counts ~facts ~absent ~available_stores ~missing_stores : Decode.absence_counts =
  { facts; absent; available_stores; missing_stores }

let inventory_absence = function
  | Decode.Missing { ordinary_absence; _ } -> ordinary_absence
  | Decode.Available inventory -> inventory.ordinary_absence

let check_absence label expected inventory =
  Alcotest.(check bool) label true (inventory_absence inventory = expected)

let test_actual_view_inventory_roundtrip () =
  let base_path = Filename.temp_dir "test-tui-decode-wm-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let read () = View.inventory ~now:1794037335.0 ~base_path () |> require
      |> Decode.decode_inventory |> require in
    let unavailable = function
      | Decode.Absence_unavailable detail -> Alcotest.(check bool) "discovery failure has a cause" true (String.trim detail <> "")
      | Decode.Absence_complete _ | Decode.Absence_partial _ -> Alcotest.fail "discovery failure became measured counts" in
    (* A missing Keeper directory is failed discovery, not an empty census. *)
    let initial = read () in
    (match initial with
     | Decode.Missing { generated_at; ordinary_absence } ->
         Alcotest.(check (float 0.001)) "missing generated_at matches" 1794037335.0 generated_at;
         unavailable ordinary_absence
     | Decode.Available _ -> Alcotest.fail "expected missing ledger");
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    Fs_compat.mkdir_p keepers_dir;
    let save_ordinary keeper_id claims =
      let origin : Memory.origin = { kind = Memory.Authored; trace_id = "fixture" } in
      let facts = List.map (fun claim -> Memory.observed ~claim ~category:Memory.Fact ~now:1. ~origin) claims in
      let snapshot : Current.t =
        { revision = 1; updated_at = 1.; source = { kind = Current.Explicit_write; trace_id = "fixture" }
        ; facts; change = { added = facts; removed = []; retained = 0; invalidated = [] } } in
      Fs_compat.save_file (Current.path_for_keepers_dir ~keepers_dir ~keeper_id)
        (Yojson.Safe.to_string (Current.to_json snapshot)) in
    save_ordinary "reader" [];
    Fs_compat.save_file (Filename.concat keepers_dir "no-snapshot.toml")
      "[keeper]\nname = \"no-snapshot\"\ninstructions = \"fixture\"\n";
    let known_empty = absence_counts ~facts:0 ~absent:0 ~available_stores:1 ~missing_stores:1 in
    check_absence "empty snapshot and missing snapshot stay distinct"
      (Decode.Absence_complete known_empty) (read ());
    save_ordinary "reader" ["First observation"; "Second observation"];
    let unclassified = absence_counts ~facts:2 ~absent:2 ~available_stores:1 ~missing_stores:1 in
    check_absence "missing ledger leaves every readable ordinary fact absent"
      (Decode.Absence_complete unclassified) (read ());
    Ledger.save ~base_path Ledger.empty |> require;
    (match read () with
    | Decode.Available inv ->
      Alcotest.(check int) "claims 0" 0 inv.claim_count;
      Alcotest.(check int) "conflicts 0" 0 inv.conflict_count;
      Alcotest.(check int) "excluded 0" 0 inv.excluded_count;
      Alcotest.(check bool) "briefing is current (empty evidence)" true (inv.briefing.status = Decode.Current);
      Alcotest.(check bool) "no building pass" true (inv.briefing.building = None);
      Alcotest.(check bool) "available empty ledger keeps ordinary counts" true
        (inv.ordinary_absence = Decode.Absence_complete unclassified)
    | Decode.Missing _ -> Alcotest.fail "saved ledger became missing");
    Fs_compat.save_file (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"broken") "{broken";
    check_absence "corrupt store keeps readable lower bounds and unavailable-store count"
      (Decode.Absence_partial { counts = unclassified; unavailable_stores = 1 }) (read ());
    Fs_compat.remove_tree keepers_dir;
    Fs_compat.save_file keepers_dir "not a directory";
    unavailable (inventory_absence (read ())))
;;

let () =
  Alcotest.run "tui_decode_workspace_memory_journal"
    [ ( "decode_inventory"
      , [ Alcotest.test_case "actual View.inventory roundtrip" `Quick test_actual_view_inventory_roundtrip
        ] )
    ]
;;
