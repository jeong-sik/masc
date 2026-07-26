open Keeper_dead_revival_payload_types

let exact_read_operation_to_string = function
  | Fs_compat.Capability_exact_read.Pin_parent -> "pin_parent"
  | Open_parent_descriptor -> "open_parent_descriptor"
  | Open_leaf -> "open_leaf"
  | Inspect_opened -> "inspect_opened"
  | Allocate -> "allocate"
  | Read_exact -> "read_exact"
  | Inspect_after_read -> "inspect_after_read"
  | Close_leaf -> "close_leaf"
  | Settle_parent_resources -> "settle_parent_resources"
  | Observe_parent_cancellation -> "observe_parent_cancellation"
;;

let exact_read_error_to_string = function
  | Fs_compat.Capability_exact_read.Invalid_leaf detail ->
    "invalid leaf: " ^ detail
  | Invalid_length_bounds { expected_length; max_length } ->
    Printf.sprintf
      "invalid length bounds expected=%Ld max=%Ld"
      expected_length
      max_length
  | Length_not_representable length ->
    Printf.sprintf "length is not representable: %Ld" length
  | Cancelled diagnostic ->
    Printf.sprintf
      "%s cancelled: %s"
      (exact_read_operation_to_string diagnostic.operation)
      diagnostic.detail
  | Parent_descriptor_unavailable ->
    "parent descriptor is unavailable"
  | Missing -> "payload is missing"
  | Symbolic_link -> "payload is a symbolic link"
  | Not_regular _ -> "payload is not a regular file"
  | Unsafe_link_count count ->
    Printf.sprintf "payload has unsafe link count: %d" count
  | Unsafe_mode mode ->
    Printf.sprintf "payload has unsafe mode: 0o%o" mode
  | Length_exceeds_max { max_length; observed_length } ->
    Printf.sprintf
      "payload length exceeds representation limit max=%Ld observed=%Ld"
      max_length
      observed_length
  | Length_mismatch { expected_length; observed_length } ->
    Printf.sprintf
      "payload length mismatch expected=%Ld observed=%Ld"
      expected_length
      observed_length
  | Changed_during_read -> "payload changed during read"
  | Io_error diagnostic ->
    Printf.sprintf
      "%s failed: %s"
      (exact_read_operation_to_string diagnostic.operation)
      diagnostic.detail
;;

let create_reconciliation_failure_to_string = function
  | Reconciliation_read_failed failure ->
    "exact reread failed: "
    ^ exact_read_error_to_string failure.error
  | Reconciliation_read_settlement_failed warnings ->
    Printf.sprintf
      "exact reread settlement failed warning_count=%d"
      (List.length warnings)
  | Reconciliation_read_injected detail ->
    "exact reread injected failure: " ^ detail
  | Reconciliation_parent_sync_failed failure ->
    "parent durability sync failed: "
    ^ Fs_compat.capability_directory_sync_error_to_string failure
  | Reconciliation_parent_sync_injected detail ->
    "parent durability sync injected failure: " ^ detail
;;

let error_to_string = function
  | Invalid_binding detail -> "invalid revival payload binding: " ^ detail
  | Malformed_payload detail -> "malformed revival payload: " ^ detail
  | Unsupported_payload_schema schema ->
    "unsupported revival payload schema: " ^ schema
  | Noncanonical_payload -> "revival payload is not exact canonical JSON"
  | Malformed_ref detail -> "malformed revival payload ref: " ^ detail
  | Unsupported_ref_schema schema ->
    "unsupported revival payload ref schema: " ^ schema
  | Noncanonical_ref -> "revival payload ref is not exact canonical JSON"
  | Filesystem_capability_unavailable ->
    "revival payload filesystem capability is unavailable"
  | Directory_prepare_failed detail ->
    "revival payload directory preparation failed: " ^ detail
  | Parent_open_failed detail ->
    "revival payload parent open failed: " ^ detail
  | Create_conflict { initial_failure; _ } ->
    "revival payload create found conflicting immutable bytes after: "
    ^ Fs_compat.capability_write_error_to_string initial_failure
  | Create_unsettled { initial_failure; _ } ->
    "revival payload create left an unsettled target requiring cleanup: "
    ^ Fs_compat.capability_write_error_to_string initial_failure
  | Create_reconciliation_failed
      { initial_failure; reconciliation_failure; _ } ->
    "revival payload create reconciliation failed after "
    ^ Fs_compat.capability_write_error_to_string initial_failure
    ^ ": "
    ^ create_reconciliation_failure_to_string
        reconciliation_failure
  | Read_failed failure ->
    "revival payload read failed: "
    ^ exact_read_error_to_string failure.error
  | Read_settlement_failed warnings ->
    Printf.sprintf
      "revival payload read settlement failed warning_count=%d"
      (List.length warnings)
  | Payload_digest_mismatch -> "revival payload digest mismatch"
  | Payload_binding_mismatch -> "revival payload binding mismatch"
  | Delete_failed failure ->
    "revival payload delete failed: "
    ^ Keeper_fs.durable_remove_error_to_string failure
  | Inventory_failed detail ->
    "revival payload inventory failed: " ^ detail
;;
