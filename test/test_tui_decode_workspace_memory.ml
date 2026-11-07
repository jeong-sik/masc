module Decode = Masc.Tui_decode_workspace_memory
module Ledger = Masc.Workspace_memory_ledger
module View = Masc.Workspace_memory_ledger_view

let require = function
  | Ok v -> v
  | Error err -> Alcotest.fail err
;;

let test_roundtrip_missing () =
  let json =
    `Assoc
      [ "schema", `String "workspace.memory.inventory.v1"
      ; "generated_at", `Float 1794037335.0
      ; "status", `String "missing"
      ]
  in
  match Decode.decode_inventory json with
  | Ok (Decode.Missing { generated_at }) ->
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
    (* 1. Missing ledger *)
    let missing_json = View.inventory ~now:1794037335.0 ~base_path |> require in
    (match Decode.decode_inventory missing_json with
     | Ok (Decode.Missing { generated_at }) ->
       Alcotest.(check (float 0.001)) "missing generated_at matches" 1794037335.0 generated_at
     | _ -> Alcotest.fail "failed to decode actual View.inventory missing output");
    (* 2. Empty saved ledger *)
    Ledger.save ~base_path Ledger.empty |> require;
    let available_json = View.inventory ~now:1794037335.0 ~base_path |> require in
    match Decode.decode_inventory available_json with
    | Ok (Decode.Available inv) ->
      Alcotest.(check int) "claims 0" 0 inv.claim_count;
      Alcotest.(check int) "conflicts 0" 0 inv.conflict_count;
      Alcotest.(check int) "excluded 0" 0 inv.excluded_count;
      Alcotest.(check bool) "briefing is current (empty evidence)" true (inv.briefing.status = Decode.Current);
      Alcotest.(check bool) "no building pass" true (inv.briefing.building = None)
    | _ -> Alcotest.fail "failed to decode actual View.inventory available output")
;;

let test_rejects_unknown_keys_and_invalid_data () =
  let valid_available =
    [ "schema", `String "workspace.memory.inventory.v1"
    ; "generated_at", `Float 1794037335.0
    ; "status", `String "available"
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

let () =
  Alcotest.run "tui_decode_workspace_memory"
    [ ( "decode_inventory"
      , [ Alcotest.test_case "missing inventory roundtrip" `Quick test_roundtrip_missing
        ; Alcotest.test_case "available inventory without building" `Quick test_roundtrip_available_without_building
        ; Alcotest.test_case "available inventory with building" `Quick test_roundtrip_available_with_building
        ; Alcotest.test_case "unavailable briefing" `Quick test_roundtrip_unavailable_briefing
        ; Alcotest.test_case "actual View.inventory roundtrip" `Quick test_actual_view_inventory_roundtrip
        ; Alcotest.test_case "rejects unknown keys and invalid data" `Quick test_rejects_unknown_keys_and_invalid_data
        ] )
    ]
;;
