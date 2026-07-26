let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let contains source needle =
  let source_length = String.length source in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > source_length
    then false
    else if String.sub source offset needle_length = needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let check_contains source needle =
  Alcotest.(check bool) needle true (contains source needle)
;;

let check_not_contains source needle =
  Alcotest.(check bool) needle false (contains source needle)
;;

let test_meta_store_is_witness_boundary () =
  let source = read_file "lib/keeper/keeper_meta_store.ml" in
  check_contains source "Identity_creation_requires_witness";
  check_contains source "Identity_change_requires_witness";
  check_contains source
    "Keeper_lifecycle_nonce.create Keeper_lifecycle_nonce.witness";
  check_contains source
    "Keeper_lifecycle_nonce.replace Keeper_lifecycle_nonce.witness";
  check_contains source
    "Keeper_lifecycle_nonce.recover_exact Keeper_lifecycle_nonce.witness"
;;

let test_generation_is_required_and_positive () =
  let source = read_file "lib/keeper/keeper_meta_json_parse.ml" in
  check_contains source "missing generation in persisted keeper runtime";
  check_contains source
    "persisted keeper generation must be a positive integer";
  check_not_contains source {|json_int ~default:0 "generation"|}
;;

let test_repairs_share_typed_transition () =
  let heartbeat = read_file "lib/keeper/keeper_heartbeat_loop_presence.ml" in
  let tools = read_file "lib/keeper/keeper_tool_surface_ops.ml" in
  check_contains heartbeat
    "Keeper_identity_transition.replace_or_recover_exact";
  check_contains tools "Keeper_identity_transition.replace_or_recover_exact";
  check_not_contains heartbeat "nonce + 1";
  check_not_contains tools "nonce + 1"
;;

let test_ambiguous_reserved_clears_exact_evidence () =
  let source = read_file "lib/keeper/keeper_dead_revival_transaction.ml" in
  check_contains source "clear_journal ctx.config ~expected_stage:Reserved current";
  check_contains source "delete_payload ctx.config current";
  check_not_contains source
    "keeper revival retains payload after ambiguous Reserved publication"
;;

let () =
  Alcotest.run
    "keeper lifecycle identity source"
    [ ( "identity"
      , [ Alcotest.test_case
            "meta store witness boundary"
            `Quick
            test_meta_store_is_witness_boundary
        ; Alcotest.test_case
            "required positive generation"
            `Quick
            test_generation_is_required_and_positive
        ; Alcotest.test_case
            "shared repair transition"
            `Quick
            test_repairs_share_typed_transition
        ; Alcotest.test_case
            "reserved ambiguity cleanup"
            `Quick
            test_ambiguous_reserved_clears_exact_evidence
        ] )
    ]
;;
