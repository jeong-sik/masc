module Head = Fs_compat.Capability_head

include Keeper_lifecycle_admission_durable_types
open Keeper_lifecycle_admission_permit
open Keeper_lifecycle_admission_journal

let permit_matches (permit : permit) ~base_path keeper_name =
  permit_scope_matches permit ~base_path keeper_name
  &&
  let active_lease = Eio.Fiber.get active_permit_lease_key in
  with_permit_lifecycle permit (fun lifecycle ->
    lifecycle.open_to_reentrant_leases
    || lease_is_live_for_permit permit active_lease)
;;

let with_permit_lease permit ~base_path keeper_name fn =
  if not (permit_scope_matches permit ~base_path keeper_name)
  then Permit_lease_denied
  else
    match try_with_reentrant_lease permit (fun _ -> fn ()) with
    | Some value -> Permit_lease_completed value
    | None -> Permit_lease_denied
;;

let with_durable_lifecycle_admission config ~keeper_name fn =
  let acquire_fresh () =
    match authority_lock_path config keeper_name with
    | Error failure ->
      Admission_blocked
        (Authority_unreadable { keeper_name; failure })
    | Ok lock_path ->
      (match
         File_lock_eio.with_durable_lock_observed
           ~lock_path
           (fun () ->
              match read_locked config keeper_name with
              | Blocked reason -> Error reason
              | Admitted evidence ->
                Ok
                  (with_active_permit
                     ~base_path:config.Workspace.base_path
                     ~keeper_name
                     ~evidence
                     fn))
       with
       | File_lock_eio.Lock_not_acquired _ ->
         Admission_blocked
           (Authority_unreadable
              { keeper_name; failure = Durable_lock_unavailable })
       | File_lock_eio.Body_completed
           { value = Error reason; release_error = None } ->
         Admission_blocked reason
       | File_lock_eio.Body_completed
           { value = Ok value; release_error = None } ->
         Admission_completed value
       | File_lock_eio.Body_completed
           { value = Error _; release_error = Some _ } ->
         Admission_blocked
           (Authority_unreadable
              { keeper_name; failure = Durable_lock_release_failed })
       | File_lock_eio.Body_completed
           { value = Ok value; release_error = Some _ } ->
         Admission_completed_with_attention
           (value, Durable_lock_release_failed))
  in
  match Eio.Fiber.get active_permit_scope_key with
  | Some permit
    when permit_scope_matches
           permit
           ~base_path:config.Workspace.base_path
           keeper_name ->
    (match
       with_permit_lease
         permit
         ~base_path:config.Workspace.base_path
         keeper_name
         (fun () -> fn permit)
     with
     | Permit_lease_completed value -> Admission_completed value
     | Permit_lease_denied -> acquire_fresh ())
  | Some _ | None -> acquire_fresh ()
;;

let with_recovery_lifecycle_admission
      config
      ~keeper_name
      ~transaction_id
      fn
  =
  match authority_lock_path config keeper_name with
  | Error failure ->
    Admission_blocked
      (Authority_unreadable { keeper_name; failure })
  | Ok lock_path ->
    (match
       File_lock_eio.with_durable_lock_observed
         ~lock_path
         (fun () ->
            let admit evidence =
              if String.equal evidence.transaction_id transaction_id
              then
                Ok
                  (with_active_permit
                     ~base_path:config.Workspace.base_path
                     ~keeper_name
                     ~evidence:(Some evidence)
                     fn)
              else
                Error
                  (Revival_transaction_mismatch
                     { keeper_name; observed = Some evidence })
            in
            match read_locked config keeper_name with
            | Blocked (Rollback_capable_authority evidence) -> admit evidence
            | Admitted (Some evidence) -> admit evidence
            | Blocked reason -> Error reason
            | Admitted None ->
              Error
                (Revival_transaction_mismatch
                   { keeper_name; observed = None }))
     with
     | File_lock_eio.Lock_not_acquired _ ->
       Admission_blocked
         (Authority_unreadable
            { keeper_name; failure = Durable_lock_unavailable })
     | File_lock_eio.Body_completed
         { value = Error reason; release_error = None } ->
       Admission_blocked reason
     | File_lock_eio.Body_completed
         { value = Ok value; release_error = None } ->
       Admission_completed value
     | File_lock_eio.Body_completed
         { value = Error _; release_error = Some _ } ->
       Admission_blocked
         (Authority_unreadable
            { keeper_name; failure = Durable_lock_release_failed })
     | File_lock_eio.Body_completed
         { value = Ok value; release_error = Some _ } ->
       Admission_completed_with_attention
         (value, Durable_lock_release_failed))
;;

let with_revival_launch_admission_under_lock
      config
      ~keeper_name
      ~owner_id
      fn
  =
  match read_locked config keeper_name with
  | Blocked
      (Rollback_capable_authority
         ({ stage = Durable_committed; _ } as evidence)) ->
    (* This second exact point-read retains the active owner binding. The
       caller holds the durable lock, so no cached startup result or racing
       cleanup can intervene between this read and lane launch. *)
    (match journal_parent config, journal_entropy () with
     | Ok parent, Ok secure_random ->
       (match
          Head.read
            ~secure_random
            ~parent
            ~leaf:(journal_leaf keeper_name)
        with
        | Ok snapshot
          when Head.snapshot_settlement_warnings snapshot <> [] ->
          Error
            (Authority_unreadable
               { keeper_name
               ; failure = Authority_read_settlement_failed
               })
        | Ok snapshot ->
          (match Head.snapshot_row snapshot with
           | Some raw ->
             (match decode_exact raw with
              | Ok { owner_id = Some observed; evidence = current }
                when String.equal observed owner_id
                     && current.stage = Durable_committed ->
                Ok
                  (with_active_permit
                     ~base_path:config.Workspace.base_path
                     ~keeper_name
                     ~evidence:(Some current)
                     fn)
              | Ok _ | Error () ->
                Error
                  (Revival_transaction_mismatch
                     { keeper_name; observed = Some evidence }))
           | None ->
             Error
               (Revival_transaction_mismatch
                  { keeper_name; observed = None }))
        | Error _ ->
          Error
            (Authority_unreadable
               { keeper_name; failure = Authority_read_failed }))
     | Error failure, _ | _, Error failure ->
       Error (Authority_unreadable { keeper_name; failure }))
  | Blocked reason -> Error reason
  | Admitted evidence ->
    Error
      (Revival_transaction_mismatch
         { keeper_name; observed = evidence })
;;

let inspect config ~keeper_name =
  let projection decision = { keeper_name; decision } in
  match
    with_durable_lifecycle_admission
      config
      ~keeper_name
      (fun permit -> permit.evidence)
  with
  | Admission_completed evidence
  | Admission_completed_with_attention (evidence, _) ->
    projection (Admitted evidence)
  | Admission_blocked reason -> projection (Blocked reason)
;;

let stage_to_wire = function
  | Reserved -> "reserved"
  | Durable_committed -> "durable_committed"
  | Launch_committed -> "launch_committed"
  | Rollback_reserved -> "rollback_reserved"
  | Rollback_durable_committed -> "rollback_durable_committed"
  | Forward_cleanup_pending -> "forward_cleanup_pending"
  | Rollback_cleanup_pending_from_reserved ->
    "rollback_cleanup_pending_from_reserved"
  | Rollback_cleanup_pending_from_durable_committed ->
    "rollback_cleanup_pending_from_durable_committed"
  | Cleared -> "cleared"
;;

let authority_failure_to_wire = function
  | Authority_path_unavailable -> "authority_path_unavailable"
  | Filesystem_capability_unavailable ->
    "filesystem_capability_unavailable"
  | Entropy_unavailable -> "entropy_unavailable"
  | Durable_lock_unavailable -> "durable_lock_unavailable"
  | Durable_lock_release_failed -> "durable_lock_release_failed"
  | Authority_read_failed -> "authority_read_failed"
  | Authority_read_settlement_failed ->
    "authority_read_settlement_failed"
  | Invalid_current_schema -> "invalid_current_schema"
;;

let blocked_reason_to_wire = function
  | Authority_unreadable { failure; _ } ->
    "authority_unreadable:" ^ authority_failure_to_wire failure
  | Authority_invalid { failure; _ } ->
    "authority_invalid:" ^ authority_failure_to_wire failure
  | Rollback_capable_authority evidence ->
    "rollback_capable:" ^ stage_to_wire evidence.stage
  | Revival_transaction_mismatch _ ->
    "revival_transaction_mismatch"
;;

let evidence_to_yojson (evidence : evidence) =
  `Assoc
    [ "keeper_name", `String evidence.keeper_name
    ; "transaction_id", `String evidence.transaction_id
    ; "stage", `String (stage_to_wire evidence.stage)
    ]
;;

let blocked_reason_to_yojson = function
  | Authority_unreadable { keeper_name; failure } ->
    `Assoc
      [ "kind", `String "authority_unreadable"
      ; "keeper_name", `String keeper_name
      ; "failure", `String (authority_failure_to_wire failure)
      ]
  | Authority_invalid { keeper_name; failure } ->
    `Assoc
      [ "kind", `String "authority_invalid"
      ; "keeper_name", `String keeper_name
      ; "failure", `String (authority_failure_to_wire failure)
      ]
  | Rollback_capable_authority evidence ->
    `Assoc
      [ "kind", `String "rollback_capable_authority"
      ; "evidence", evidence_to_yojson evidence
      ]
  | Revival_transaction_mismatch { keeper_name; observed } ->
    `Assoc
      [ "kind", `String "revival_transaction_mismatch"
      ; "keeper_name", `String keeper_name
      ; ( "observed"
        , match observed with
          | None -> `Null
          | Some evidence -> evidence_to_yojson evidence )
      ]
;;

let projection_to_yojson projection =
  let decision =
    match projection.decision with
    | Admitted evidence ->
      `Assoc
        [ "admitted", `Bool true
        ; ( "evidence"
          , match evidence with
            | None -> `Null
            | Some value -> evidence_to_yojson value )
        ]
    | Blocked reason ->
      `Assoc
        [ "admitted", `Bool false
        ; "blocked_reason", blocked_reason_to_yojson reason
        ]
  in
  `Assoc
    [ "keeper_name", `String projection.keeper_name
    ; "decision", decision
    ]
;;

module For_testing = struct
  let permit_matches = permit_matches

  let replace_current_row ~config ~keeper_name ~row =
    match journal_parent config, journal_entropy () with
    | Error _, _ | _, Error _ -> Error "test authority unavailable"
    | Ok parent, Ok secure_random ->
      (match
         Head.read
           ~secure_random
           ~parent
           ~leaf:(journal_leaf keeper_name)
       with
       | Error _ -> Error "test authority read failed"
       | Ok snapshot ->
         (match journal_entropy () with
          | Error _ -> Error "test authority entropy unavailable"
          | Ok secure_random ->
            (match
               Head.compare_and_swap
                 ~secure_random
                 ~parent
                 ~leaf:(journal_leaf keeper_name)
                 ~expected:(Head.snapshot_cursor snapshot)
                 ~row
             with
             | Ok _ -> Ok ()
             | Error _ -> Error "test authority publication failed")))
  ;;
end
