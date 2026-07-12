open Keeper_meta_contract
open Keeper_types_profile

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
  | Rollback_journal_delete_failed of string

type error =
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
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

type journal =
  { owner_id : string
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

let journal_path config keeper_name =
  Filename.concat (journal_dir config) (keeper_name ^ ".json")
;;

let journal_to_json journal =
  let stage =
    match journal.stage with
    | Reserved -> `Assoc [ "reserved", `Bool true ]
    | Durable_committed -> `Assoc [ "durable_committed", `Bool true ]
    | Launch_committed -> `Assoc [ "launch_committed", `Bool true ]
  in
  `Assoc
    [ "owner_id", `String journal.owner_id
    ; "keeper_name", `String journal.keeper_name
    ; "expected_trace_id", `String (Keeper_id.Trace_id.to_string journal.expected_trace_id)
    ; "expected_generation", `Int journal.expected_generation
    ; "original", Keeper_meta_json.meta_to_json journal.original
    ; "candidate", Keeper_meta_json.meta_to_json journal.candidate
    ; "stage", stage
    ]
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
    let* owner_id = required_string "owner_id" fields in
    let* keeper_name = required_string "keeper_name" fields in
    let* trace_id_raw = required_string "expected_trace_id" fields in
    let* expected_trace_id = Keeper_id.Trace_id.of_string trace_id_raw in
    let* expected_generation = required_int "expected_generation" fields in
    let* original = required_meta "original" fields in
    let* candidate = required_meta "candidate" fields in
    let* stage = required_stage fields in
    Ok
      { owner_id
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

let save_journal config journal =
  let dir = journal_dir config in
  ignore (Keeper_fs.ensure_dir dir : string);
  Keeper_fs.save_json_atomic (journal_path config journal.keeper_name) (journal_to_json journal)
;;

let delete_journal config keeper_name =
  let path = journal_path config keeper_name in
  if not (Fs_compat.file_exists path)
  then Ok ()
  else
    try
      Sys.remove path;
      Ok ()
    with
    | Sys_error detail -> Error detail
;;

let same_identity (a : keeper_meta) (b : keeper_meta) =
  Keeper_id.Trace_id.equal a.runtime.trace_id b.runtime.trace_id
  && Int.equal a.runtime.generation b.runtime.generation
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
  | Rollback_journal_delete_failed detail -> "journal delete failed: " ^ detail
;;

let error_to_string = function
  | Reservation_conflict owner ->
    "keeper revival already owned: " ^ Keeper_lifecycle_reservation.snapshot_to_string owner
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
    ignore (Keeper_lane.await_exit entry.lane : Keeper_lane.exit);
    ignore (Eio.Promise.await entry.done_p : Keeper_registry.done_resolution);
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
    match delete_journal config journal.keeper_name with
    | Ok () -> []
    | Error detail -> [ Rollback_journal_delete_failed detail ]
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
         ; expected_generation = original.runtime.generation
         ; actual_trace_id = entry.meta.runtime.trace_id
         ; actual_generation = entry.meta.runtime.generation
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
      ~expected_generation:original.runtime.generation
      ~purpose:Keeper_lifecycle_reservation.Dead_revival
  with
  | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
    observe "conflict" original.name (Keeper_lifecycle_reservation.snapshot_to_string owner);
    Error (Reservation_conflict owner)
  | Ok token ->
    observe "acquire" original.name (Keeper_lifecycle_reservation.owner_id token);
    let generation =
      Keeper_memory_os_io.next_generation_with_floor
        ~floor:(original.runtime.generation + 1)
        ~keeper_id:original.name
        ~trace_id:(Keeper_id.Trace_id.to_string original.runtime.trace_id)
    in
    let candidate =
      { candidate with
        runtime = { candidate.runtime with generation }
      }
    in
    let journal =
      { owner_id = Keeper_lifecycle_reservation.owner_id token
      ; keeper_name = original.name
      ; expected_trace_id = original.runtime.trace_id
      ; expected_generation = original.runtime.generation
      ; original
      ; candidate
      ; stage = Reserved
      }
    in
    (match save_journal ctx.config journal with
     | Error detail ->
       release_observed token original.name;
       Error (Journal_write_failed detail)
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
                          ; expected_generation = original.runtime.generation
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
                        | Error detail ->
                          fail_with_rollback
                            token
                            ctx.config
                            journal
                            original_entry
                            detail
                            (Journal_write_failed detail)
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
                              | Error detail ->
                                fail_with_rollback
                                  token
                                  ctx.config
                                  committed_journal
                                  original_entry
                                  detail
                                  (Journal_write_failed detail)
                              | Ok () ->
                                let journal_cleanup_pending =
                                  match delete_journal ctx.config committed.name with
                                  | Ok () -> None
                                  | Error detail -> Some detail
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
         raise cancelled)
;;

let recover_one config path =
  match Safe_ops.read_json_file_safe path with
  | Error detail -> Error detail
  | Ok json ->
    Result.bind (journal_of_json json) (fun journal ->
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
        (match delete_journal config journal.keeper_name with
         | Ok () ->
           observe "recovery_forward_commit" journal.keeper_name "journal cleared";
           Ok false
         | Error detail -> Error ("forward-commit journal cleanup failed: " ^ detail))
      | Reserved -> rollback_recovery ~durable_committed:false
      | Durable_committed -> rollback_recovery ~durable_committed:true)
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
            match recover_one config path with
            | Ok true -> { summary with recovered = summary.recovered + 1 }
            | Ok false -> { summary with cleared = summary.cleared + 1 }
            | Error detail ->
              { summary with unresolved = (path, detail) :: summary.unresolved })
         { recovered = 0; cleared = 0; unresolved = [] }
;;
