open Keeper_meta_contract
open Keeper_types_profile

module Head = Fs_compat.Capability_head
module Payload = Keeper_dead_revival_payload

type boundary_hooks =
  { after_nonce_allocation : unit -> unit
  ; after_journal_write : unit -> unit
  }

let boundary_hooks_key : boundary_hooks Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let reserved_publication_failure_key : unit Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

type cleanup_direction =
  [ `Forward
  | `Rollback
  ]

type cleanup_boundary_hooks =
  { after_cleanup_pending : cleanup_direction -> string option
  ; after_payload_delete : cleanup_direction -> string option
  }

let cleanup_boundary_hooks_key : cleanup_boundary_hooks Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let final_clear_failure_hook : (unit -> string option) Atomic.t =
  Atomic.make (fun () -> None)
;;

let before_recovery_claim_hook : (unit -> unit) Atomic.t =
  Atomic.make (fun () -> ())
;;

let durable_compare_and_swap_hook =
  Atomic.make Head.compare_and_swap
;;

let launch_compare_and_swap_hook =
  Atomic.make Head.compare_and_swap
;;

let fd_backed_parent_opening_key : unit Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let with_head_parent parent fn =
  match Eio.Fiber.get fd_backed_parent_opening_key with
  | Some () -> Eio.Path.with_open_dir parent fn
  | None -> fn parent
;;

let invoke_after_nonce_allocation_hook () =
  match Eio.Fiber.get boundary_hooks_key with
  | None -> ()
  | Some hooks -> hooks.after_nonce_allocation ()
;;

let invoke_after_journal_write_hook () =
  match Eio.Fiber.get boundary_hooks_key with
  | None -> ()
  | Some hooks -> hooks.after_journal_write ()
;;

let invoke_after_cleanup_pending_hook direction =
  match Eio.Fiber.get cleanup_boundary_hooks_key with
  | None -> None
  | Some hooks -> hooks.after_cleanup_pending direction
;;

let invoke_after_payload_delete_hook direction =
  match Eio.Fiber.get cleanup_boundary_hooks_key with
  | None -> None
  | Some hooks -> hooks.after_payload_delete direction
;;

let invoke_final_clear_failure_hook () =
  (Atomic.get final_clear_failure_hook) ()
;;

let invoke_before_recovery_claim_hook () =
  (Atomic.get before_recovery_claim_hook) ()
;;

module Boundary_hooks_for_testing = struct
  let with_boundary_hooks
        ?(after_nonce_allocation = fun () -> ())
        ?(after_journal_write = fun () -> ())
        fn
    =
    Eio.Fiber.with_binding
      boundary_hooks_key
      { after_nonce_allocation; after_journal_write }
      fn
  ;;

  let with_reserved_publication_failure fn =
    Eio.Fiber.with_binding reserved_publication_failure_key () fn
  ;;

  let with_cleanup_boundary_hooks
        ?(after_cleanup_pending = fun _ -> None)
        ?(after_payload_delete = fun _ -> None)
        fn
    =
    Eio.Fiber.with_binding
      cleanup_boundary_hooks_key
      { after_cleanup_pending; after_payload_delete }
      fn
  ;;

  let with_final_clear_failure ~detail fn =
    let previous =
      Atomic.exchange final_clear_failure_hook (fun () -> Some detail)
    in
    Fun.protect
      ~finally:(fun () -> Atomic.set final_clear_failure_hook previous)
      fn
  ;;

  let with_recovery_claim_hook ~before_recovery_claim fn =
    let previous =
      Atomic.exchange before_recovery_claim_hook before_recovery_claim
    in
    Fun.protect
      ~finally:(fun () -> Atomic.set before_recovery_claim_hook previous)
      fn
  ;;

  let with_durable_publication_settlement_warning fn =
    let hooks =
      Head.For_testing.hooks
        ~on_resource_settlement:(fun () ->
          failwith "injected revival durable publication settlement warning")
        ()
    in
    let previous =
      Atomic.exchange
        durable_compare_and_swap_hook
        (Head.For_testing.compare_and_swap hooks)
    in
    Fun.protect
      ~finally:(fun () -> Atomic.set durable_compare_and_swap_hook previous)
      fn
  ;;

  let with_launch_publication_settlement_warning fn =
    let hooks =
      Head.For_testing.hooks
        ~on_resource_settlement:(fun () ->
          failwith "injected revival launch publication settlement warning")
        ()
    in
    let previous =
      Atomic.exchange
        launch_compare_and_swap_hook
        (Head.For_testing.compare_and_swap hooks)
    in
    Fun.protect
      ~finally:(fun () -> Atomic.set launch_compare_and_swap_hook previous)
      fn
  ;;

  let with_fd_backed_parent_opening fn =
    Eio.Fiber.with_binding fd_backed_parent_opening_key () fn
  ;;
end

type registry_conflict =
  | Registry_phase_conflict of Keeper_state_machine.phase
  | Registry_identity_conflict of
      { expected_trace_id : Keeper_id.Trace_id.t
      ; expected_generation : int
      ; actual_trace_id : Keeper_id.Trace_id.t
      ; actual_generation : int
      }
  | Registry_dead_lane_not_settled
  | Registry_remove_missing
  | Registry_remove_replaced

type rollback_error =
  | Rollback_meta_missing
  | Rollback_meta_identity_changed
  | Rollback_meta_payload_changed
  | Rollback_meta_write_failed of string
  | Rollback_registry_occupied of Keeper_registry.registry_entry
  | Rollback_registry_invalid of Keeper_registry.registry_entry_validation_error
  | Rollback_registry_reservation_changed of Keeper_lifecycle_reservation.snapshot
  | Rollback_payload_delete_failed of Payload.error
  | Rollback_journal_clear_failed of string

type payload_operation =
  | Payload_prepare
  | Payload_create
  | Payload_verify
  | Payload_delete

type error =
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Nonce_allocation_failed of Keeper_lifecycle_nonce.error
  | Journal_conflict of string
  | Journal_ownership_changed of string
  | Journal_publication_indeterminate of Head.failure
  | Journal_published_with_failure of Head.failure
  | Journal_published_with_warnings of
      { evidence : Head.publication_evidence
      ; warnings : Head.settlement_warning list
      }
  | Journal_read_settlement_failed of Head.settlement_warning list
  | Journal_write_failed of string
  | Payload_operation_failed of
      { operation : payload_operation
      ; failure : Payload.error
      }
  | Transaction_lock_failed of File_lock_eio.durable_lock_error
  | Post_commit_cleanup_required of
      { committed : keeper_meta
      ; entry : Keeper_registry.registry_entry
      ; cleanup_error : error
      }
  | Durable_snapshot_missing
  | Durable_snapshot_changed
  | Registry_conflict of registry_conflict
  | Durable_commit_failed of string
  | Durable_commit_unreadable of string
  | Launch_failed of Keeper_keepalive.start_keepalive_outcome
  | Rollback_failed of
      { cause : string
      ; errors : rollback_error list
      }

type success =
  { meta : keeper_meta
  ; entry : Keeper_registry.registry_entry
  }

type journal_stage =
  | Reserved
  | Durable_committed
  | Launch_committed
  | Rollback_reserved
  | Rollback_durable_committed
  | Forward_cleanup_pending
  | Rollback_cleanup_pending
  | Cleared

type journal =
  { transaction_id : string
  ; owner_id : string
  ; keeper_name : string
  ; expected_trace_id : Keeper_id.Trace_id.t
  ; expected_generation : int
  ; payload_ref : Payload.immutable_ref
  ; stage : journal_stage
  }

type cleared_journal =
  { transaction_id : string
  ; keeper_name : string
  }

type journal_row =
  | Active_journal of journal
  | Cleared_tombstone of cleared_journal

type recovery_summary =
  { recovered : int
  ; cleared : int
  ; unresolved : (string * string) list
  }

let journal_dir config =
  Filename.concat (Workspace.masc_root_dir config) "keeper-lifecycle-transactions"
;;

let journal_schema = "masc.keeper-dead-revival-journal.v2"
let head_entropy_bytes = 32 * 33

let sha256 value =
  Digestif.SHA256.(to_hex (digest_string value))
;;

let length_delimited value =
  Printf.sprintf "%d:%s" (String.length value) value
;;

let journal_leaf keeper_name =
  "revival-"
  ^ sha256
      ("keeper-dead-revival-journal-leaf-v1\000"
       ^ length_delimited keeper_name)
  ^ ".json"
;;

let journal_transaction_id
      ~owner_id
      ~keeper_name
      ~expected_trace_id
      ~expected_generation
      ~candidate_nonce
  =
  [ "keeper-dead-revival-transaction-v1"
  ; length_delimited owner_id
  ; length_delimited keeper_name
  ; length_delimited
      (Keeper_id.Trace_id.to_string expected_trace_id)
  ; string_of_int expected_generation
  ; string_of_int candidate_nonce
  ]
  |> String.concat "\000"
  |> sha256
;;

let journal_stage_to_json = function
  | Reserved -> `Assoc [ "reserved", `Bool true ]
  | Durable_committed -> `Assoc [ "durable_committed", `Bool true ]
  | Launch_committed -> `Assoc [ "launch_committed", `Bool true ]
  | Rollback_reserved -> `Assoc [ "rollback_reserved", `Bool true ]
  | Rollback_durable_committed ->
    `Assoc [ "rollback_durable_committed", `Bool true ]
  | Forward_cleanup_pending ->
    `Assoc [ "forward_cleanup_pending", `Bool true ]
  | Rollback_cleanup_pending ->
    `Assoc [ "rollback_cleanup_pending", `Bool true ]
  | Cleared -> `Assoc [ "cleared", `Bool true ]
;;

let journal_to_json journal =
  let stage =
    match journal.stage with
    | Cleared ->
      invalid_arg "active keeper revival journal cannot have Cleared stage"
    | stage -> journal_stage_to_json stage
  in
  `Assoc
    [ "schema", `String journal_schema
    ; "transaction_id", `String journal.transaction_id
    ; "owner_id", `String journal.owner_id
    ; "keeper_name", `String journal.keeper_name
    ; "expected_trace_id", `String (Keeper_id.Trace_id.to_string journal.expected_trace_id)
    ; "expected_generation", `Int journal.expected_generation
    ; "payload_ref", Payload.immutable_ref_to_json journal.payload_ref
    ; "stage", stage
    ]
;;

let cleared_journal_to_json tombstone =
  `Assoc
    [ "schema", `String journal_schema
    ; "transaction_id", `String tombstone.transaction_id
    ; "keeper_name", `String tombstone.keeper_name
    ; "stage", journal_stage_to_json Cleared
    ]
;;

let journal_row_to_json = function
  | Active_journal journal -> journal_to_json journal
  | Cleared_tombstone tombstone -> cleared_journal_to_json tombstone
;;

let journal_to_bytes journal =
  Yojson.Safe.to_string (journal_to_json journal)
;;

let journal_row_to_bytes row =
  Yojson.Safe.to_string (journal_row_to_json row)
;;

let exact_fields ~kind expected fields =
  let expected = List.sort String.compare expected in
  let observed =
    List.map fst fields
    |> List.sort String.compare
  in
  if List.equal String.equal expected observed
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields differ expected=[%s] observed=[%s]"
         kind
         (String.concat "," expected)
         (String.concat "," observed))
;;

let exact_active_journal_fields fields =
  exact_fields
    ~kind:"active journal"
    [ "schema"
    ; "transaction_id"
    ; "owner_id"
    ; "keeper_name"
    ; "expected_trace_id"
    ; "expected_generation"
    ; "payload_ref"
    ; "stage"
    ]
    fields
;;

let exact_cleared_journal_fields fields =
  exact_fields
    ~kind:"cleared journal"
    [ "schema"; "transaction_id"; "keeper_name"; "stage" ]
    fields
;;

let required_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value) when not (String.equal (String.trim value) "") -> Ok value
  | Some _ -> Error (Printf.sprintf "journal field %s must be a non-empty string" key)
  | None -> Error (Printf.sprintf "journal field %s is missing" key)
;;

let required_sha256 key fields =
  let ( let* ) = Result.bind in
  let* value = required_string key fields in
  match Digestif.SHA256.consistent_of_hex_opt value with
  | Some digest
    when String.equal value (Digestif.SHA256.to_hex digest) ->
    Ok value
  | Some _ | None ->
    Error
      (Printf.sprintf
         "journal field %s must be a lowercase SHA-256"
         key)
;;

let required_int key fields =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Ok value
  | Some _ -> Error (Printf.sprintf "journal field %s must be an integer" key)
  | None -> Error (Printf.sprintf "journal field %s is missing" key)
;;

let required_stage fields =
  match List.assoc_opt "stage" fields with
  | Some (`Assoc [ ("reserved", `Bool true) ]) -> Ok Reserved
  | Some (`Assoc [ ("durable_committed", `Bool true) ]) -> Ok Durable_committed
  | Some (`Assoc [ ("launch_committed", `Bool true) ]) -> Ok Launch_committed
  | Some (`Assoc [ ("rollback_reserved", `Bool true) ]) ->
    Ok Rollback_reserved
  | Some (`Assoc [ ("rollback_durable_committed", `Bool true) ]) ->
    Ok Rollback_durable_committed
  | Some (`Assoc [ ("forward_cleanup_pending", `Bool true) ]) ->
    Ok Forward_cleanup_pending
  | Some (`Assoc [ ("rollback_cleanup_pending", `Bool true) ]) ->
    Ok Rollback_cleanup_pending
  | Some (`Assoc [ ("cleared", `Bool true) ]) -> Ok Cleared
  | Some _ -> Error "journal stage must contain exactly one known constructor"
  | None -> Error "journal field stage is missing"
;;

let required_payload_ref key fields =
  match List.assoc_opt key fields with
  | None -> Error (Printf.sprintf "journal field %s is missing" key)
  | Some json ->
    Payload.immutable_ref_of_json json
    |> Result.map_error Payload.error_to_string
;;

let journal_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* schema = required_string "schema" fields in
    let* stage = required_stage fields in
    if not (String.equal schema journal_schema)
    then Error ("unsupported keeper lifecycle journal schema: " ^ schema)
    else (
      match stage with
      | Cleared ->
        let* () = exact_cleared_journal_fields fields in
        let* transaction_id = required_sha256 "transaction_id" fields in
        let* keeper_name = required_string "keeper_name" fields in
        Ok (Cleared_tombstone { transaction_id; keeper_name })
      | ( Reserved
        | Durable_committed
        | Launch_committed
        | Rollback_reserved
        | Rollback_durable_committed
        | Forward_cleanup_pending
        | Rollback_cleanup_pending ) as stage ->
        let* () = exact_active_journal_fields fields in
        let* transaction_id = required_sha256 "transaction_id" fields in
        let* owner_id = required_string "owner_id" fields in
        let* keeper_name = required_string "keeper_name" fields in
        let* trace_id_raw = required_string "expected_trace_id" fields in
        let* expected_trace_id = Keeper_id.Trace_id.of_string trace_id_raw in
        let* expected_generation = required_int "expected_generation" fields in
        let* payload_ref = required_payload_ref "payload_ref" fields in
        let* shard =
          Payload.authority_shard_for_keeper ~keeper_name
          |> Result.map_error Payload.error_to_string
        in
        let* transaction_leaf =
          Payload.transaction_leaf_for_id ~transaction_id
          |> Result.map_error Payload.error_to_string
        in
        if
          not
            (String.equal
               (Payload.immutable_ref_authority_leaf payload_ref)
               (Payload.authority_shard_leaf shard))
        then Error "journal payload authority differs from its keeper binding"
        else if
          not
            (String.equal
               (Payload.immutable_ref_transaction_leaf payload_ref)
               transaction_leaf)
        then Error "journal payload slot differs from its transaction binding"
        else
          Ok
            (Active_journal
               { transaction_id
               ; owner_id
               ; keeper_name
               ; expected_trace_id
               ; expected_generation
               ; payload_ref
               ; stage
               }))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "keeper lifecycle journal must be a JSON object"
;;

let journal_of_bytes raw =
  try
    Result.bind
      (journal_of_json (Yojson.Safe.from_string raw))
      (fun row ->
         if String.equal raw (journal_row_to_bytes row)
         then Ok row
         else Error "journal row is not exact canonical JSON")
  with
  | Yojson.Json_error detail -> Error detail
;;

let reraise_fatal exception_ backtrace =
  match exception_ with
  | Out_of_memory | Stack_overflow | Sys.Break ->
    Printexc.raise_with_backtrace exception_ backtrace
  | _ -> ()
;;

let revival_authority_lock_path config authority_leaf =
  try
    let dir = Keeper_fs.ensure_dir (journal_dir config) in
    let lock_leaf =
      "authority-"
      ^ sha256
          ("keeper-dead-revival-authority-lock-v1\000"
           ^ length_delimited authority_leaf)
      ^ ".lock"
    in
    Ok (Filename.concat dir lock_leaf)
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exception_ backtrace;
    Error
      (Journal_write_failed
         ("transaction lock directory preparation failed: "
          ^ Printexc.to_string exception_))
;;

let journal_parent config =
  try
    let dir = Keeper_fs.ensure_dir (journal_dir config) in
    match Fs_compat.get_fs_opt () with
    | None -> Error (Journal_write_failed "filesystem capability is unavailable")
    | Some fs -> Ok Eio.Path.(fs / dir)
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exception_ backtrace;
    Error
      (Journal_write_failed
         ("journal directory preparation failed: "
          ^ Printexc.to_string exception_))
;;

let journal_entropy () =
  try
    Ok (Eio.Flow.string_source (Crypto_rng.generate head_entropy_bytes))
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exception_ backtrace;
    Error
      (Journal_write_failed
         ("journal entropy source failed: " ^ Printexc.to_string exception_))
;;

let head_failure_to_string (failure : Head.failure) =
  match failure.error with
  | Head.Invalid_leaf detail -> "invalid journal leaf: " ^ detail
  | Invalid_row detail -> "invalid journal row: " ^ detail
  | Busy -> "journal authority is busy"
  | Conflict _ -> "journal authority changed concurrently"
  | Corrupt_lock detail -> "corrupt journal lock: " ^ detail
  | Corrupt_head detail -> "corrupt journal HEAD: " ^ detail
  | Unsupported detail -> "unsupported journal filesystem operation: " ^ detail
  | Io_error diagnostic -> "journal I/O failed: " ^ diagnostic.detail
;;

let settlement_warning_detail count =
  Printf.sprintf "journal authority settled with %d warning(s)" count
;;

let journal_row_keeper_name = function
  | Active_journal journal -> journal.keeper_name
  | Cleared_tombstone tombstone -> tombstone.keeper_name
;;

let journal_row_transaction_id = function
  | Active_journal journal -> journal.transaction_id
  | Cleared_tombstone tombstone -> tombstone.transaction_id
;;

let read_journal_leaf ~invalid config ~leaf ~expected_keeper_name =
  match journal_parent config with
  | Error error -> Error error
  | Ok parent ->
    (match journal_entropy () with
     | Error error -> Error error
     | Ok secure_random ->
       (match
          with_head_parent parent (fun parent ->
            Head.read
              ~secure_random
              ~parent
              ~leaf)
        with
        | Error failure ->
          Error (Journal_write_failed (head_failure_to_string failure))
        | Ok snapshot ->
          let warnings = Head.snapshot_settlement_warnings snapshot in
          if warnings <> []
          then
            Error (Journal_read_settlement_failed warnings)
          else
            (match Head.snapshot_row snapshot with
             | None -> Ok (parent, snapshot, None)
             | Some raw ->
               (match journal_of_bytes raw with
                | Error detail -> Error (invalid detail)
                | Ok row
                  when not
                         (String.equal
                            (journal_leaf (journal_row_keeper_name row))
                            leaf) ->
                  Error (invalid "journal keeper binding differs from its hashed leaf")
                | Ok row ->
                  (match expected_keeper_name with
                   | Some keeper_name
                     when not
                            (String.equal
                               (journal_row_keeper_name row)
                               keeper_name) ->
                     Error (invalid "journal keeper binding differs from request")
                   | Some _ | None -> Ok (parent, snapshot, Some row))))))
;;

let read_current_journal ~invalid config keeper_name =
  read_journal_leaf
    ~invalid
    config
    ~leaf:(journal_leaf keeper_name)
    ~expected_keeper_name:(Some keeper_name)
;;

let publication_error ~conflict (failure : Head.failure) =
  let detail = head_failure_to_string failure in
  match failure.target_effect with
  | Head.Unchanged ->
    (match failure.error with
     | Head.Conflict _ -> conflict detail
     | _ -> Journal_write_failed detail)
  | Published _ -> Journal_published_with_failure failure
  | Publication_indeterminate _ ->
    Journal_publication_indeterminate failure
;;

let publish_row
      ?(compare_and_swap = Head.compare_and_swap)
      ~conflict
      ~parent
      ~snapshot
      ~row
      ()
  =
  let keeper_name = journal_row_keeper_name row in
  match journal_entropy () with
  | Error error -> Error error
  | Ok secure_random ->
    (match
       with_head_parent parent (fun parent ->
         compare_and_swap
           ~secure_random
           ~parent
           ~leaf:(journal_leaf keeper_name)
           ~expected:(Head.snapshot_cursor snapshot)
           ~row:(journal_row_to_bytes row))
     with
     | Error failure -> Error (publication_error ~conflict failure)
     | Ok publication ->
       let warnings = Head.publication_settlement_warnings publication in
       if warnings = []
       then Ok ()
       else
         Error
           (Journal_published_with_warnings
              { evidence = Head.publication_evidence publication
              ; warnings
              }))
;;

let same_transaction (left : journal) (right : journal) =
  String.equal left.transaction_id right.transaction_id
  && String.equal left.owner_id right.owner_id
  && String.equal left.keeper_name right.keeper_name
  && Keeper_id.Trace_id.equal
       left.expected_trace_id
       right.expected_trace_id
  && Int.equal left.expected_generation right.expected_generation
  && String.equal
       (Payload.immutable_ref_to_bytes left.payload_ref)
       (Payload.immutable_ref_to_bytes right.payload_ref)
;;

type durable_publication_observation =
  | Durable_publication_rollback_from of journal_stage
  | Durable_publication_attention of error

let observe_durable_publication config (expected : journal) =
  match
    read_current_journal
      ~invalid:(fun detail -> Journal_ownership_changed detail)
      config
      expected.keeper_name
  with
  | Error error -> Durable_publication_attention error
  | Ok (_, _, None) ->
    Durable_publication_attention
      (Journal_ownership_changed
         "durable publication journal authority disappeared")
  | Ok (_, _, Some (Cleared_tombstone _)) ->
    Durable_publication_attention
      (Journal_ownership_changed
         "durable publication settled to a cleared transaction")
  | Ok (_, _, Some (Active_journal (current : journal)))
    when not (same_transaction current expected) ->
    Durable_publication_attention
      (Journal_ownership_changed
         "durable publication settled to another active transaction")
  | Ok (_, _, Some (Active_journal (current : journal))) ->
    (match current.stage with
     | Reserved
     | Durable_committed ->
       Durable_publication_rollback_from current.stage
     | Launch_committed
     | Forward_cleanup_pending
     | Rollback_reserved
     | Rollback_durable_committed
     | Rollback_cleanup_pending
     | Cleared ->
       Durable_publication_attention
         (Journal_ownership_changed
            ("durable publication settled to conflicting stage "
             ^ Yojson.Safe.to_string (journal_stage_to_json current.stage))))
;;

type launch_publication_observation =
  | Launch_publication_committed
  | Launch_publication_not_committed
  | Launch_publication_attention of error

let observe_launch_publication config (expected : journal) =
  match
    read_current_journal
      ~invalid:(fun detail -> Journal_ownership_changed detail)
      config
      expected.keeper_name
  with
  | Error error -> Launch_publication_attention error
  | Ok (_, _, None) ->
    Launch_publication_attention
      (Journal_ownership_changed
         "launch publication journal authority disappeared")
  | Ok (_, _, Some (Cleared_tombstone tombstone))
    when String.equal tombstone.transaction_id expected.transaction_id
         && String.equal tombstone.keeper_name expected.keeper_name ->
    Launch_publication_committed
  | Ok (_, _, Some (Cleared_tombstone _)) ->
    Launch_publication_attention
      (Journal_ownership_changed
         "launch publication settled to another cleared transaction")
  | Ok (_, _, Some (Active_journal (current : journal)))
    when not (same_transaction current expected) ->
    Launch_publication_attention
      (Journal_ownership_changed
         "launch publication settled to another active transaction")
  | Ok (_, _, Some (Active_journal (current : journal))) ->
    (match current.stage with
     | Launch_committed
     | Forward_cleanup_pending -> Launch_publication_committed
     | Durable_committed -> Launch_publication_not_committed
     | Reserved
     | Rollback_reserved
     | Rollback_durable_committed
     | Rollback_cleanup_pending
     | Cleared ->
       Launch_publication_attention
         (Journal_ownership_changed
            ("launch publication settled to conflicting stage "
             ^ Yojson.Safe.to_string (journal_stage_to_json current.stage))))
;;

let reserve_journal config (journal : journal) =
  match
    read_current_journal
      ~invalid:(fun detail -> Journal_conflict detail)
      config
      journal.keeper_name
  with
  | Error error -> Error error
  | Ok (_, _, Some (Active_journal existing)) ->
    Error
      (Journal_conflict
         (Printf.sprintf
            "unresolved journal transaction=%s remains stage=%s"
            existing.transaction_id
            (Yojson.Safe.to_string (journal_stage_to_json existing.stage))))
  | Ok (parent, snapshot, None)
  | Ok (parent, snapshot, Some (Cleared_tombstone _)) ->
    let compare_and_swap =
      match Eio.Fiber.get reserved_publication_failure_key with
      | None -> Head.compare_and_swap
      | Some () ->
        let hooks =
          Head.For_testing.hooks
            ~after_verified:(fun () ->
              failwith "injected Reserved journal post-publication failure")
            ()
        in
        Head.For_testing.compare_and_swap hooks
    in
    publish_row
      ~compare_and_swap
      ~conflict:(fun detail -> Journal_conflict detail)
      ~parent
      ~snapshot
      ~row:(Active_journal journal)
      ()
;;

let transition_journal ?compare_and_swap config ~expected_stage (journal : journal) =
  match
    read_current_journal
      ~invalid:(fun detail -> Journal_ownership_changed detail)
      config
      journal.keeper_name
  with
  | Error error -> Error error
  | Ok (_, _, None) ->
    Error (Journal_ownership_changed "journal authority is missing")
  | Ok (_, _, Some (Cleared_tombstone _)) ->
    Error (Journal_ownership_changed "journal authority is already cleared")
  | Ok (_, _, Some (Active_journal current))
    when current.stage <> expected_stage
         || not (same_transaction current journal) ->
    Error
      (Journal_ownership_changed
         "journal authority is not the expected transaction stage")
  | Ok (parent, snapshot, Some (Active_journal _)) ->
    publish_row
      ?compare_and_swap
      ~conflict:(fun detail -> Journal_ownership_changed detail)
      ~parent
      ~snapshot
      ~row:(Active_journal journal)
      ()
;;

let save_journal config (journal : journal) =
  match journal.stage with
  | Reserved -> reserve_journal config journal
  | Durable_committed ->
    transition_journal
      ~compare_and_swap:(Atomic.get durable_compare_and_swap_hook)
      config
      ~expected_stage:Reserved
      journal
  | Launch_committed ->
    transition_journal config ~expected_stage:Durable_committed journal
  | Rollback_reserved | Rollback_durable_committed ->
    Error
      (Journal_write_failed
         "rollback claim stages are owned by startup recovery")
  | Forward_cleanup_pending | Rollback_cleanup_pending ->
    Error
      (Journal_write_failed
         "cleanup claim stages require an exact predecessor")
  | Cleared ->
    Error (Journal_write_failed "Cleared is not a publishable revival stage")
;;

let save_launch_journal config journal =
  transition_journal
    ~compare_and_swap:(Atomic.get launch_compare_and_swap_hook)
    config
    ~expected_stage:Durable_committed
    journal
;;

let clear_journal config ~expected_stage (journal : journal) =
  match
    read_current_journal
      ~invalid:(fun detail -> Journal_ownership_changed detail)
      config
      journal.keeper_name
  with
  | Error error -> Error error
  | Ok (_, _, None) ->
    Error (Journal_ownership_changed "journal authority disappeared before clear")
  | Ok (_, _, Some (Cleared_tombstone tombstone))
    when String.equal tombstone.transaction_id journal.transaction_id
         && String.equal tombstone.keeper_name journal.keeper_name ->
    Ok ()
  | Ok (_, _, Some (Cleared_tombstone _)) ->
    Error
      (Journal_ownership_changed
         "cleared journal authority belongs to a different transaction")
  | Ok (_, _, Some (Active_journal current))
    when not (same_transaction current journal) ->
    Error
      (Journal_ownership_changed
         "journal authority belongs to a different transaction")
  | Ok (_, _, Some (Active_journal current))
    when current.stage <> expected_stage ->
    Error
      (Journal_ownership_changed
         "journal authority advanced beyond the expected clear stage")
  | Ok (parent, snapshot, Some (Active_journal current)) ->
    publish_row
      ~conflict:(fun detail -> Journal_ownership_changed detail)
      ~parent
      ~snapshot
      ~row:
        (Cleared_tombstone
           { transaction_id = current.transaction_id
           ; keeper_name = current.keeper_name
           })
      ()
;;

type recovery_claim =
  | Recovery_rollback_claimed of journal_stage * bool
  | Recovery_forward_complete of journal_stage
  | Recovery_already_cleared

let rec claim_recovery_rollback config journal attempts =
  if attempts <= 0
  then
    Error
      (Journal_ownership_changed
         "journal authority did not settle while recovery claimed rollback")
  else
    match
      read_current_journal
        ~invalid:(fun detail -> Journal_ownership_changed detail)
        config
        journal.keeper_name
    with
    | Error error -> Error error
    | Ok (_, _, None) ->
      Error (Journal_ownership_changed "journal authority disappeared before claim")
    | Ok (_, _, Some (Cleared_tombstone tombstone))
      when String.equal tombstone.transaction_id journal.transaction_id ->
      Ok Recovery_already_cleared
    | Ok (_, _, Some (Cleared_tombstone _)) ->
      Error
        (Journal_ownership_changed
           "journal authority belongs to a different cleared transaction")
    | Ok (_, _, Some (Active_journal current))
      when not (same_transaction current journal) ->
      Error
        (Journal_ownership_changed
           "journal authority belongs to a different transaction")
    | Ok (_, _, Some (Active_journal current))
      when current.stage = Launch_committed
           || current.stage = Forward_cleanup_pending ->
      Ok (Recovery_forward_complete current.stage)
    | Ok (_, _, Some (Active_journal current))
      when current.stage = Rollback_reserved ->
      Ok (Recovery_rollback_claimed (current.stage, false))
    | Ok (_, _, Some (Active_journal current))
      when current.stage = Rollback_durable_committed ->
      Ok (Recovery_rollback_claimed (current.stage, true))
    | Ok (_, _, Some (Active_journal current))
      when current.stage = Rollback_cleanup_pending ->
      Ok (Recovery_rollback_claimed (current.stage, true))
    | Ok (parent, snapshot, Some (Active_journal current)) ->
      let claimed_stage, durable_committed =
        match current.stage with
        | Reserved -> Rollback_reserved, false
        | Durable_committed -> Rollback_durable_committed, true
        | Launch_committed
        | Forward_cleanup_pending
        | Rollback_reserved
        | Rollback_durable_committed
        | Rollback_cleanup_pending
        | Cleared ->
          assert false
      in
      let claimed = { current with stage = claimed_stage } in
      (match
         publish_row
           ~conflict:(fun detail -> Journal_ownership_changed detail)
           ~parent
           ~snapshot
           ~row:(Active_journal claimed)
           ()
       with
       | Ok () -> Ok (Recovery_rollback_claimed (claimed.stage, durable_committed))
       | Error (Journal_ownership_changed _) ->
         claim_recovery_rollback config journal (attempts - 1)
       | Error error -> Error error)
;;

let make_reserved_journal ~owner_id ~original ~candidate ~payload_ref =
  let transaction_id =
    journal_transaction_id
      ~owner_id
      ~keeper_name:original.name
      ~expected_trace_id:original.runtime.trace_id
      ~expected_generation:original.runtime.nonce
      ~candidate_nonce:candidate.runtime.nonce
  in
  { transaction_id
  ; owner_id
  ; keeper_name = original.name
  ; expected_trace_id = original.runtime.trace_id
  ; expected_generation = original.runtime.nonce
  ; payload_ref
  ; stage = Reserved
  }
;;

let make_prepared_journal ~owner_id ~original ~candidate =
  let transaction_id =
    journal_transaction_id
      ~owner_id
      ~keeper_name:original.name
      ~expected_trace_id:original.runtime.trace_id
      ~expected_generation:original.runtime.nonce
      ~candidate_nonce:candidate.runtime.nonce
  in
  let ( let* ) = Result.bind in
  let* payload =
    Payload.make_payload
      ~transaction_id
      ~owner_id
      ~keeper_name:original.name
      ~expected_trace_id:original.runtime.trace_id
      ~expected_generation:original.runtime.nonce
      ~original
      ~candidate
  in
  let* prepared = Payload.prepare payload in
  Ok
    ( make_reserved_journal
        ~owner_id
        ~original
        ~candidate
        ~payload_ref:(Payload.prepared_ref prepared)
    , prepared )
;;

let verify_payload config (journal : journal) =
  Payload.read
    config
    ~expected_ref:journal.payload_ref
    ~expected_authority_leaf:
      (Payload.immutable_ref_authority_leaf journal.payload_ref)
    ~transaction_id:journal.transaction_id
    ~owner_id:journal.owner_id
    ~keeper_name:journal.keeper_name
    ~expected_trace_id:journal.expected_trace_id
    ~expected_generation:journal.expected_generation
;;

module For_testing = struct
  include Boundary_hooks_for_testing

  let reserved_journal_row ~owner_id ~original ~candidate =
    match make_prepared_journal ~owner_id ~original ~candidate with
    | Ok (journal, _) -> journal_to_bytes journal
    | Error failure -> invalid_arg (Payload.error_to_string failure)
  ;;

  let create_and_verify_payload config journal prepared =
    match Payload.create config prepared with
    | Error failure ->
      Error
        (Payload_operation_failed
           { operation = Payload_create; failure })
    | Ok (Payload.Created _ | Payload.Reconciled_created _) ->
      (match verify_payload config journal with
       | Ok _ -> Ok ()
       | Error failure ->
         Error
           (Payload_operation_failed
              { operation = Payload_verify; failure }))
  ;;

  let reserve_journal ~config ~owner_id ~original ~candidate =
    match make_prepared_journal ~owner_id ~original ~candidate with
    | Error failure ->
      Error
        (Payload_operation_failed
           { operation = Payload_prepare; failure })
    | Ok (journal, prepared) ->
      (match create_and_verify_payload config journal prepared with
       | Error _ as error -> error
       | Ok () ->
         (match save_journal config journal with
          | Ok () -> Ok (journal_to_bytes journal)
          | Error error -> Error error))
  ;;

  let current_journal_row ~config ~keeper_name =
    match
      read_current_journal
        ~invalid:(fun detail -> Journal_ownership_changed detail)
        config
        keeper_name
    with
    | Error error -> Error error
    | Ok (_, _, None) -> Ok None
    | Ok (_, _, Some row) -> Ok (Some (journal_row_to_bytes row))
  ;;

  let current_journal_stage ~config ~keeper_name =
    match
      read_current_journal
        ~invalid:(fun detail -> Journal_ownership_changed detail)
        config
        keeper_name
    with
    | Error error -> Error error
    | Ok (_, _, None) -> Ok `Missing
    | Ok (_, _, Some (Active_journal { stage = Reserved; _ })) -> Ok `Reserved
    | Ok (_, _, Some (Active_journal { stage = Durable_committed; _ })) ->
      Ok `Durable_committed
    | Ok (_, _, Some (Active_journal { stage = Launch_committed; _ })) ->
      Ok `Launch_committed
    | Ok (_, _, Some (Active_journal { stage = Rollback_reserved; _ })) ->
      Ok `Rollback_reserved
    | Ok
        (_, _, Some (Active_journal { stage = Rollback_durable_committed; _ })) ->
      Ok `Rollback_durable_committed
    | Ok (_, _, Some (Active_journal { stage = Forward_cleanup_pending; _ })) ->
      Ok `Forward_cleanup_pending
    | Ok (_, _, Some (Active_journal { stage = Rollback_cleanup_pending; _ })) ->
      Ok `Rollback_cleanup_pending
    | Ok (_, _, Some (Active_journal { stage = Cleared; _ })) ->
      Error
        (Journal_ownership_changed
           "active journal unexpectedly carries Cleared stage")
    | Ok (_, _, Some (Cleared_tombstone _)) -> Ok `Cleared
  ;;

  let replace_with_reserved_journal
        ~config
        ~owner_id
        ~original
        ~candidate
    =
    match make_prepared_journal ~owner_id ~original ~candidate with
    | Error failure ->
      Error
        (Payload_operation_failed
           { operation = Payload_prepare; failure })
    | Ok (replacement, prepared) ->
    (match
      read_current_journal
        ~invalid:(fun detail -> Journal_ownership_changed detail)
        config
        original.name
    with
    | Error error -> Error error
    | Ok (_, _, None) ->
      Error (Journal_ownership_changed "test replacement source is missing")
    | Ok (parent, snapshot, Some _) ->
      (match create_and_verify_payload config replacement prepared with
       | Error _ as error -> error
       | Ok () ->
         publish_row
           ~conflict:(fun detail -> Journal_ownership_changed detail)
           ~parent
           ~snapshot
           ~row:(Active_journal replacement)
           ()))
  ;;

  let advance_to_launch_committed ~config ~keeper_name =
    match
      read_current_journal
        ~invalid:(fun detail -> Journal_ownership_changed detail)
        config
        keeper_name
    with
    | Error error -> Error error
    | Ok (_, _, None) ->
      Error (Journal_ownership_changed "test launch source is missing")
    | Ok (_, _, Some (Cleared_tombstone _)) ->
      Error (Journal_ownership_changed "test launch source is already cleared")
    | Ok (parent, snapshot, Some (Active_journal current)) ->
      publish_row
        ~conflict:(fun detail -> Journal_ownership_changed detail)
        ~parent
        ~snapshot
        ~row:(Active_journal { current with stage = Launch_committed })
        ()
  ;;
end
;;

let same_identity (a : keeper_meta) (b : keeper_meta) =
  Keeper_id.Trace_id.equal a.runtime.trace_id b.runtime.trace_id
  && Int.equal a.runtime.nonce b.runtime.nonce
;;

let same_persisted_payload (a : keeper_meta) (b : keeper_meta) =
  Keeper_meta_json.meta_to_json { a with meta_version = 0 }
  = Keeper_meta_json.meta_to_json { b with meta_version = 0 }
;;

let registry_conflict_to_string = function
  | Registry_phase_conflict phase ->
    Printf.sprintf "registry phase is %s, expected Dead" (Keeper_state_machine.phase_to_string phase)
  | Registry_identity_conflict
      { expected_trace_id
      ; expected_generation
      ; actual_trace_id
      ; actual_generation
      } ->
    Printf.sprintf
      "registry identity changed expected=%s/%d actual=%s/%d"
      (Keeper_id.Trace_id.to_string expected_trace_id)
      expected_generation
      (Keeper_id.Trace_id.to_string actual_trace_id)
      actual_generation
  | Registry_dead_lane_not_settled -> "registry Dead lane has not settled"
  | Registry_remove_missing -> "registry Dead lane disappeared before owned removal"
  | Registry_remove_replaced -> "registry Dead lane was replaced before owned removal"
;;

let rollback_error_to_string = function
  | Rollback_meta_missing -> "durable metadata disappeared during rollback"
  | Rollback_meta_identity_changed -> "durable keeper identity changed during rollback"
  | Rollback_meta_payload_changed -> "durable metadata changed after revival commit"
  | Rollback_meta_write_failed detail -> "durable rollback write failed: " ^ detail
  | Rollback_registry_occupied entry ->
    Printf.sprintf
      "registry rollback preserved occupied lane phase=%s lane=%s"
      (Keeper_state_machine.phase_to_string entry.phase)
      (Keeper_lane.Id.to_string (Keeper_lane.id entry.lane))
  | Rollback_registry_invalid error ->
    "registry rollback rejected original entry: "
    ^ Keeper_registry.registry_entry_validation_error_to_string error
  | Rollback_registry_reservation_changed owner ->
    "registry rollback lost reservation ownership: "
    ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Rollback_payload_delete_failed failure ->
    "revival payload cleanup failed: " ^ Payload.error_to_string failure
  | Rollback_journal_clear_failed detail -> "journal clear failed: " ^ detail
;;

let payload_operation_to_string = function
  | Payload_prepare -> "prepare"
  | Payload_create -> "create"
  | Payload_verify -> "verify"
  | Payload_delete -> "delete"
;;

let rec error_to_string = function
  | Reservation_conflict owner ->
    "keeper revival already owned: " ^ Keeper_lifecycle_reservation.snapshot_to_string owner
  | Nonce_allocation_failed error ->
    "keeper revival lifecycle nonce allocation failed: "
    ^ Keeper_lifecycle_nonce.error_to_string error
  | Journal_conflict detail ->
    "keeper revival journal is already unresolved: " ^ detail
  | Journal_ownership_changed detail ->
    "keeper revival journal ownership changed: " ^ detail
  | Journal_publication_indeterminate failure ->
    "keeper revival journal publication is indeterminate: "
    ^ head_failure_to_string failure
  | Journal_published_with_failure failure ->
    "keeper revival journal was published with a later failure: "
    ^ head_failure_to_string failure
  | Journal_published_with_warnings { warnings; _ } ->
    "keeper revival journal was published with settlement warnings: "
    ^ settlement_warning_detail (List.length warnings)
  | Journal_read_settlement_failed warnings ->
    "keeper revival journal read settled with warnings: "
    ^ settlement_warning_detail (List.length warnings)
  | Journal_write_failed detail -> "keeper revival journal write failed: " ^ detail
  | Payload_operation_failed { operation; failure } ->
    Printf.sprintf
      "keeper revival payload %s failed: %s"
      (payload_operation_to_string operation)
      (Payload.error_to_string failure)
  | Transaction_lock_failed failure ->
    "keeper revival transaction lock failed: "
    ^ File_lock_eio.durable_lock_error_to_string failure
  | Post_commit_cleanup_required { committed; cleanup_error; _ } ->
    Printf.sprintf
      "keeper %s launch committed at lifecycle nonce %d but transaction cleanup \
       requires attention: %s"
      committed.name
      committed.runtime.nonce
      (error_to_string cleanup_error)
  | Durable_snapshot_missing -> "keeper durable metadata disappeared before revival commit"
  | Durable_snapshot_changed -> "keeper durable metadata changed before revival commit"
  | Registry_conflict conflict -> registry_conflict_to_string conflict
  | Durable_commit_failed detail -> "keeper revival durable commit failed: " ^ detail
  | Durable_commit_unreadable detail ->
    "keeper revival committed metadata could not be read: " ^ detail
  | Launch_failed outcome ->
    "keeper revival launch failed: " ^ Keeper_keepalive.start_keepalive_outcome_to_string outcome
  | Rollback_failed { cause; errors } ->
    Printf.sprintf
      "%s; rollback failed: %s"
      cause
      (String.concat "; " (List.map rollback_error_to_string errors))
;;

let observe phase keeper detail =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LifecycleTransactions)
    ~labels:[ "keeper", keeper; "phase", phase ]
    ();
  Log.Keeper.info
    "keeper lifecycle transaction phase=%s keeper=%s detail=%s"
    phase
    keeper
    detail
;;

let release_observed token keeper =
  match Keeper_lifecycle_reservation.release token with
  | Keeper_lifecycle_reservation.Released -> observe "release" keeper "released"
  | Keeper_lifecycle_reservation.Release_missing ->
    Log.Keeper.warn "keeper lifecycle transaction release missing keeper=%s" keeper
  | Keeper_lifecycle_reservation.Release_not_owner owner ->
    Log.Keeper.error
      "keeper lifecycle transaction release ownership changed keeper=%s %s"
      keeper
      (Keeper_lifecycle_reservation.snapshot_to_string owner)
;;

let clear_candidate_registry token config journal candidate =
  match
    Keeper_registry.get
      ~base_path:config.Workspace.base_path
      journal.keeper_name
  with
  | None -> []
  | Some entry when same_identity entry.meta candidate ->
    Keeper_keepalive.request_entry_stop entry;
    (* Cancellation-safe rollback joins both terminal signals before exact
       unregister, so the replacement cannot inherit a live predecessor. *)
    let _lane_exit = Keeper_lane.await_exit entry.lane in
    let _done_resolution = Eio.Promise.await entry.done_p in
    (match Keeper_registry.unregister_exact_for_lifecycle token entry with
     | Keeper_registry.Exact_unregistered | Keeper_registry.Exact_entry_missing -> []
     | Keeper_registry.Exact_entry_replaced -> [ Rollback_registry_occupied entry ]
     | Keeper_registry.Exact_unregister_lifecycle_reserved owner ->
       [ Rollback_registry_reservation_changed owner ])
  | Some _ -> []
;;

let restore_registry
      token
      (original_entry : Keeper_registry.registry_entry option)
  =
  match original_entry with
  | None -> []
  | Some entry ->
    (match Keeper_registry.get ~base_path:entry.base_path entry.name with
     | Some occupied
       when Keeper_lane.Id.equal
              (Keeper_lane.id occupied.lane)
              (Keeper_lane.id entry.lane) -> []
     | Some occupied -> [ Rollback_registry_occupied occupied ]
     | None ->
       (match Keeper_registry.restore_entry_if_absent_for_lifecycle token entry with
        | Keeper_registry.Entry_restored -> []
        | Keeper_registry.Entry_restore_occupied occupied ->
          [ Rollback_registry_occupied occupied ]
        | Keeper_registry.Entry_restore_invalid error -> [ Rollback_registry_invalid error ]
        | Keeper_registry.Entry_restore_lifecycle_reserved owner ->
          [ Rollback_registry_reservation_changed owner ]))
;;

let transition_cleanup_pending
      config
      ~expected_stage
      ~cleanup_stage
      (journal : journal)
  =
  let cleanup = { journal with stage = cleanup_stage } in
  match transition_journal config ~expected_stage cleanup with
  | Ok () -> Ok cleanup
  | Error publication_error ->
    (match
       read_current_journal
         ~invalid:(fun detail -> Journal_ownership_changed detail)
         config
         journal.keeper_name
     with
     | Ok (_, _, Some (Active_journal current))
       when same_transaction current journal
            && current.stage = cleanup_stage ->
       Ok cleanup
     | Ok (_, _, Some (Active_journal current))
       when same_transaction current journal
            && current.stage = expected_stage ->
       Error publication_error
     | Error error -> Error error
     | Ok _ ->
       Error
         (Journal_ownership_changed
            "cleanup publication settled to an unexpected transaction stage"))
;;

let delete_payload config (journal : journal) =
  Payload.delete
    config
    ~keeper_name:journal.keeper_name
    ~expected_authority_leaf:
      (Payload.immutable_ref_authority_leaf journal.payload_ref)
    ~transaction_id:journal.transaction_id
    journal.payload_ref
;;

let rollback token config journal payload original_entry =
  let original = Payload.payload_original payload in
  let candidate = Payload.payload_candidate payload in
  let meta_errors =
    match Keeper_meta_store.read_meta config journal.keeper_name with
    | Error detail -> [ Rollback_meta_write_failed detail ]
    | Ok None -> [ Rollback_meta_missing ]
    | Ok (Some current)
      when same_persisted_payload current original -> []
    | Ok (Some current) when not (same_identity current candidate) ->
      [ Rollback_meta_identity_changed ]
    | Ok (Some current)
      when not (same_persisted_payload current candidate) ->
      [ Rollback_meta_payload_changed ]
    | Ok (Some current) ->
      let restored = { original with meta_version = current.meta_version } in
      (match Keeper_meta_store.write_meta_for_lifecycle token config restored with
       | Ok () -> []
       | Error detail -> [ Rollback_meta_write_failed detail ])
  in
  let registry_errors =
    clear_candidate_registry token config journal candidate
    @ restore_registry token original_entry
  in
  let errors = meta_errors @ registry_errors in
  if errors <> []
  then errors
  else
    match
      transition_cleanup_pending
        config
        ~expected_stage:journal.stage
        ~cleanup_stage:Rollback_cleanup_pending
        journal
    with
    | Error error ->
      [ Rollback_journal_clear_failed (error_to_string error) ]
    | Ok cleanup ->
      (match invoke_after_cleanup_pending_hook `Rollback with
       | Some detail -> [ Rollback_journal_clear_failed detail ]
       | None ->
         (match delete_payload config cleanup with
          | Error failure -> [ Rollback_payload_delete_failed failure ]
          | Ok () ->
            (match invoke_after_payload_delete_hook `Rollback with
             | Some detail -> [ Rollback_journal_clear_failed detail ]
             | None ->
               (match
                  clear_journal
                    config
                    ~expected_stage:Rollback_cleanup_pending
                    cleanup
                with
                | Ok () -> []
                | Error error ->
                  [ Rollback_journal_clear_failed
                      (error_to_string error)
                  ]))))
;;

let fail_with_rollback token config journal payload original_entry cause error =
  let errors = rollback token config journal payload original_entry in
  observe
    (if errors = [] then "rollback" else "rollback_failed")
    journal.keeper_name
    cause;
  release_observed token journal.keeper_name;
  match errors with
  | [] -> Error error
  | _ -> Error (Rollback_failed { cause; errors })
;;

let validate_registry_snapshot config original =
  match Keeper_registry.get ~base_path:config.Workspace.base_path original.name with
  | None -> Ok None
  | Some entry when entry.phase <> Keeper_state_machine.Dead ->
    Error (Registry_phase_conflict entry.phase)
  | Some entry when not (same_identity entry.meta original) ->
    Error
      (Registry_identity_conflict
         { expected_trace_id = original.runtime.trace_id
         ; expected_generation = original.runtime.nonce
         ; actual_trace_id = entry.meta.runtime.trace_id
         ; actual_generation = entry.meta.runtime.nonce
         })
  | Some entry
    when Option.is_none (Eio.Promise.peek entry.done_p)
         || not (Keeper_registry.lane_has_exited entry) ->
    Error Registry_dead_lane_not_settled
  | Some entry -> Ok (Some entry)
;;

let reserve_validated_journal config ~original journal =
  match Keeper_meta_store.read_meta config original.name with
  | Error _ -> Error Durable_snapshot_changed
  | Ok None -> Error Durable_snapshot_missing
  | Ok (Some latest)
    when latest.meta_version <> original.meta_version
         || not (same_persisted_payload latest original) ->
    Error Durable_snapshot_changed
  | Ok (Some _) ->
    (match validate_registry_snapshot config original with
     | Error conflict -> Error (Registry_conflict conflict)
     | Ok _ -> save_journal config journal)
;;

let payload_failure operation failure =
  Payload_operation_failed { operation; failure }
;;

let cleanup_unreserved_payload config (journal : journal) ~cause =
  let delete_proven_unpublished () =
    match delete_payload config journal with
    | Ok () -> cause
    | Error failure ->
      Log.Keeper.error
        "keeper revival unreserved payload cleanup failed keeper=%s cause=%s cleanup=%s"
        journal.keeper_name
        (error_to_string cause)
        (Payload.error_to_string failure);
      payload_failure Payload_delete failure
  in
  Eio.Cancel.protect (fun () ->
    match
      read_current_journal
        ~invalid:(fun detail -> Journal_ownership_changed detail)
        config
        journal.keeper_name
    with
    | Ok (_, _, None) -> delete_proven_unpublished ()
    | Ok
        ( _,
          _,
          Some
            (Cleared_tombstone
               { transaction_id; keeper_name }) )
      when String.equal transaction_id journal.transaction_id
           && String.equal keeper_name journal.keeper_name ->
      delete_proven_unpublished ()
    | Ok (_, _, Some (Active_journal current))
      when same_transaction current journal
           && current.stage = Reserved ->
      Log.Keeper.error
        "keeper revival retains payload for published Reserved recovery keeper=%s transaction=%s"
        journal.keeper_name
        journal.transaction_id;
      cause
    | Error observation_error ->
      Log.Keeper.error
        "keeper revival retains payload after inconclusive HEAD observation keeper=%s transaction=%s observation=%s"
        journal.keeper_name
        journal.transaction_id
        (error_to_string observation_error);
      observation_error
    | Ok _ ->
      Log.Keeper.error
        "keeper revival retains payload after conflicting HEAD observation keeper=%s transaction=%s"
        journal.keeper_name
        journal.transaction_id;
      Journal_ownership_changed
        "pre-Reserved payload cleanup was blocked by conflicting journal authority")
;;

let forward_cleanup config (journal : journal) =
  let cleanup_result =
    match journal.stage with
    | Launch_committed ->
      transition_cleanup_pending
        config
        ~expected_stage:Launch_committed
        ~cleanup_stage:Forward_cleanup_pending
        journal
      |> Result.map (fun cleanup -> cleanup, true)
    | Forward_cleanup_pending -> Ok (journal, false)
    | _ ->
      Error
        (Journal_ownership_changed
           "forward cleanup requires launch-committed authority")
  in
  match cleanup_result with
  | Error _ as error -> error
  | Ok (cleanup, cleanup_published) ->
    let pending_failure =
      if cleanup_published
      then invoke_after_cleanup_pending_hook `Forward
      else None
    in
    (match pending_failure with
     | Some detail -> Error (Journal_write_failed detail)
     | None ->
       (match delete_payload config cleanup with
        | Error failure -> Error (payload_failure Payload_delete failure)
        | Ok () ->
          (match invoke_after_payload_delete_hook `Forward with
           | Some detail -> Error (Journal_write_failed detail)
           | None ->
             clear_journal
               config
               ~expected_stage:Forward_cleanup_pending
               cleanup)))
;;

let revive_locked (ctx : _ context) ~original ~candidate =
  match
    Keeper_lifecycle_reservation.acquire
      ~base_path:ctx.config.base_path
      ~keeper_name:original.name
      ~expected_generation:original.runtime.nonce
      ~purpose:Keeper_lifecycle_reservation.Dead_revival
  with
  | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
    observe "conflict" original.name (Keeper_lifecycle_reservation.snapshot_to_string owner);
    Error (Reservation_conflict owner)
  | Ok token ->
    observe "acquire" original.name (Keeper_lifecycle_reservation.owner_id token);
    let journal_for_cleanup = ref None in
    let verified_payload_for_cleanup = ref None in
    let journal_published = ref false in
    let launch_committed = ref false in
    let cleanup_pre_journal_cancellation () =
      Eio.Cancel.protect (fun () ->
        (match !journal_for_cleanup with
         | None -> ()
         | Some journal ->
           (match !journal_published, !verified_payload_for_cleanup with
            | false, _ ->
              ignore
                (cleanup_unreserved_payload
                   ctx.config
                   journal
                   ~cause:
                     (Journal_write_failed
                        "cancelled before Reserved publication was confirmed"))
            | true, Some payload ->
              let errors = rollback token ctx.config journal payload None in
              if errors <> []
              then
              Log.Keeper.error
                "keeper lifecycle reserved cancellation rollback failed keeper=%s errors=%s"
                original.name
                (String.concat "; " (List.map rollback_error_to_string errors))
            | true, None ->
              Log.Keeper.error
                "keeper lifecycle reserved cancellation lost verified payload keeper=%s"
                original.name));
        release_observed token original.name)
    in
    let protect_pre_journal fn =
      try fn () with
      | Eio.Cancel.Cancelled _ as cancelled ->
        let backtrace = Printexc.get_raw_backtrace () in
        cleanup_pre_journal_cancellation ();
        Printexc.raise_with_backtrace cancelled backtrace
    in
    let nonce_result =
      protect_pre_journal (fun () ->
        let result =
          Result.bind
            (Keeper_lifecycle_nonce.next_for_base_path
               ~base_path:ctx.config.base_path
               ~floor:(Int64.succ (Int64.of_int original.runtime.nonce))
               ~keeper_id:original.name
               ~owner_id:(Keeper_id.Trace_id.to_string original.runtime.trace_id)
               ())
            Keeper_lifecycle_nonce.runtime_int_of_nonce
        in
        invoke_after_nonce_allocation_hook ();
        result)
    in
    match nonce_result with
    | Error error ->
      observe
        "nonce_allocation_failed"
        original.name
        (Keeper_lifecycle_nonce.error_to_string error);
      release_observed token original.name;
      Error (Nonce_allocation_failed error)
    | Ok nonce ->
    let candidate =
      { candidate with
        runtime = { candidate.runtime with nonce }
      }
    in
    let journal_result =
      protect_pre_journal (fun () ->
      match
        make_prepared_journal
          ~owner_id:(Keeper_lifecycle_reservation.owner_id token)
          ~original
          ~candidate
      with
      | Error failure -> Error (payload_failure Payload_prepare failure)
      | Ok (journal, prepared) ->
        journal_for_cleanup := Some journal;
        (match Payload.create ctx.config prepared with
         | Error failure ->
           Error
             (cleanup_unreserved_payload
                ctx.config
                journal
                ~cause:(payload_failure Payload_create failure))
         | Ok (Payload.Created _ | Payload.Reconciled_created _) ->
           (match verify_payload ctx.config journal with
            | Error failure ->
              Error
                (cleanup_unreserved_payload
                   ctx.config
                   journal
                   ~cause:(payload_failure Payload_verify failure))
            | Ok payload ->
              verified_payload_for_cleanup := Some payload;
              let result =
                let result =
                  reserve_validated_journal
                    ctx.config
                    ~original
                    journal
                in
                (match result with
                 | Ok () -> journal_published := true
                 | Error _ -> ());
                invoke_after_journal_write_hook ();
                result
              in
              (match result with
               | Ok () ->
                 journal_published := true;
                 Ok (journal, payload)
               | Error error ->
                 Eio.Cancel.protect (fun () ->
                 (match
                    read_current_journal
                      ~invalid:(fun detail ->
                        Journal_ownership_changed detail)
                      ctx.config
                      journal.keeper_name
                  with
                  | Ok
                      (_, _, Some (Active_journal current))
                    when same_transaction current journal
                         && current.stage = Reserved ->
                    Log.Keeper.error
                      "keeper revival retains payload after ambiguous Reserved publication keeper=%s transaction=%s"
                      journal.keeper_name
                      journal.transaction_id;
                    Error error
                  | Ok (_, _, None)
                  | Ok (_, _, Some (Cleared_tombstone _)) ->
                    Error
                      (cleanup_unreserved_payload
                         ctx.config
                         journal
                         ~cause:error)
                  | Error attention -> Error attention
                  | Ok (_, _, Some (Active_journal _)) ->
                    Error
                      (Journal_ownership_changed
                         "reservation publication settled to an unexpected active transaction"))))))
    in
    (match journal_result with
     | Error error ->
       release_observed token original.name;
       Error error
     | Ok (journal, verified_payload) ->
       (* The cancellation handler must restore the exact pre-transaction
          registry lane after removal. This ref carries only that immutable
          snapshot across the exception boundary; transaction ownership and
          all shared state remain in Atomic/CAS structures. *)
       let original_entry_for_rollback = ref None in
       let run () =
         match Keeper_meta_store.read_meta ctx.config original.name with
         | Error detail ->
           fail_with_rollback
             token
             ctx.config
             journal
             verified_payload
             None
             detail
             Durable_snapshot_changed
         | Ok None ->
           fail_with_rollback
             token
             ctx.config
             journal
             verified_payload
             None
             "durable metadata missing"
             Durable_snapshot_missing
         | Ok (Some latest)
           when latest.meta_version <> original.meta_version
                || not (same_persisted_payload latest original) ->
           fail_with_rollback
             token
             ctx.config
             journal
             verified_payload
             None
             "durable snapshot changed"
             Durable_snapshot_changed
         | Ok (Some _) ->
           (match validate_registry_snapshot ctx.config original with
            | Error conflict ->
              fail_with_rollback
                token
                ctx.config
                journal
                verified_payload
                None
                (registry_conflict_to_string conflict)
                (Registry_conflict conflict)
            | Ok original_entry ->
              original_entry_for_rollback := original_entry;
              let removal =
                match original_entry with
                | None -> Ok ()
                | Some entry ->
                  (match Keeper_registry.unregister_exact_for_lifecycle token entry with
                   | Keeper_registry.Exact_unregistered -> Ok ()
                   | Keeper_registry.Exact_entry_missing -> Error Registry_remove_missing
                   | Keeper_registry.Exact_entry_replaced -> Error Registry_remove_replaced
                   | Keeper_registry.Exact_unregister_lifecycle_reserved owner ->
                     Error
                       (Registry_identity_conflict
                          { expected_trace_id = original.runtime.trace_id
                          ; expected_generation = original.runtime.nonce
                          ; actual_trace_id = original.runtime.trace_id
                          ; actual_generation = owner.expected_generation
                          }))
              in
              (match removal with
               | Error conflict ->
                 fail_with_rollback
                   token
                   ctx.config
                   journal
                   verified_payload
                   original_entry
                   (registry_conflict_to_string conflict)
                   (Registry_conflict conflict)
               | Ok () ->
                 (match
                    Keeper_meta_store.write_meta_for_lifecycle token ctx.config candidate
                  with
                  | Error detail ->
                    fail_with_rollback
                      token
                      ctx.config
                      journal
                      verified_payload
                      original_entry
                      detail
                      (Durable_commit_failed detail)
                  | Ok () ->
                    (match Keeper_meta_store.read_meta ctx.config candidate.name with
                     | Error detail ->
                       fail_with_rollback
                         token
                         ctx.config
                         journal
                         verified_payload
                         original_entry
                         detail
                         (Durable_commit_unreadable detail)
                     | Ok None ->
                       fail_with_rollback
                         token
                         ctx.config
                         journal
                         verified_payload
                         original_entry
                         "committed metadata missing"
                         Durable_snapshot_missing
                     | Ok (Some committed) ->
                       let expected_candidate =
                         Payload.payload_candidate verified_payload
                       in
                       if not (same_persisted_payload committed expected_candidate)
                       then
                         fail_with_rollback
                           token
                           ctx.config
                           journal
                           verified_payload
                           original_entry
                           "committed metadata differs from verified revival payload"
                           Durable_snapshot_changed
                       else
                       let committed_journal =
                         { journal with stage = Durable_committed }
                       in
                       (match save_journal ctx.config committed_journal with
                        | Error publication_error ->
                          (match
                             observe_durable_publication
                               ctx.config
                               committed_journal
                           with
                           | Durable_publication_rollback_from observed_stage ->
                             fail_with_rollback
                               token
                               ctx.config
                               { journal with stage = observed_stage }
                               verified_payload
                               original_entry
                               (error_to_string publication_error)
                               publication_error
                           | Durable_publication_attention attention ->
                             Log.Keeper.error
                               "keeper revival durable publication requires \
                                attention keeper=%s publication=%s observation=%s"
                               committed.name
                               (error_to_string publication_error)
                               (error_to_string attention);
                             release_observed token committed.name;
                             Error attention)
                        | Ok () ->
                          (match
                             Keeper_keepalive.start_keepalive
                               ~lifecycle_token:token
                               ctx
                               committed
                           with
                           | Keeper_keepalive.Keepalive_started entry ->
                             let launch_journal =
                               { committed_journal with stage = Launch_committed }
                             in
                             let committed_with_attention cleanup_error =
                               launch_committed := true;
                               release_observed token committed.name;
                               Error
                                 (Post_commit_cleanup_required
                                    { committed
                                    ; entry
                                    ; cleanup_error
                                    })
                             in
                             (match save_launch_journal ctx.config launch_journal with
                              | Error publication_error ->
                                (match
                                   observe_launch_publication
                                     ctx.config
                                     committed_journal
                                 with
                                 | Launch_publication_not_committed ->
                                   fail_with_rollback
                                     token
                                     ctx.config
                                     committed_journal
                                     verified_payload
                                     original_entry
                                     (error_to_string publication_error)
                                     publication_error
                                 | Launch_publication_committed ->
                                   committed_with_attention publication_error
                                 | Launch_publication_attention attention ->
                                   Log.Keeper.error
                                     "keeper revival launch publication requires \
                                      attention keeper=%s publication=%s \
                                      observation=%s"
                                     committed.name
                                     (error_to_string publication_error)
                                     (error_to_string attention);
                                   committed_with_attention attention)
                              | Ok () ->
                                launch_committed := true;
                                let cleanup_result =
                                  Eio.Cancel.protect (fun () ->
                                    let result =
                                      match invoke_final_clear_failure_hook () with
                                      | Some detail ->
                                        Error (Journal_write_failed detail)
                                      | None ->
                                        forward_cleanup
                                          ctx.config
                                          launch_journal
                                    in
                                    release_observed token committed.name;
                                    result)
                                in
                                (match cleanup_result with
                                 | Error cleanup_error ->
                                   Error
                                     (Post_commit_cleanup_required
                                        { committed; entry; cleanup_error })
                                 | Ok () ->
                                   Eio.Fiber.check ();
                                   observe "commit" committed.name "lane started";
                                   Ok { meta = committed; entry }))
                           | rejected ->
                             fail_with_rollback
                               token
                               ctx.config
                               committed_journal
                               verified_payload
                               original_entry
                               (Keeper_keepalive.start_keepalive_outcome_to_string rejected)
                               (Launch_failed rejected)))))))
       in
       try run () with
       | Eio.Cancel.Cancelled _ as cancelled ->
         let backtrace = Printexc.get_raw_backtrace () in
         if not !launch_committed
         then
           Eio.Cancel.protect (fun () ->
             let errors =
               rollback
                 token
                 ctx.config
                 journal
                 verified_payload
                 !original_entry_for_rollback
             in
             if errors <> []
             then
               Log.Keeper.error
                 "keeper lifecycle cancellation rollback failed keeper=%s errors=%s"
                 original.name
                 (String.concat "; " (List.map rollback_error_to_string errors));
             release_observed token original.name);
         Printexc.raise_with_backtrace cancelled backtrace)
;;

let revive (ctx : _ context) ~original ~candidate =
  match Payload.authority_shard_for_keeper ~keeper_name:original.name with
  | Error failure -> Error (payload_failure Payload_prepare failure)
  | Ok shard ->
    (match
       revival_authority_lock_path
         ctx.config
         (Payload.authority_shard_leaf shard)
     with
     | Error error -> Error error
     | Ok lock_path ->
    (match
       File_lock_eio.with_durable_lock_observed
         ~lock_path
         (fun () -> revive_locked ctx ~original ~candidate)
     with
     | File_lock_eio.Lock_not_acquired failure ->
       Error (Transaction_lock_failed failure)
     | File_lock_eio.Body_completed { value; release_error = None } -> value
     | File_lock_eio.Body_completed
         { value = Ok { meta = committed; entry }
         ; release_error = Some failure
         } ->
       Error
         (Post_commit_cleanup_required
            { committed
            ; entry
            ; cleanup_error = Transaction_lock_failed failure
            })
     | File_lock_eio.Body_completed
         { value = Error error
         ; release_error = Some failure
         } ->
       Log.Keeper.error
         "keeper revival transaction lock release failed after body error \
          keeper=%s error=%s"
         original.name
         (File_lock_eio.durable_lock_error_to_string failure);
       Error error))
;;

let recovery_payload_error failure =
  "recovery payload verification failed: " ^ Payload.error_to_string failure
;;

let finish_rollback_cleanup config journal =
  match delete_payload config journal with
  | Error failure ->
    Error
      (rollback_error_to_string
       (Rollback_payload_delete_failed failure))
  | Ok () ->
    (match invoke_after_payload_delete_hook `Rollback with
     | Some detail -> Error detail
     | None ->
       (match
          clear_journal
            config
            ~expected_stage:Rollback_cleanup_pending
            journal
        with
        | Ok () -> Ok true
        | Error error -> Error (error_to_string error)))
;;

let recover_one_locked config leaf =
  match
    read_journal_leaf
      ~invalid:(fun detail -> Journal_ownership_changed detail)
      config
      ~leaf
      ~expected_keeper_name:None
  with
  | Error error -> Error (error_to_string error)
  | Ok (_, _, None) -> Error "journal authority disappeared during recovery"
  | Ok (_, _, Some (Cleared_tombstone _)) -> Ok false
  | Ok (_, _, Some (Active_journal journal)) ->
    let recover_forward journal =
      match forward_cleanup config journal with
      | Ok () ->
        observe "recovery_forward_commit" journal.keeper_name "payload and journal cleared";
        Ok false
      | Error error ->
        Error
          ("forward-commit journal cleanup failed: "
           ^ error_to_string error)
    in
    (match journal.stage with
     | Launch_committed -> recover_forward journal
     | Forward_cleanup_pending -> recover_forward journal
     | Rollback_cleanup_pending ->
       finish_rollback_cleanup config journal
     | Reserved
     | Durable_committed
     | Rollback_reserved
     | Rollback_durable_committed ->
       (match verify_payload config journal with
        | Error failure -> Error (recovery_payload_error failure)
        | Ok verified_payload ->
          (match journal.stage with
           | Reserved
           | Durable_committed
           | Rollback_reserved
           | Rollback_durable_committed ->
             (match
                Keeper_lifecycle_reservation.acquire
                  ~base_path:config.Workspace.base_path
                  ~keeper_name:journal.keeper_name
                  ~expected_generation:journal.expected_generation
                  ~purpose:Keeper_lifecycle_reservation.Dead_revival
              with
              | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
                observe
                  "recovery_conflict"
                  journal.keeper_name
                  (Keeper_lifecycle_reservation.snapshot_to_string owner);
                Error
                  ("recovery reservation conflict: "
                   ^ Keeper_lifecycle_reservation.snapshot_to_string owner)
              | Ok token ->
                invoke_before_recovery_claim_hook ();
                let result =
                  match claim_recovery_rollback config journal 8 with
                  | Error error -> Error (error_to_string error)
                  | Ok Recovery_already_cleared -> Ok false
                  | Ok (Recovery_forward_complete stage) ->
                    recover_forward { journal with stage }
                  | Ok
                      (Recovery_rollback_claimed
                         (Rollback_cleanup_pending, _)) ->
                    finish_rollback_cleanup
                      config
                      { journal with stage = Rollback_cleanup_pending }
                  | Ok
                      (Recovery_rollback_claimed
                         (stage, durable_committed)) ->
                    let claimed = { journal with stage } in
                    let errors =
                      rollback
                        token
                        config
                        claimed
                        verified_payload
                        None
                    in
                    observe
                      (if errors = [] then "recovery" else "recovery_failed")
                      claimed.keeper_name
                      (String.concat
                         "; "
                         (List.map rollback_error_to_string errors));
                    if errors = []
                    then Ok durable_committed
                    else
                      Error
                        (String.concat
                           "; "
                           (List.map rollback_error_to_string errors))
                in
                release_observed token journal.keeper_name;
                result)
           | Launch_committed
           | Forward_cleanup_pending
           | Rollback_cleanup_pending
           | Cleared -> assert false))
     | Cleared ->
       Error "active journal unexpectedly carries Cleared stage")
;;

let recover_one config leaf =
  match
    read_journal_leaf
      ~invalid:(fun detail -> Journal_ownership_changed detail)
      config
      ~leaf
      ~expected_keeper_name:None
  with
  | Error error -> Error (error_to_string error)
  | Ok (_, _, None) ->
    Error "journal authority disappeared during recovery discovery"
  | Ok (_, _, Some (Cleared_tombstone _)) -> Ok false
  | Ok (_, _, Some (Active_journal discovered)) ->
    (match
       revival_authority_lock_path
         config
         (Payload.immutable_ref_authority_leaf discovered.payload_ref)
     with
     | Error error -> Error (error_to_string error)
     | Ok lock_path ->
       (match
          File_lock_eio.with_durable_lock_observed
            ~lock_path
            (fun () -> recover_one_locked config leaf)
        with
        | File_lock_eio.Lock_not_acquired failure ->
          Error
            ("recovery transaction lock failed: "
             ^ File_lock_eio.durable_lock_error_to_string failure)
        | File_lock_eio.Body_completed
            { value; release_error = None } -> value
        | File_lock_eio.Body_completed
            { value; release_error = Some failure } ->
          let release_detail =
            "recovery transaction lock release failed: "
            ^ File_lock_eio.durable_lock_error_to_string failure
          in
          (match value with
           | Ok _ -> Error ("recovery completed; " ^ release_detail)
           | Error detail -> Error (detail ^ "; " ^ release_detail))))
;;

let protect_shard_from_orphan_cleanup_locked config shard =
  let dir = journal_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error _ when not (Fs_compat.file_exists dir) -> Ok false
  | Error detail -> Error detail
  | Ok files ->
    List.fold_left
      (fun result leaf ->
         let ( let* ) = Result.bind in
         let* protect_shard = result in
         if not (Filename.check_suffix leaf ".json")
         then Ok protect_shard
         else
           match
             read_journal_leaf
               ~invalid:(fun detail -> Journal_ownership_changed detail)
               config
               ~leaf
               ~expected_keeper_name:None
           with
           | Error error -> Error (error_to_string error)
           | Ok (_, _, None)
           | Ok (_, _, Some (Cleared_tombstone _)) -> Ok protect_shard
           | Ok (_, _, Some (Active_journal journal)) ->
             if
               String.equal
                 (Payload.immutable_ref_authority_leaf journal.payload_ref)
                 (Payload.authority_shard_leaf shard)
             then
               let transaction_leaf =
                 Payload.immutable_ref_transaction_leaf journal.payload_ref
               in
               let* expected_transaction_leaf =
                 Payload.transaction_leaf_for_id
                   ~transaction_id:journal.transaction_id
                 |> Result.map_error Payload.error_to_string
               in
               if String.equal transaction_leaf expected_transaction_leaf
               then
                 Ok true
               else
                 Error
                   "active journal payload slot differs from transaction binding"
             else Ok protect_shard)
      (Ok false)
      files
;;

let clean_orphan_shard config shard =
  match
    revival_authority_lock_path
      config
      (Payload.authority_shard_leaf shard)
  with
  | Error error -> Error (error_to_string error)
  | Ok lock_path ->
    (match
       File_lock_eio.with_durable_lock_observed
         ~lock_path
         (fun () ->
            let ( let* ) = Result.bind in
            let* inventory =
              Payload.inventory_transactions config shard
              |> Result.map_error Payload.error_to_string
            in
            let* protect_shard =
              protect_shard_from_orphan_cleanup_locked config shard
            in
            if protect_shard
            then Ok 0
            else
              List.fold_left
                (fun result entry ->
                   let* cleared = result in
                   Payload.delete_inventory_transaction
                     config
                     ~authority_shard:shard
                     entry
                   |> Result.map (fun () -> cleared + 1)
                   |> Result.map_error Payload.error_to_string)
                (Ok 0)
                inventory)
     with
     | File_lock_eio.Lock_not_acquired failure ->
       Error (File_lock_eio.durable_lock_error_to_string failure)
     | File_lock_eio.Body_completed
         { value; release_error = None } -> value
     | File_lock_eio.Body_completed
         { value = _; release_error = Some failure } ->
       Error (File_lock_eio.durable_lock_error_to_string failure))
;;

let recover_pending config =
  let dir = journal_dir config in
  let summary =
    match Safe_ops.list_dir_safe dir with
    | Error _ when not (Fs_compat.file_exists dir) ->
      { recovered = 0; cleared = 0; unresolved = [] }
    | Error detail ->
      { recovered = 0; cleared = 0; unresolved = [ dir, detail ] }
    | Ok files ->
      List.fold_left
        (fun summary file ->
           if not (Filename.check_suffix file ".json")
           then summary
           else
             let path = Filename.concat dir file in
             match recover_one config file with
             | Ok true ->
               { summary with recovered = summary.recovered + 1 }
             | Ok false ->
               { summary with cleared = summary.cleared + 1 }
             | Error detail ->
               { summary with
                 unresolved = (path, detail) :: summary.unresolved
               })
        { recovered = 0; cleared = 0; unresolved = [] }
        files
  in
  match Payload.inventory_authority_shards config with
  | Error failure ->
    { summary with
      unresolved =
        ("revival-payload-inventory", Payload.error_to_string failure)
        :: summary.unresolved
    }
  | Ok shards ->
    List.fold_left
      (fun summary shard ->
         match clean_orphan_shard config shard with
         | Ok cleared ->
           { summary with cleared = summary.cleared + cleared }
         | Error detail ->
           { summary with
             unresolved =
               (Payload.authority_shard_leaf shard, detail)
               :: summary.unresolved
           })
      summary
      shards
;;
