open Keeper_meta_contract
open Keeper_types_profile

module Head = Fs_compat.Capability_head

let after_nonce_allocation_hook : (unit -> unit) Atomic.t =
  Atomic.make (fun () -> ())
;;

let after_journal_write_hook : (unit -> unit) Atomic.t =
  Atomic.make (fun () -> ())
;;

let invoke_after_nonce_allocation_hook () =
  (Atomic.get after_nonce_allocation_hook) ()
;;

let invoke_after_journal_write_hook () =
  (Atomic.get after_journal_write_hook) ()
;;

module Boundary_hooks_for_testing = struct
  let with_boundary_hooks
        ?(after_nonce_allocation = fun () -> ())
        ?(after_journal_write = fun () -> ())
        fn
    =
    let previous_nonce =
      Atomic.exchange after_nonce_allocation_hook after_nonce_allocation
    in
    let previous_journal =
      Atomic.exchange after_journal_write_hook after_journal_write
    in
    Fun.protect
      ~finally:(fun () ->
        Atomic.set after_nonce_allocation_hook previous_nonce;
        Atomic.set after_journal_write_hook previous_journal)
      fn
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
  | Rollback_journal_clear_failed of string

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
  ; journal_cleanup_pending : string option
  }

type journal_stage =
  | Reserved
  | Durable_committed
  | Launch_committed
  | Cleared

type journal =
  { transaction_id : string
  ; owner_id : string
  ; keeper_name : string
  ; expected_trace_id : Keeper_id.Trace_id.t
  ; expected_generation : int
  ; original : keeper_meta
  ; candidate : keeper_meta
  ; stage : journal_stage
  }

type recovery_summary =
  { recovered : int
  ; cleared : int
  ; unresolved : (string * string) list
  }

let journal_dir config =
  Filename.concat (Workspace.masc_root_dir config) "keeper-lifecycle-transactions"
;;

let journal_schema = "masc.keeper-dead-revival-journal.v1"
let head_entropy_bytes = 32 * 33

let sha256 value =
  Digestif.SHA256.(to_hex (digest_string value))
;;

let length_delimited value =
  Printf.sprintf "%d:%s" (String.length value) value
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
  | Cleared -> `Assoc [ "cleared", `Bool true ]
;;

let journal_to_json journal =
  let stage =
    journal_stage_to_json journal.stage
  in
  `Assoc
    [ "schema", `String journal_schema
    ; "transaction_id", `String journal.transaction_id
    ; "owner_id", `String journal.owner_id
    ; "keeper_name", `String journal.keeper_name
    ; "expected_trace_id", `String (Keeper_id.Trace_id.to_string journal.expected_trace_id)
    ; "expected_generation", `Int journal.expected_generation
    ; "original", Keeper_meta_json.meta_to_json journal.original
    ; "candidate", Keeper_meta_json.meta_to_json journal.candidate
    ; "stage", stage
    ]
;;

let journal_to_bytes journal =
  Yojson.Safe.to_string (journal_to_json journal)
;;

let exact_journal_fields fields =
  let expected =
    [ "schema"
    ; "transaction_id"
    ; "owner_id"
    ; "keeper_name"
    ; "expected_trace_id"
    ; "expected_generation"
    ; "original"
    ; "candidate"
    ; "stage"
    ]
    |> List.sort String.compare
  in
  let observed =
    List.map fst fields
    |> List.sort String.compare
  in
  if List.equal String.equal expected observed
  then Ok ()
  else
    Error
      (Printf.sprintf
         "journal fields differ expected=[%s] observed=[%s]"
         (String.concat "," expected)
         (String.concat "," observed))
;;

let required_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value) when not (String.equal (String.trim value) "") -> Ok value
  | Some _ -> Error (Printf.sprintf "journal field %s must be a non-empty string" key)
  | None -> Error (Printf.sprintf "journal field %s is missing" key)
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
  | Some (`Assoc [ ("cleared", `Bool true) ]) -> Ok Cleared
  | Some _ -> Error "journal stage must contain exactly one known constructor"
  | None -> Error "journal field stage is missing"
;;

let required_meta key fields =
  match List.assoc_opt key fields with
  | None -> Error (Printf.sprintf "journal field %s is missing" key)
  | Some json -> Keeper_meta_json.meta_of_json json
;;

let journal_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () = exact_journal_fields fields in
    let* schema = required_string "schema" fields in
    let* transaction_id = required_string "transaction_id" fields in
    let* owner_id = required_string "owner_id" fields in
    let* keeper_name = required_string "keeper_name" fields in
    let* trace_id_raw = required_string "expected_trace_id" fields in
    let* expected_trace_id = Keeper_id.Trace_id.of_string trace_id_raw in
    let* expected_generation = required_int "expected_generation" fields in
    let* original = required_meta "original" fields in
    let* candidate = required_meta "candidate" fields in
    let* stage = required_stage fields in
    if not (String.equal schema journal_schema)
    then Error ("unsupported keeper lifecycle journal schema: " ^ schema)
    else if
      not (String.equal original.name keeper_name)
      || not (String.equal candidate.name keeper_name)
      || not
           (Keeper_id.Trace_id.equal
              original.runtime.trace_id
              expected_trace_id)
      || not (Int.equal original.runtime.nonce expected_generation)
    then Error "journal metadata does not match its keeper lifecycle binding"
    else
      let expected_transaction_id =
        journal_transaction_id
          ~owner_id
          ~keeper_name
          ~expected_trace_id
          ~expected_generation
          ~candidate_nonce:candidate.runtime.nonce
      in
      if not (String.equal transaction_id expected_transaction_id)
      then Error "journal transaction_id does not bind owner and lifecycle nonce"
      else
        Ok
          { transaction_id
          ; owner_id
          ; keeper_name
          ; expected_trace_id
          ; expected_generation
          ; original
          ; candidate
          ; stage
          }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "keeper lifecycle journal must be a JSON object"
;;

let journal_of_bytes raw =
  try
    Result.bind
      (journal_of_json (Yojson.Safe.from_string raw))
      (fun journal ->
         if String.equal raw (journal_to_bytes journal)
         then Ok journal
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

let read_current_journal ~invalid config keeper_name =
  match journal_parent config with
  | Error error -> Error error
  | Ok parent ->
    (match journal_entropy () with
     | Error error -> Error error
     | Ok secure_random ->
       (match
          Head.read
            ~secure_random
            ~parent
            ~leaf:(keeper_name ^ ".json")
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
                | Ok journal when not (String.equal journal.keeper_name keeper_name) ->
                  Error (invalid "journal keeper binding differs from its leaf")
                | Ok journal -> Ok (parent, snapshot, Some journal)))))
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

let publish_row ~conflict ~parent ~snapshot ~journal =
  match journal_entropy () with
  | Error error -> Error error
  | Ok secure_random ->
    (match
       Head.compare_and_swap
         ~secure_random
         ~parent
         ~leaf:(journal.keeper_name ^ ".json")
         ~expected:(Head.snapshot_cursor snapshot)
         ~row:(journal_to_bytes journal)
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

let same_transaction left right =
  String.equal left.transaction_id right.transaction_id
  && String.equal left.owner_id right.owner_id
  && String.equal left.keeper_name right.keeper_name
  && Keeper_id.Trace_id.equal
       left.expected_trace_id
       right.expected_trace_id
  && Int.equal left.expected_generation right.expected_generation
  && Int.equal left.candidate.runtime.nonce right.candidate.runtime.nonce
;;

let reserve_journal config journal =
  match
    read_current_journal
      ~invalid:(fun detail -> Journal_conflict detail)
      config
      journal.keeper_name
  with
  | Error error -> Error error
  | Ok (_, _, Some existing)
    when existing.stage <> Cleared ->
    Error
      (Journal_conflict
         (Printf.sprintf
            "unresolved journal transaction=%s remains stage=%s"
            existing.transaction_id
            (Yojson.Safe.to_string (journal_stage_to_json existing.stage))))
  | Ok (parent, snapshot, None)
  | Ok (parent, snapshot, Some { stage = Cleared; _ }) ->
    publish_row
      ~conflict:(fun detail -> Journal_conflict detail)
      ~parent
      ~snapshot
      ~journal
;;

let transition_journal config ~expected_stage journal =
  match
    read_current_journal
      ~invalid:(fun detail -> Journal_ownership_changed detail)
      config
      journal.keeper_name
  with
  | Error error -> Error error
  | Ok (_, _, None) ->
    Error (Journal_ownership_changed "journal authority is missing")
  | Ok (_, _, Some current)
    when current.stage <> expected_stage
         || not (same_transaction current journal) ->
    Error
      (Journal_ownership_changed
         "journal authority is not the expected transaction stage")
  | Ok (parent, snapshot, Some _) ->
    publish_row
      ~conflict:(fun detail -> Journal_ownership_changed detail)
      ~parent
      ~snapshot
      ~journal
;;

let save_journal config journal =
  match journal.stage with
  | Reserved -> reserve_journal config journal
  | Durable_committed ->
    transition_journal config ~expected_stage:Reserved journal
  | Launch_committed ->
    transition_journal config ~expected_stage:Durable_committed journal
  | Cleared ->
    Error (Journal_write_failed "Cleared is not a publishable revival stage")
;;

let clear_journal config journal =
  match
    read_current_journal
      ~invalid:(fun detail -> Journal_ownership_changed detail)
      config
      journal.keeper_name
  with
  | Error error -> Error error
  | Ok (_, _, None) ->
    Error (Journal_ownership_changed "journal authority disappeared before clear")
  | Ok (_, _, Some current)
    when not (same_transaction current journal) ->
    Error
      (Journal_ownership_changed
         "journal authority belongs to a different transaction")
  | Ok (_, _, Some { stage = Cleared; _ }) -> Ok ()
  | Ok (parent, snapshot, Some current) ->
    publish_row
      ~conflict:(fun detail -> Journal_ownership_changed detail)
      ~parent
      ~snapshot
      ~journal:{ current with stage = Cleared }
;;

let make_reserved_journal ~owner_id ~original ~candidate =
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
  ; original
  ; candidate
  ; stage = Reserved
  }
;;

module For_testing = struct
  include Boundary_hooks_for_testing

  let reserved_journal_row ~owner_id ~original ~candidate =
    make_reserved_journal ~owner_id ~original ~candidate
    |> journal_to_bytes
  ;;

  let reserve_journal ~config ~owner_id ~original ~candidate =
    let journal = make_reserved_journal ~owner_id ~original ~candidate in
    match save_journal config journal with
    | Ok () -> Ok (journal_to_bytes journal)
    | Error error -> Error error
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
    | Ok (_, _, Some journal) -> Ok (Some (journal_to_bytes journal))
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
    | Ok (_, _, Some { stage = Reserved; _ }) -> Ok `Reserved
    | Ok (_, _, Some { stage = Durable_committed; _ }) ->
      Ok `Durable_committed
    | Ok (_, _, Some { stage = Launch_committed; _ }) ->
      Ok `Launch_committed
    | Ok (_, _, Some { stage = Cleared; _ }) -> Ok `Cleared
  ;;

  let replace_with_reserved_journal
        ~config
        ~owner_id
        ~original
        ~candidate
    =
    let replacement =
      make_reserved_journal ~owner_id ~original ~candidate
    in
    match
      read_current_journal
        ~invalid:(fun detail -> Journal_ownership_changed detail)
        config
        original.name
    with
    | Error error -> Error error
    | Ok (_, _, None) ->
      Error (Journal_ownership_changed "test replacement source is missing")
    | Ok (parent, snapshot, Some _) ->
      publish_row
        ~conflict:(fun detail -> Journal_ownership_changed detail)
        ~parent
        ~snapshot
        ~journal:replacement
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
  | Rollback_journal_clear_failed detail -> "journal clear failed: " ^ detail
;;

let error_to_string = function
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

let clear_candidate_registry token config journal =
  match
    Keeper_registry.get
      ~base_path:config.Workspace.base_path
      journal.keeper_name
  with
  | None -> []
  | Some entry when same_identity entry.meta journal.candidate ->
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

let rollback token config journal original_entry =
  let meta_errors =
    match Keeper_meta_store.read_meta config journal.keeper_name with
    | Error detail -> [ Rollback_meta_write_failed detail ]
    | Ok None -> [ Rollback_meta_missing ]
    | Ok (Some current)
      when same_persisted_payload current journal.original -> []
    | Ok (Some current) when not (same_identity current journal.candidate) ->
      [ Rollback_meta_identity_changed ]
    | Ok (Some current)
      when not (same_persisted_payload current journal.candidate) ->
      [ Rollback_meta_payload_changed ]
    | Ok (Some current) ->
      let restored = { journal.original with meta_version = current.meta_version } in
      (match Keeper_meta_store.write_meta_for_lifecycle token config restored with
       | Ok () -> []
       | Error detail -> [ Rollback_meta_write_failed detail ])
  in
  let registry_errors =
    clear_candidate_registry token config journal @ restore_registry token original_entry
  in
  let errors = meta_errors @ registry_errors in
  if errors <> []
  then errors
  else
    match clear_journal config journal with
    | Ok () -> []
    | Error error ->
      [ Rollback_journal_clear_failed (error_to_string error) ]
;;

let fail_with_rollback token config journal original_entry cause error =
  let errors = rollback token config journal original_entry in
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

let revive (ctx : _ context) ~original ~candidate =
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
    let cleanup_pre_journal_cancellation () =
      Eio.Cancel.protect (fun () ->
        (match !journal_for_cleanup with
         | None -> ()
         | Some journal ->
           (match clear_journal ctx.config journal with
            | Ok () -> ()
            | Error error ->
              Log.Keeper.error
                "keeper lifecycle pre-journal cancellation clear failed keeper=%s error=%s"
                original.name
                (error_to_string error)));
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
    let journal =
      make_reserved_journal
        ~owner_id:(Keeper_lifecycle_reservation.owner_id token)
        ~original
        ~candidate
    in
    let journal_result =
      protect_pre_journal (fun () ->
        journal_for_cleanup := Some journal;
        let result = save_journal ctx.config journal in
        invoke_after_journal_write_hook ();
        result)
    in
    (match journal_result with
     | Error error ->
       release_observed token original.name;
       Error error
     | Ok () ->
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
             None
             detail
             Durable_snapshot_changed
         | Ok None ->
           fail_with_rollback
             token
             ctx.config
             journal
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
                         original_entry
                         detail
                         (Durable_commit_unreadable detail)
                     | Ok None ->
                       fail_with_rollback
                         token
                         ctx.config
                         journal
                         original_entry
                         "committed metadata missing"
                         Durable_snapshot_missing
                     | Ok (Some committed) ->
                       let committed_journal =
                         { journal with candidate = committed; stage = Durable_committed }
                       in
                       (match save_journal ctx.config committed_journal with
                        | Error error ->
                          fail_with_rollback
                            token
                            ctx.config
                            journal
                            original_entry
                            (error_to_string error)
                            error
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
                             (match save_journal ctx.config launch_journal with
                              | Error error ->
                                fail_with_rollback
                                  token
                                  ctx.config
                                  committed_journal
                                  original_entry
                                  (error_to_string error)
                                  error
                              | Ok () ->
                                let journal_cleanup_pending =
                                  match clear_journal ctx.config launch_journal with
                                  | Ok () -> None
                                  | Error error -> Some (error_to_string error)
                                in
                                observe
                                  (match journal_cleanup_pending with
                                   | None -> "commit"
                                   | Some _ -> "commit_journal_cleanup_pending")
                                  committed.name
                                  "lane started";
                                release_observed token committed.name;
                                Ok { meta = committed; entry; journal_cleanup_pending })
                           | rejected ->
                             fail_with_rollback
                               token
                               ctx.config
                               committed_journal
                               original_entry
                               (Keeper_keepalive.start_keepalive_outcome_to_string rejected)
                               (Launch_failed rejected)))))))
       in
       try run () with
       | Eio.Cancel.Cancelled _ as cancelled ->
         let backtrace = Printexc.get_raw_backtrace () in
         Eio.Cancel.protect (fun () ->
           let errors =
             rollback token ctx.config journal !original_entry_for_rollback
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

let recover_one config keeper_name =
  match
    read_current_journal
      ~invalid:(fun detail -> Journal_ownership_changed detail)
      config
      keeper_name
  with
  | Error error -> Error (error_to_string error)
  | Ok (_, _, None) -> Error "journal authority disappeared during recovery"
  | Ok (_, _, Some journal) ->
      let rollback_recovery ~durable_committed =
        match
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
          let errors = rollback token config journal None in
          observe
            (match errors with
             | [] -> "recovery"
             | _ -> "recovery_failed")
            journal.keeper_name
            (String.concat "; " (List.map rollback_error_to_string errors));
          release_observed token journal.keeper_name;
          (match errors with
           | [] -> Ok durable_committed
           | _ -> Error (String.concat "; " (List.map rollback_error_to_string errors)))
      in
      match journal.stage with
      | Launch_committed ->
        (match clear_journal config journal with
         | Ok () ->
           observe "recovery_forward_commit" journal.keeper_name "journal cleared";
           Ok false
         | Error error ->
           Error
             ("forward-commit journal cleanup failed: "
              ^ error_to_string error))
      | Reserved -> rollback_recovery ~durable_committed:false
      | Durable_committed -> rollback_recovery ~durable_committed:true
      | Cleared -> Ok false
;;

let recover_pending config =
  let dir = journal_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error _ when not (Fs_compat.file_exists dir) -> { recovered = 0; cleared = 0; unresolved = [] }
  | Error detail -> { recovered = 0; cleared = 0; unresolved = [ dir, detail ] }
  | Ok files ->
    files
    |> List.filter (fun file -> Filename.check_suffix file ".json")
    |> List.fold_left
         (fun summary file ->
            let path = Filename.concat dir file in
            let keeper_name = Filename.chop_suffix file ".json" in
            match recover_one config keeper_name with
            | Ok true -> { summary with recovered = summary.recovered + 1 }
            | Ok false -> { summary with cleared = summary.cleared + 1 }
            | Error detail ->
              { summary with unresolved = (path, detail) :: summary.unresolved })
         { recovered = 0; cleared = 0; unresolved = [] }
;;
