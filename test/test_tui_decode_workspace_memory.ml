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

let absence_fields (counts : Decode.absence_counts) =
  [ "facts", `Int counts.facts; "absent", `Int counts.absent
  ; "available_stores", `Int counts.available_stores; "missing_stores", `Int counts.missing_stores ]

let complete_json counts = `Assoc (("status", `String "complete") :: absence_fields counts)
let empty_counts = absence_counts ~facts:0 ~absent:0 ~available_stores:0 ~missing_stores:0
let empty_absence = complete_json empty_counts

let inventory_absence = function
  | Decode.Missing { ordinary_absence; _ } -> ordinary_absence
  | Decode.Available inventory -> inventory.ordinary_absence

let check_absence label expected inventory =
  Alcotest.(check bool) label true (inventory_absence inventory = expected)

let test_roundtrip_missing () =
  let json =
    `Assoc
      [ "schema", `String "workspace.memory.inventory.v1"
      ; "generated_at", `Float 1794037335.0
      ; "status", `String "missing"
      ; "ordinary_absence", empty_absence
      ]
  in
  match Decode.decode_inventory json with
  | Ok (Decode.Missing { generated_at; ordinary_absence }) ->
    Alcotest.(check bool) "known empty ordinary inventory" true
      (ordinary_absence = Decode.Absence_complete empty_counts);
    Alcotest.(check (float 0.001)) "generated_at matches" 1794037335.0 generated_at
  | Ok (Decode.Available _) -> Alcotest.fail "expected Missing, got Available"
  | Error err -> Alcotest.fail ("failed to decode missing inventory: " ^ err)
;;

let test_roundtrip_available_without_building () =
  let json =
    `Assoc
      [ "schema", `String "workspace.memory.inventory.v1"
      ; "generated_at", `Float 1794037335.0
      ; "status", `String "available"
      ; "ordinary_absence", empty_absence
      ; "semantic_verification", `String "not_performed"
      ; "ledger_sha256", `String "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234"
      ; "claim_count", `Int 3
      ; "conflict_count", `Int 1
      ; "excluded_count", `Int 0
      ; "classified_count", `Int 4
      ; "briefing", `Assoc [ "status", `String "pending"; "building", `Null ]
      ]
  in
  match Decode.decode_inventory json with
  | Ok (Decode.Available inv) ->
    Alcotest.(check (float 0.001)) "generated_at matches" 1794037335.0 inv.generated_at;
    Alcotest.(check string) "ledger_sha256 matches"
      "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234" inv.ledger_sha256;
    Alcotest.(check int) "claim_count matches" 3 inv.claim_count;
    Alcotest.(check int) "conflict_count matches" 1 inv.conflict_count;
    Alcotest.(check int) "excluded_count matches" 0 inv.excluded_count;
    Alcotest.(check int) "classified_count matches" 4 inv.classified_count;
    Alcotest.(check bool) "briefing status is pending" true (inv.briefing.status = Decode.Pending);
    Alcotest.(check bool) "building is none" true (inv.briefing.building = None)
  | Ok (Decode.Missing _) -> Alcotest.fail "expected Available, got Missing"
  | Error err -> Alcotest.fail ("failed to decode available inventory: " ^ err)
;;

let test_roundtrip_available_with_building () =
  let json =
    `Assoc
      [ "schema", `String "workspace.memory.inventory.v1"
      ; "generated_at", `Float 1794037335.0
      ; "status", `String "available"
      ; "ordinary_absence", empty_absence
      ; "semantic_verification", `String "not_performed"
      ; "ledger_sha256", `String "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      ; "claim_count", `Int 10
      ; "conflict_count", `Int 2
      ; "excluded_count", `Int 1
      ; "classified_count", `Int 13
      ; ( "briefing"
        , `Assoc
            [ "status", `String "current"
            ; "building", `Assoc [ "target", `Int 5; "remaining", `Int 2 ]
            ] )
      ]
  in
  match Decode.decode_inventory json with
  | Ok (Decode.Available inv) ->
    Alcotest.(check bool) "briefing status is current" true (inv.briefing.status = Decode.Current);
    (match inv.briefing.building with
     | Some pass ->
       Alcotest.(check int) "target matches" 5 pass.target;
       Alcotest.(check int) "remaining matches" 2 pass.remaining
     | None -> Alcotest.fail "expected building pass")
  | _ -> Alcotest.fail "failed to decode building pass"
;;

let test_roundtrip_unavailable_briefing () =
  let json =
    `Assoc
      [ "schema", `String "workspace.memory.inventory.v1"
      ; "generated_at", `Float 1794037335.0
      ; "status", `String "available"
      ; "ordinary_absence", empty_absence
      ; "semantic_verification", `String "not_performed"
      ; "ledger_sha256", `String "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      ; "claim_count", `Int 0
      ; "conflict_count", `Int 0
      ; "excluded_count", `Int 0
      ; "classified_count", `Int 0
      ; "briefing", `Assoc [ "status", `String "unavailable" ]
      ]
  in
  match Decode.decode_inventory json with
  | Ok (Decode.Available inv) ->
    Alcotest.(check bool) "briefing status is unavailable" true (inv.briefing.status = Decode.Unavailable);
    Alcotest.(check bool) "building is none" true (inv.briefing.building = None)
  | _ -> Alcotest.fail "failed to decode unavailable briefing"
;;

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

let test_rejects_unknown_keys_and_invalid_data () =
  let valid_available =
    [ "schema", `String "workspace.memory.inventory.v1"
    ; "generated_at", `Float 1794037335.0
    ; "status", `String "available"
    ; "ordinary_absence", empty_absence
    ; "semantic_verification", `String "not_performed"
    ; "ledger_sha256", `String "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    ; "claim_count", `Int 1
    ; "conflict_count", `Int 0
    ; "excluded_count", `Int 0
    ; "classified_count", `Int 1
    ; "briefing", `Assoc [ "status", `String "pending"; "building", `Null ]
    ]
  in
  let check_rejected label fields =
    match Decode.decode_inventory (`Assoc fields) with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail (label ^ " should have been rejected")
  in
  check_rejected "unknown root key" (("unknown_key", `Int 1) :: valid_available);
  check_rejected "wrong schema" (List.map (fun (k, v) -> if k = "schema" then k, `String "workspace.memory.inventory.v2" else k, v) valid_available);
  check_rejected "negative claim count" (List.map (fun (k, v) -> if k = "claim_count" then k, `Int (-1) else k, v) valid_available);
  check_rejected "unexpected verification" (List.map (fun (k, v) -> if k = "semantic_verification" then k, `String "verified" else k, v) valid_available);
  check_rejected "unknown briefing key"
    (List.map (fun (k, v) ->
      if k = "briefing" then
        k, `Assoc [ "status", `String "pending"; "building", `Null; "extra", `Bool true ]
      else k, v) valid_available);
  check_rejected "remaining exceeds target"
    (List.map (fun (k, v) ->
      if k = "briefing" then
        k, `Assoc [ "status", `String "pending"; "building", `Assoc [ "target", `Int 2; "remaining", `Int 5 ] ]
      else k, v) valid_available);
  check_rejected "unavailable briefing with building"
    (List.map (fun (k, v) ->
      if k = "briefing" then
        k, `Assoc [ "status", `String "unavailable"; "building", `Null ]
      else k, v) valid_available)
;;

let test_absence_contract () =
  let measured = absence_counts ~facts:3 ~absent:1 ~available_stores:2 ~missing_stores:1 in
  let partial = `Assoc (("status", `String "partial") :: ("unavailable_stores", `Int 1) :: absence_fields measured) in
  let unavailable = `Assoc ["status", `String "unavailable"; "detail", `String "discovery failed"] in
  let available absence =
    `Assoc [ "schema", `String "workspace.memory.inventory.v1"; "generated_at", `Int 1
      ; "status", `String "available"; "semantic_verification", `String "not_performed"
      ; "ledger_sha256", `String (String.make 64 'a'); "claim_count", `Int 0
      ; "conflict_count", `Int 0; "excluded_count", `Int 0; "classified_count", `Int 0
      ; "briefing", `Assoc ["status", `String "pending"; "building", `Null]
      ; "ordinary_absence", absence ] in
  List.iter (fun (json, expected) ->
    check_absence "closed absence state survives the wire" expected (available json |> Decode.decode_inventory |> require))
    [ complete_json measured, Decode.Absence_complete measured
    ; partial, Decode.Absence_partial { counts = measured; unavailable_stores = 1 }
    ; `Assoc (("status", `String "partial") :: ("unavailable_stores", `Int 1) :: absence_fields empty_counts),
      Decode.Absence_partial { counts = empty_counts; unavailable_stores = 1 }
    ; unavailable, Decode.Absence_unavailable "discovery failed" ];
  let replace key value = function
    | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "fixture must be an object" in
  let reject label json = match Decode.decode_inventory json with
    | Error _ -> ()
    | Ok (Decode.Missing _ | Decode.Available _) -> Alcotest.fail (label ^ " was accepted") in
  (match available empty_absence with
   | `Assoc fields -> reject "required hard-cut field" (`Assoc (List.remove_assoc "ordinary_absence" fields))
   | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "fixture must be an object");
  reject "missing inventory requires the hard-cut field"
    (`Assoc ["schema", `String "workspace.memory.inventory.v1"; "generated_at", `Int 1; "status", `String "missing"]);
  let complete = complete_json measured in
  List.iter (fun (label, absence) -> reject label (available absence))
    ([ "unknown status", replace "status" (`String "guessed") complete
     ; "unknown field", replace "extra" (`Bool true) complete
     ; "absent exceeds facts", replace "absent" (`Int 4) complete
     ; "facts without an available store", replace "available_stores" (`Int 0) complete
     ; "fractional fact count", replace "facts" (`Float 3.5) complete
     ; "partial without failed store", replace "unavailable_stores" (`Int 0) partial
     ; "negative failed stores", replace "unavailable_stores" (`Int (-1)) partial
     ; "complete with partial field", replace "unavailable_stores" (`Int 1) complete
     ; "blank failure cause", replace "detail" (`String " ") unavailable
     ; "unavailable with counts", replace "facts" (`Int 0) unavailable ]
     @ List.map (fun field -> "negative " ^ field, replace field (`Int (-1)) complete)
         ["facts"; "absent"; "available_stores"; "missing_stores"]);
  List.iter (fun absence ->
    reject "missing ledger with classified ordinary facts"
      (`Assoc ["schema", `String "workspace.memory.inventory.v1"; "generated_at", `Int 1
        ; "status", `String "missing"; "ordinary_absence", absence]))
    [complete; partial]
;;

let () =
  Alcotest.run "tui_decode_workspace_memory"
    [ ( "decode_inventory"
      , [ Alcotest.test_case "missing inventory roundtrip" `Quick test_roundtrip_missing
        ; Alcotest.test_case "available inventory without building" `Quick test_roundtrip_available_without_building
        ; Alcotest.test_case "available inventory with building" `Quick test_roundtrip_available_with_building
        ; Alcotest.test_case "unavailable briefing" `Quick test_roundtrip_unavailable_briefing
        ; Alcotest.test_case "actual View.inventory roundtrip" `Quick test_actual_view_inventory_roundtrip
        ; Alcotest.test_case "rejects unknown keys and invalid data" `Quick test_rejects_unknown_keys_and_invalid_data
        ; Alcotest.test_case "strict ordinary absence contract" `Quick test_absence_contract
        ] )
    ]
;;
