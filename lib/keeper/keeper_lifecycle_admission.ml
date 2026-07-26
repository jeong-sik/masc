type paused_latch =
  | Classified of Keeper_latched_reason.t
  | Unclassified

type state =
  | Active
  | Paused of paused_latch
  | Dead_tombstone

let state ~paused ~latched_reason =
  match latched_reason with
  | Some Keeper_latched_reason.Dead_tombstone -> Dead_tombstone
  | Some (Keeper_latched_reason.Transcript_corruption_reset_required as reason) ->
    Paused (Classified reason)
  | Some reason when paused -> Paused (Classified reason)
  | None when paused -> Paused Unclassified
  | Some _ | None -> Active
;;

type manual_one_shot_admission =
  | Manual_admitted_active
  | Manual_admitted_paused_recovery of paused_latch
  | Manual_denied_dead_tombstone
  | Manual_denied_transcript_reset_required

let admit_manual_one_shot = function
  | Active -> Manual_admitted_active
  | Paused
      (Classified Keeper_latched_reason.Transcript_corruption_reset_required) ->
    Manual_denied_transcript_reset_required
  | Paused latch -> Manual_admitted_paused_recovery latch
  | Dead_tombstone -> Manual_denied_dead_tombstone
;;

type autonomous_denial =
  | Autonomous_paused of paused_latch
  | Autonomous_dead_tombstone

type autonomous_admission =
  | Autonomous_admitted
  | Autonomous_denied of autonomous_denial

let admit_autonomous = function
  | Active -> Autonomous_admitted
  | Paused latch -> Autonomous_denied (Autonomous_paused latch)
  | Dead_tombstone -> Autonomous_denied Autonomous_dead_tombstone
;;

let paused_latch_to_wire = function
  | Classified reason -> Keeper_latched_reason.to_wire reason
  | Unclassified -> "unclassified"
;;

let state_to_wire = function
  | Active -> "active"
  | Paused _ -> "paused"
  | Dead_tombstone -> "dead_tombstone"
;;

let autonomous_denial_to_wire = function
  | Autonomous_paused _ -> "paused"
  | Autonomous_dead_tombstone -> "dead_tombstone"
;;

module Durable_transaction = struct
  module Head = Fs_compat.Capability_head
  module Payload = Keeper_dead_revival_payload

  type stage =
    | Reserved
    | Durable_committed
    | Launch_committed
    | Rollback_reserved
    | Rollback_durable_committed
    | Forward_cleanup_pending
    | Rollback_cleanup_pending_from_reserved
    | Rollback_cleanup_pending_from_durable_committed
    | Cleared

  type evidence =
    { keeper_name : string
    ; transaction_id : string
    ; stage : stage
    }

  type authority_failure =
    | Authority_path_unavailable
    | Filesystem_capability_unavailable
    | Entropy_unavailable
    | Durable_lock_unavailable
    | Durable_lock_release_failed
    | Authority_read_failed
    | Authority_read_settlement_failed
    | Invalid_current_schema

  type blocked_reason =
    | Authority_unreadable of
        { keeper_name : string
        ; failure : authority_failure
        }
    | Authority_invalid of
        { keeper_name : string
        ; failure : authority_failure
        }
    | Rollback_capable_authority of evidence
    | Revival_transaction_mismatch of
        { keeper_name : string
        ; observed : evidence option
        }

  type permit_lifecycle =
    { mutex : Eio.Mutex.t
    ; leases_changed : Eio.Condition.t
    ; mutable open_to_reentrant_leases : bool
    ; mutable active_reentrant_leases : int
    }

  type permit =
    { base_path : string
    ; keeper_name : string
    ; evidence : evidence option
    ; scope_id : int
    ; lifecycle : permit_lifecycle
    }

  type permit_lease =
    { permit_scope_id : int
    ; mutable live : bool
    }

  type decision =
    | Admitted of evidence option
    | Blocked of blocked_reason

  type projection =
    { keeper_name : string
    ; decision : decision
    }

  type decoded =
    { evidence : evidence
    ; owner_id : string option
    }

  type 'a admission_result =
    | Admission_completed of 'a
    | Admission_completed_with_attention of 'a * authority_failure
    | Admission_blocked of blocked_reason

  let active_permit_scope_key : permit Eio.Fiber.key = Eio.Fiber.create_key ()
  let active_permit_lease_key : permit_lease Eio.Fiber.key =
    Eio.Fiber.create_key ()
  ;;

  let next_permit_scope = Atomic.make 0

  let with_permit_lifecycle permit fn =
    Eio.Mutex.use_rw ~protect:true permit.lifecycle.mutex (fun () ->
      fn permit.lifecycle)
  ;;

  let close_to_reentrant_leases permit =
    with_permit_lifecycle permit (fun lifecycle ->
      lifecycle.open_to_reentrant_leases <- false)
  ;;

  let await_reentrant_leases_drained permit =
    Eio.Condition.loop_no_mutex
      permit.lifecycle.leases_changed
      (fun () ->
         with_permit_lifecycle permit (fun lifecycle ->
           if lifecycle.active_reentrant_leases = 0
           then Some ()
           else None))
  ;;

  let close_and_drain_permit permit =
    Eio.Cancel.protect (fun () ->
      close_to_reentrant_leases permit;
      await_reentrant_leases_drained permit)
  ;;

  let with_active_permit ~base_path ~keeper_name ~evidence fn =
    let scope_id = Atomic.fetch_and_add next_permit_scope 1 in
    let permit =
      { base_path
      ; keeper_name
      ; evidence
      ; scope_id
      ; lifecycle =
          { mutex = Eio.Mutex.create ()
          ; leases_changed = Eio.Condition.create ()
          ; open_to_reentrant_leases = true
          ; active_reentrant_leases = 0
          }
      }
    in
    Eio.Fiber.with_binding active_permit_scope_key permit (fun () ->
      Fun.protect
        ~finally:(fun () -> close_and_drain_permit permit)
        (fun () -> fn permit))
  ;;

  let permit_scope_matches (permit : permit) ~base_path keeper_name =
    String.equal permit.base_path base_path
    && String.equal permit.keeper_name keeper_name
    &&
    match Eio.Fiber.get active_permit_scope_key with
    | Some active_permit -> Int.equal active_permit.scope_id permit.scope_id
    | None -> false
  ;;

  let lease_is_live_for_permit permit = function
    | Some lease ->
      lease.live
      && Int.equal lease.permit_scope_id permit.scope_id
    | None -> false
  ;;

  let release_reentrant_lease permit lease =
    let drained =
      with_permit_lifecycle permit (fun lifecycle ->
        if lease.live
        then (
          lease.live <- false;
          lifecycle.active_reentrant_leases <-
            lifecycle.active_reentrant_leases - 1;
          lifecycle.active_reentrant_leases = 0)
        else false)
    in
    if drained
    then Eio.Condition.broadcast permit.lifecycle.leases_changed
  ;;

  let try_with_reentrant_lease permit fn =
    let parent_lease = Eio.Fiber.get active_permit_lease_key in
    let lease =
      { permit_scope_id = permit.scope_id
      ; live = false
      }
    in
    Eio.Fiber.with_binding active_permit_lease_key lease (fun () ->
      Fun.protect
        ~finally:(fun () ->
          Eio.Cancel.protect (fun () ->
            release_reentrant_lease permit lease))
        (fun () ->
           let acquired =
             with_permit_lifecycle permit (fun lifecycle ->
               if
                 lifecycle.open_to_reentrant_leases
                 || lease_is_live_for_permit permit parent_lease
               then (
                 lifecycle.active_reentrant_leases <-
                   lifecycle.active_reentrant_leases + 1;
                 lease.live <- true;
                 true)
               else false)
           in
           if acquired then Some (fn permit) else None))
  ;;

  let journal_schema = "masc.keeper-dead-revival-journal.v3"
  let head_entropy_bytes = 32 * 33

  let sha256 value =
    Digestif.SHA256.(to_hex (digest_string value))
  ;;

  let length_delimited value =
    Printf.sprintf "%d:%s" (String.length value) value
  ;;

  let journal_dir config =
    Filename.concat
      (Workspace.masc_root_dir config)
      "keeper-lifecycle-transactions"
  ;;

  let journal_leaf keeper_name =
    "revival-"
    ^ sha256
        ("keeper-dead-revival-journal-leaf-v1\000"
         ^ length_delimited keeper_name)
    ^ ".json"
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
    | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
    | _ -> Error Authority_path_unavailable
  ;;

  let authority_lock_path config keeper_name =
    match Payload.authority_shard_for_keeper ~keeper_name with
    | Error _ -> Error Authority_path_unavailable
    | Ok shard ->
      revival_authority_lock_path
        config
        (Payload.authority_shard_leaf shard)
  ;;

  let exact_fields expected fields =
    let expected = List.sort String.compare expected in
    let observed = List.map fst fields |> List.sort String.compare in
    List.equal String.equal expected observed
  ;;

  let required_string key fields =
    match List.assoc_opt key fields with
    | Some (`String value)
      when not (String.equal (String.trim value) "") ->
      Ok value
    | Some _ | None -> Error ()
  ;;

  let required_sha256 key fields =
    let ( let* ) = Result.bind in
    let* value = required_string key fields in
    match Digestif.SHA256.consistent_of_hex_opt value with
    | Some digest
      when String.equal value (Digestif.SHA256.to_hex digest) ->
      Ok value
    | Some _ | None -> Error ()
  ;;

  let required_stage fields =
    match List.assoc_opt "stage" fields with
    | Some (`Assoc [ "reserved", `Bool true ]) -> Ok Reserved
    | Some (`Assoc [ "durable_committed", `Bool true ]) ->
      Ok Durable_committed
    | Some (`Assoc [ "launch_committed", `Bool true ]) ->
      Ok Launch_committed
    | Some (`Assoc [ "rollback_reserved", `Bool true ]) ->
      Ok Rollback_reserved
    | Some (`Assoc [ "rollback_durable_committed", `Bool true ]) ->
      Ok Rollback_durable_committed
    | Some (`Assoc [ "forward_cleanup_pending", `Bool true ]) ->
      Ok Forward_cleanup_pending
    | Some
        (`Assoc
          [ ( "rollback_cleanup_pending"
            , `Assoc [ "from_reserved", `Bool true ] )
          ]) ->
      Ok Rollback_cleanup_pending_from_reserved
    | Some
        (`Assoc
          [ ( "rollback_cleanup_pending"
            , `Assoc [ "from_durable_committed", `Bool true ] )
          ]) ->
      Ok Rollback_cleanup_pending_from_durable_committed
    | Some (`Assoc [ "cleared", `Bool true ]) -> Ok Cleared
    | Some _ | None -> Error ()
  ;;

  let stage_to_json = function
    | Reserved -> `Assoc [ "reserved", `Bool true ]
    | Durable_committed ->
      `Assoc [ "durable_committed", `Bool true ]
    | Launch_committed ->
      `Assoc [ "launch_committed", `Bool true ]
    | Rollback_reserved ->
      `Assoc [ "rollback_reserved", `Bool true ]
    | Rollback_durable_committed ->
      `Assoc [ "rollback_durable_committed", `Bool true ]
    | Forward_cleanup_pending ->
      `Assoc [ "forward_cleanup_pending", `Bool true ]
    | Rollback_cleanup_pending_from_reserved ->
      `Assoc
        [ ( "rollback_cleanup_pending"
          , `Assoc [ "from_reserved", `Bool true ] )
        ]
    | Rollback_cleanup_pending_from_durable_committed ->
      `Assoc
        [ ( "rollback_cleanup_pending"
          , `Assoc [ "from_durable_committed", `Bool true ] )
        ]
    | Cleared -> `Assoc [ "cleared", `Bool true ]
  ;;

  let decode_exact raw =
    let ( let* ) = Result.bind in
    try
      match Yojson.Safe.from_string raw with
      | `Assoc fields ->
        let* schema = required_string "schema" fields in
        let* transaction_id = required_sha256 "transaction_id" fields in
        let* keeper_name = required_string "keeper_name" fields in
        let* stage = required_stage fields in
        if not (String.equal schema journal_schema)
        then Error ()
        else
          let evidence = { keeper_name; transaction_id; stage } in
          (match stage with
           | Cleared ->
             if
               not
                 (exact_fields
                    [ "schema"; "transaction_id"; "keeper_name"; "stage" ]
                    fields)
             then Error ()
             else
               let canonical =
                 `Assoc
                   [ "schema", `String schema
                   ; "transaction_id", `String transaction_id
                   ; "keeper_name", `String keeper_name
                   ; "stage", stage_to_json stage
                   ]
                 |> Yojson.Safe.to_string
               in
               if String.equal raw canonical
               then Ok { evidence; owner_id = None }
               else Error ()
           | Reserved
           | Durable_committed
           | Launch_committed
           | Rollback_reserved
           | Rollback_durable_committed
           | Forward_cleanup_pending
           | Rollback_cleanup_pending_from_reserved
           | Rollback_cleanup_pending_from_durable_committed ->
             if
               not
                 (exact_fields
                    [ "schema"
                    ; "transaction_id"
                    ; "owner_id"
                    ; "keeper_name"
                    ; "expected_trace_id"
                    ; "expected_generation"
                    ; "payload_ref"
                    ; "stage"
                    ]
                    fields)
             then Error ()
             else
               let* owner_id = required_string "owner_id" fields in
               let* expected_trace_id =
                 required_string "expected_trace_id" fields
               in
               let* expected_generation =
                 match List.assoc_opt "expected_generation" fields with
                 | Some (`Int value) -> Ok value
                 | Some _ | None -> Error ()
               in
               let* () =
                 Keeper_id.Trace_id.of_string expected_trace_id
                 |> Result.map (fun _ -> ())
                 |> Result.map_error (fun _ -> ())
               in
               let* payload_ref =
                 match List.assoc_opt "payload_ref" fields with
                 | Some json ->
                   Payload.immutable_ref_of_json json
                   |> Result.map_error (fun _ -> ())
                 | None -> Error ()
               in
               let* shard =
                 Payload.authority_shard_for_keeper ~keeper_name
                 |> Result.map_error (fun _ -> ())
               in
               let* transaction_leaf =
                 Payload.transaction_leaf_for_id ~transaction_id
                 |> Result.map_error (fun _ -> ())
               in
               if
                 not
                   (String.equal
                      (Payload.immutable_ref_authority_leaf payload_ref)
                      (Payload.authority_shard_leaf shard))
                 || not
                      (String.equal
                         (Payload.immutable_ref_transaction_leaf payload_ref)
                         transaction_leaf)
               then Error ()
               else
                 let canonical =
                   `Assoc
                     [ "schema", `String schema
                     ; "transaction_id", `String transaction_id
                     ; "owner_id", `String owner_id
                     ; "keeper_name", `String keeper_name
                     ; "expected_trace_id", `String expected_trace_id
                     ; "expected_generation", `Int expected_generation
                     ; "payload_ref", Payload.immutable_ref_to_json payload_ref
                     ; "stage", stage_to_json stage
                     ]
                   |> Yojson.Safe.to_string
                 in
                 if String.equal raw canonical
                 then Ok { evidence; owner_id = Some owner_id }
                 else Error ())
      | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null
      | `String _ -> Error ()
    with
    | Yojson.Json_error _ -> Error ()
  ;;

  let journal_parent config =
    try
      let dir = Keeper_fs.ensure_dir (journal_dir config) in
      match Fs_compat.get_fs_opt () with
      | None -> Error Filesystem_capability_unavailable
      | Some fs -> Ok Eio.Path.(fs / dir)
    with
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
    | _ -> Error Authority_path_unavailable
  ;;

  let journal_entropy () =
    try
      Ok (Eio.Flow.string_source (Crypto_rng.generate head_entropy_bytes))
    with
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
    | _ -> Error Entropy_unavailable
  ;;

  let read_locked config keeper_name =
    match journal_parent config, journal_entropy () with
    | Error failure, _ | _, Error failure ->
      Blocked (Authority_unreadable { keeper_name; failure })
    | Ok parent, Ok secure_random ->
      (match
         Head.read
           ~secure_random
           ~parent
           ~leaf:(journal_leaf keeper_name)
       with
       | Error _ ->
         Blocked
           (Authority_unreadable
              { keeper_name; failure = Authority_read_failed })
       | Ok snapshot
         when Head.snapshot_settlement_warnings snapshot <> [] ->
         Blocked
           (Authority_unreadable
              { keeper_name
              ; failure = Authority_read_settlement_failed
              })
       | Ok snapshot ->
         (match Head.snapshot_row snapshot with
          | None -> Admitted None
          | Some raw ->
            (match decode_exact raw with
             | Error () ->
               Blocked
                 (Authority_invalid
                    { keeper_name
                    ; failure = Invalid_current_schema
                    })
             | Ok decoded
               when not
                      (String.equal
                         decoded.evidence.keeper_name
                         keeper_name) ->
               Blocked
                 (Authority_invalid
                    { keeper_name
                    ; failure = Invalid_current_schema
                    })
             | Ok { evidence = ({ stage; _ } as evidence); _ } ->
               (match stage with
                | Reserved
                | Durable_committed
                | Rollback_reserved
                | Rollback_durable_committed
                | Rollback_cleanup_pending_from_reserved
                | Rollback_cleanup_pending_from_durable_committed ->
                  Blocked (Rollback_capable_authority evidence)
                | Launch_committed
                | Forward_cleanup_pending
                | Cleared ->
                  Admitted (Some evidence)))))
  ;;

  let permit_matches (permit : permit) ~base_path keeper_name =
    permit_scope_matches permit ~base_path keeper_name
    &&
    let active_lease = Eio.Fiber.get active_permit_lease_key in
    with_permit_lifecycle permit (fun lifecycle ->
      lifecycle.open_to_reentrant_leases
      || lease_is_live_for_permit permit active_lease)
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
      (match try_with_reentrant_lease permit fn with
       | Some value -> Admission_completed value
       | None -> acquire_fresh ())
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
end
