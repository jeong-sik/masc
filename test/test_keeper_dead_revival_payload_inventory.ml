open Alcotest
open Test_keeper_dead_revival_payload_support

let find_shard_for_keeper shards keeper_name =
  match
    List.find_opt
      (fun shard ->
         Payload.authority_shard_matches_keeper shard ~keeper_name)
      shards
  with
  | Some shard -> shard
  | None -> failf "inventory shard missing for %s" keeper_name
;;

let test_root_shard_and_transaction_inventory () =
  with_workspace "masc_dead_revival_payload_inventory_" @@ fun config ->
  let initial =
    Payload.inventory_authority_shards config
    |> require_payload_ok "inventory absent payload root"
  in
  check int "absent root inventory" 0 (List.length initial);
  (* Direct payload creation precedes any Reserved journal publication. *)
  let first =
    make_fixture
      ~keeper_name:"inventory-orphan"
      ~candidate_nonce:8
      config
  in
  let second =
    make_fixture
      ~keeper_name:"inventory-orphan"
      ~candidate_nonce:9
      config
  in
  ignore (create_first first);
  ignore (create_first second);
  let shards =
    Payload.inventory_authority_shards config
    |> require_payload_ok "inventory orphan authority shard"
  in
  check int "one orphan authority shard" 1 (List.length shards);
  let shard = find_shard_for_keeper shards first.keeper_name in
  check
    string
    "opaque orphan shard leaf"
    first.authority_leaf
    (Payload.authority_shard_leaf shard);
  let transactions =
    Payload.inventory_transactions config shard
    |> require_payload_ok "inventory orphan transactions"
  in
  check int "two orphan transactions" 2 (List.length transactions);
  let expected_order =
    [ independent_transaction_leaf first.transaction_id, first.transaction_id
    ; independent_transaction_leaf second.transaction_id, second.transaction_id
    ]
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
    |> List.map snd
  in
  List.iter2
    (fun inventory transaction_id ->
       check
         bool
         "transaction inventory order and binding"
         true
         (Payload.inventory_transaction_matches
            inventory
            ~transaction_id))
    transactions
    expected_order;
  let other =
    make_fixture ~keeper_name:"inventory-other" config
  in
  ignore (create_first other);
  let all_shards =
    Payload.inventory_authority_shards config
    |> require_payload_ok "inventory multiple authority shards"
  in
  check
    (list string)
    "authority shards sorted"
    (List.sort
       String.compare
       [ first.authority_leaf; other.authority_leaf ])
    (List.map Payload.authority_shard_leaf all_shards);
  let other_shard =
    find_shard_for_keeper all_shards other.keeper_name
  in
  let first_inventory = List.hd transactions in
  Payload.delete_inventory_transaction
    config
    ~authority_shard:other_shard
    first_inventory
  |> expect_error
       "inventory delete rejects swapped shard"
       (function Payload.Invalid_binding _ -> true | _ -> false);
  Payload.delete_inventory_transaction
    config
    ~authority_shard:shard
    first_inventory
  |> require_payload_ok "delete opaque orphan transaction";
  Payload.delete_inventory_transaction
    config
    ~authority_shard:shard
    first_inventory
  |> require_payload_ok "repeat opaque orphan delete"
;;

let test_inventory_rejects_invalid_entries () =
  with_workspace "masc_dead_revival_payload_inventory_invalid_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let root = payload_root config in
  let invalid_root = Filename.concat root "unexpected-entry" in
  write_file invalid_root "invalid";
  Payload.inventory_authority_shards config
  |> expect_error
       "reject invalid payload-root entry"
       (function Payload.Inventory_failed _ -> true | _ -> false);
  Sys.remove invalid_root;
  let non_directory_authority =
    Filename.concat
      root
      (independent_authority_leaf "non-directory-authority")
  in
  write_file non_directory_authority "invalid";
  Payload.inventory_authority_shards config
  |> expect_error
       "reject non-directory authority entry"
       (function Payload.Inventory_failed _ -> true | _ -> false);
  Sys.remove non_directory_authority;
  let invalid_transaction =
    Filename.concat (shard_directory fixture) "unexpected-entry"
  in
  write_file invalid_transaction "invalid";
  Payload.inventory_transactions config fixture.authority_shard
  |> expect_error
       "reject invalid transaction entry"
       (function Payload.Inventory_failed _ -> true | _ -> false);
  Sys.remove invalid_transaction;
  let recovered =
    Payload.inventory_transactions config fixture.authority_shard
    |> require_payload_ok "inventory after invalid entry removal"
  in
  check int "valid transaction remains" 1 (List.length recovered)
;;

let test_large_metadata_roundtrip () =
  with_workspace "masc_dead_revival_payload_large_" @@ fun config ->
  let large = String.make (1_048_576 + 16_384) 'x' in
  let fixture =
    make_fixture ~candidate_instructions:large config
  in
  check
    bool
    "payload exceeds one MiB"
    true
    (Int64.compare
       (Payload.immutable_ref_byte_count fixture.reference)
       1_048_576L
     > 0);
  ignore (create_first fixture);
  let observed =
    read_bound fixture fixture.reference
    |> require_payload_ok "read large metadata payload"
  in
  let observed_instructions =
    (Payload.payload_candidate observed).instructions
  in
  check
    int
    "large metadata length"
    (String.length large)
    (String.length observed_instructions);
  check
    string
    "large metadata digest"
    (sha256 large)
    (sha256 observed_instructions);
  Payload.delete
    config
    ~keeper_name:fixture.keeper_name
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    fixture.reference
  |> require_payload_ok "delete large metadata payload"
;;
